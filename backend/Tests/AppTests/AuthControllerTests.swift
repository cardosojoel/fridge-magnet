@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Corpo de `/health`, replicado aqui porque `HealthResponse` é `private` em
/// `configure.swift` — `@testable import` não relaxa `private` (só `internal`).
private struct HealthPayload: Content {
    var status: String
    var database: String
}

final class AuthControllerTests: XCTestCase {
    // MARK: Task 1 — fatia traçadora

    func testHealthEndpointReturnsOKWhenDatabaseIsReachable() async throws {
        try await TestSupport.withApp { app in
            try await app.testable().test(.GET, "/health") { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
                let body = try res.content.decode(HealthPayload.self)
                XCTAssertEqual(body.status, "ok")
                XCTAssertEqual(body.database, "ok")
            }
        }
    }

    func testAppleSignInIssuesSession() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(email: "member@example.com")
            let sessionRequest = SessionRequest(
                provider: .apple,
                identityToken: token,
                displayName: "Joel",
                gender: .masculino
            )

            try await app.testable().test(
                .POST, "/api/v1/auth/session",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    try req.content.encode(sessionRequest, as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .ok)
                    let body = try res.content.decode(SessionResponse.self)
                    XCTAssertEqual(body.expiresIn, 900)
                    XCTAssertFalse(body.accessToken.isEmpty)
                    XCTAssertFalse(body.refreshToken.isEmpty)
                    XCTAssertEqual(body.user.displayName, "Joel")
                    XCTAssertNil(body.household)
                }
            )

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1, "um identity token válido deve criar exatamente uma linha em users")

            let linkedCount = try await LinkedIdentity.query(on: app.db).count()
            XCTAssertEqual(
                linkedCount, 1,
                "um identity token válido deve criar exatamente uma linha em linked_identities"
            )
        }
    }

    // MARK: Task 2 — matriz de rejeição de token e login recorrente sem duplicata (IDENT-02)

    /// Apresenta `token` em `POST /api/v1/auth/session` e devolve o status HTTP junto do
    /// corpo decodificado como sucesso (`SessionResponse`) ou erro (`APIErrorResponse`),
    /// conforme o status — evita duplicar o `beforeRequest`/`afterResponse` em cada teste
    /// da matriz.
    private func postSession(
        app: Application,
        token: String
    ) async throws -> (status: HTTPStatus, session: SessionResponse?, error: APIErrorResponse?) {
        let sessionRequest = SessionRequest(provider: .apple, identityToken: token)
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedSession: SessionResponse?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/auth/session",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                try req.content.encode(sessionRequest, as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedSession = try res.content.decode(SessionResponse.self)
                } else {
                    capturedError = try res.content.decode(APIErrorResponse.self)
                }
            }
        )

        return (capturedStatus, capturedSession, capturedError)
    }

    func testRepeatedLoginResolvesToSameUserWithoutDuplicate() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let token = try await TestSupport.makeAppleIdentityToken(subject: subject)

            let first = try await postSession(app: app, token: token)
            XCTAssertEqual(first.status, .ok)
            let firstUserID = try XCTUnwrap(first.session?.user.id)

            let second = try await postSession(app: app, token: token)
            XCTAssertEqual(second.status, .ok)
            let secondUserID = try XCTUnwrap(second.session?.user.id)

            XCTAssertEqual(
                firstUserID, secondUserID,
                "o mesmo (provider, subject) apresentado duas vezes deve resolver para o mesmo users.id"
            )

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1, "o segundo login da mesma pessoa não pode criar uma segunda conta")

            let linkedCount = try await LinkedIdentity.query(on: app.db).count()
            XCTAssertEqual(linkedCount, 1, "o segundo login não pode criar uma segunda linked_identities")
        }
    }

    func testTokenSignedByUnknownKeyIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(signingKey: TestSupport.rogueSigningKey)

            let result = try await postSession(app: app, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 0, "um token com chave desconhecida não pode criar nenhuma linha em users")
        }
    }

    func testTokenWithWrongAudienceIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(audience: "com.other-app.wrong")

            let result = try await postSession(app: app, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testTokenWithWrongIssuerIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(issuer: "https://not-appleid.example.com")

            let result = try await postSession(app: app, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testExpiredTokenIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(
                expiration: Date().addingTimeInterval(-300)
            )

            let result = try await postSession(app: app, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testMissingEmailVerifiedClaimIsAcceptedButRecordedAsFalse() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let token = try await TestSupport.makeAppleIdentityToken(subject: subject, emailVerified: nil)

            let result = try await postSession(app: app, token: token)
            XCTAssertEqual(result.status, .ok, "email_verified ausente não pode bloquear o login")

            let linkedIdentity = try await LinkedIdentity.query(on: app.db)
                .filter(\.$providerSubject == subject)
                .first()
            let unwrapped = try XCTUnwrap(linkedIdentity)
            XCTAssertFalse(
                unwrapped.emailVerified,
                "email_verified ausente nunca pode ser gravado como true (trava a unificação de D-03)"
            )
        }
    }

    func testAllRejectionPathsReturnTheSameErrorCode() async throws {
        try await TestSupport.withApp { app in
            let wrongKey = try await TestSupport.makeAppleIdentityToken(signingKey: TestSupport.rogueSigningKey)
            let wrongAudience = try await TestSupport.makeAppleIdentityToken(audience: "com.other-app.wrong")
            let wrongIssuer = try await TestSupport.makeAppleIdentityToken(issuer: "https://not-appleid.example.com")
            let expired = try await TestSupport.makeAppleIdentityToken(expiration: Date().addingTimeInterval(-300))

            for badToken in [wrongKey, wrongAudience, wrongIssuer, expired] {
                let result = try await postSession(app: app, token: badToken)
                XCTAssertEqual(result.status, .unauthorized)
                XCTAssertEqual(
                    result.error?.code, .invalidToken,
                    "nenhum caminho de rejeição pode devolver uma mensagem/código que distinga o motivo (T-01-10)"
                )
            }
        }
    }

    // MARK: Plano 01-07 — PATCH /api/v1/auth/profile (D-04)

    func testUpdateProfileWithValidBearerSetsGender() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app, displayName: "Ana")
            let userID = try user.requireID()
            let token = try await TestSupport.makeAccessToken(app: app, userID: userID)

            try await app.testable().test(
                .PATCH, "/api/v1/auth/profile",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(UpdateProfileRequest(gender: .feminino), as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .noContent)
                }
            )

            let reloaded = try await User.find(userID, on: app.db)
            XCTAssertEqual(reloaded?.gender, "feminino")
        }
    }

    func testUpdateProfileWithoutBearerIsRejected() async throws {
        try await TestSupport.withApp { app in
            try await app.testable().test(
                .PATCH, "/api/v1/auth/profile",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    try req.content.encode(UpdateProfileRequest(gender: .masculino), as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .unauthorized)
                }
            )
        }
    }
}

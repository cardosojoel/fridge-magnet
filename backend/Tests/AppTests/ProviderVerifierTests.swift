@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Plano 01-08 Task 1 — os sete casos de `<behavior>`: Google e Microsoft passam pelo
/// mesmo caminho de verificação já provado pela Apple (planos 01-01/01-02), e a Microsoft
/// nunca confia em um `iss` fixo nem numa URL de JWKS adivinhada.
final class ProviderVerifierTests: XCTestCase {
    /// Apresenta `token` em `POST /api/v1/auth/session` e devolve o status HTTP junto do
    /// corpo decodificado — mesma forma do helper privado de `AuthControllerTests`
    /// (duplicado aqui porque `private` não atravessa arquivos de teste).
    private func postSession(
        app: Application,
        provider: AuthProvider,
        token: String
    ) async throws -> (status: HTTPStatus, session: SessionResponse?, error: APIErrorResponse?) {
        let sessionRequest = SessionRequest(provider: provider, identityToken: token)
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

    // MARK: Google

    /// O Google emite `iss` nas duas formas — aceitar só uma quebraria logins reais de
    /// forma intermitente.
    func testGoogleTokenIsAcceptedWithBothIssuerForms() async throws {
        try await TestSupport.withApp { app in
            for issuer in ["https://accounts.google.com", "accounts.google.com"] {
                let subject = UUID().uuidString
                let token = try await TestSupport.makeGoogleIdentityToken(
                    subject: subject,
                    email: "member@example.com",
                    issuer: issuer
                )

                let result = try await postSession(app: app, provider: .google, token: token)
                XCTAssertEqual(result.status, .ok, "iss '\(issuer)' deve ser aceito")
                XCTAssertEqual(result.session?.user.email, "member@example.com")

                let linkedIdentity = try await LinkedIdentity.query(on: app.db)
                    .filter(\.$provider == AuthProvider.google.rawValue)
                    .filter(\.$providerSubject == subject)
                    .first()
                let unwrapped = try XCTUnwrap(linkedIdentity)
                XCTAssertTrue(unwrapped.emailVerified)
            }
        }
    }

    func testGoogleTokenWithWrongAudienceIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeGoogleIdentityToken(audience: "some-other-client-id.apps.googleusercontent.com")

            let result = try await postSession(app: app, provider: .google, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testGoogleTokenMissingEmailVerifiedClaimIsAcceptedButRecordedAsFalse() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let token = try await TestSupport.makeGoogleIdentityToken(subject: subject, emailVerified: nil)

            let result = try await postSession(app: app, provider: .google, token: token)
            XCTAssertEqual(result.status, .ok, "email_verified ausente não pode bloquear o login")

            let linkedIdentity = try await LinkedIdentity.query(on: app.db)
                .filter(\.$providerSubject == subject)
                .first()
            let unwrapped = try XCTUnwrap(linkedIdentity)
            XCTAssertFalse(unwrapped.emailVerified, "email_verified ausente nunca pode ser gravado como true (T-08-06)")
        }
    }

    // MARK: Microsoft

    /// Conta pessoal (GUID de tenant consumidor fixo da Microsoft) com `iss` correspondente
    /// ao próprio `tid` — deve ser aceita, provando que a autoridade `common` não exclui
    /// contas pessoais.
    func testMicrosoftTokenWithPersonalTenantIsAccepted() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let token = try await TestSupport.makeMicrosoftIdentityToken(
                subject: subject,
                email: nil,
                preferredUsername: "member@outlook.com",
                tenantID: "9188040d-6c67-4c5b-b112-36a304b66dad"
            )

            let result = try await postSession(app: app, provider: .microsoft, token: token)
            XCTAssertEqual(result.status, .ok)
            XCTAssertEqual(
                result.session?.user.email, "member@outlook.com",
                "e-mail ausente deve cair para preferred_username em contas pessoais"
            )
        }
    }

    /// `iss` não corresponde ao próprio `tid` do token — mesmo com assinatura válida, deve
    /// ser rejeitado (T-08-03). Isto é o que separa "aceitar qualquer tenant sob
    /// login.microsoftonline.com" (inseguro) de "aceitar qualquer tenant, mas só o que o
    /// próprio token afirma ser o seu" (seguro).
    func testMicrosoftTokenWithIssuerNotMatchingOwnTenantIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeMicrosoftIdentityToken(
                tenantID: "11111111-1111-1111-1111-111111111111",
                issuer: "https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0"
            )

            let result = try await postSession(app: app, provider: .microsoft, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testMicrosoftTokenWithWrongAudienceIsRejected() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeMicrosoftIdentityToken(audience: "00000000-wrong-client-id")

            let result = try await postSession(app: app, provider: .microsoft, token: token)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .invalidToken)
        }
    }

    func testMicrosoftTokenMissingEmailVerifiedClaimIsAcceptedButRecordedAsFalse() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let token = try await TestSupport.makeMicrosoftIdentityToken(subject: subject, emailVerified: nil)

            let result = try await postSession(app: app, provider: .microsoft, token: token)
            XCTAssertEqual(result.status, .ok, "email_verified ausente não pode bloquear o login")

            let linkedIdentity = try await LinkedIdentity.query(on: app.db)
                .filter(\.$providerSubject == subject)
                .first()
            let unwrapped = try XCTUnwrap(linkedIdentity)
            XCTAssertFalse(unwrapped.emailVerified, "email_verified ausente nunca pode ser gravado como true (T-08-06)")
        }
    }

    // MARK: Chave desconhecida e expiração — os três provedores

    func testTokenSignedByUnknownKeyIsRejectedForEveryProvider() async throws {
        try await TestSupport.withApp { app in
            let googleToken = try await TestSupport.makeGoogleIdentityToken(signingKey: TestSupport.rogueSigningKey)
            let microsoftToken = try await TestSupport.makeMicrosoftIdentityToken(signingKey: TestSupport.rogueSigningKey)

            for (provider, token) in [(AuthProvider.google, googleToken), (AuthProvider.microsoft, microsoftToken)] {
                let result = try await postSession(app: app, provider: provider, token: token)
                XCTAssertEqual(result.status, .unauthorized, "\(provider.rawValue): chave desconhecida deve ser rejeitada")
                XCTAssertEqual(result.error?.code, .invalidToken)
            }

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 0, "nenhum token com chave desconhecida pode criar uma linha em users")
        }
    }

    func testExpiredTokenIsRejectedForEveryProvider() async throws {
        try await TestSupport.withApp { app in
            let expiration = Date().addingTimeInterval(-300)
            let googleToken = try await TestSupport.makeGoogleIdentityToken(expiration: expiration)
            let microsoftToken = try await TestSupport.makeMicrosoftIdentityToken(expiration: expiration)

            for (provider, token) in [(AuthProvider.google, googleToken), (AuthProvider.microsoft, microsoftToken)] {
                let result = try await postSession(app: app, provider: provider, token: token)
                XCTAssertEqual(result.status, .unauthorized, "\(provider.rawValue): token expirado deve ser rejeitado")
                XCTAssertEqual(result.error?.code, .invalidToken)
            }
        }
    }

    // MARK: O registro cobre os três provedores — sem 501

    func testGoogleSignInNoLongerReturns501AndIssuesSession() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeGoogleIdentityToken()
            let result = try await postSession(app: app, provider: .google, token: token)
            XCTAssertEqual(result.status, .ok, "provider: google não pode mais responder 501")
            XCTAssertNotNil(result.session)
        }
    }

    func testMicrosoftSignInNoLongerReturns501AndIssuesSession() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeMicrosoftIdentityToken()
            let result = try await postSession(app: app, provider: .microsoft, token: token)
            XCTAssertEqual(result.status, .ok, "provider: microsoft não pode mais responder 501")
            XCTAssertNotNil(result.session)
        }
    }
}

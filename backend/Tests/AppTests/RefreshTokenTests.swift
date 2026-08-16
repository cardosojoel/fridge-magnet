@testable import App
import Crypto
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Cobertura de `SessionService`/`AuthController.refresh`/`AuthController.logout` — plano
/// 01-04. Task 1 cobre rotação, expiração, logout e ausência de oráculo de existência de
/// token; Task 2 acrescenta a detecção de reuso que revoga a família inteira.
final class RefreshTokenTests: XCTestCase {
    // MARK: Helpers

    /// Loga com um identity token Apple válido e devolve a `SessionResponse` completa —
    /// usado por todo teste que precisa de um refresh token real emitido pelo servidor.
    private func login(app: Application) async throws -> SessionResponse {
        let token = try await TestSupport.makeAppleIdentityToken()
        var captured: SessionResponse?
        try await app.testable().test(
            .POST, "/api/v1/auth/session",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                try req.content.encode(SessionRequest(provider: .apple, identityToken: token), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
                captured = try res.content.decode(SessionResponse.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    private func postRefresh(
        app: Application,
        token: String
    ) async throws -> (status: HTTPStatus, session: SessionResponse?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedSession: SessionResponse?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/auth/refresh",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                try req.content.encode(RefreshRequest(refreshToken: token), as: .json)
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

    private func postLogout(app: Application, token: String) async throws -> HTTPStatus {
        var capturedStatus: HTTPStatus = .internalServerError
        try await app.testable().test(
            .POST, "/api/v1/auth/logout",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                try req.content.encode(LogoutRequest(refreshToken: token), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
            }
        )
        return capturedStatus
    }

    /// SHA-256 hexadecimal — recalculado independentemente em cada teste (não importado de
    /// `SessionService`, que é `private` a esse detalhe) para provar, de fora, que o valor
    /// gravado em `refresh_tokens.token_hash` é mesmo o hash do valor devolvido.
    private func sha256Hex(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Task 1 — refresh_tokens com hash em repouso, rotação e logout revogável

    func testSessionPersistsOnlyTheHashedRefreshToken() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            let rows = try await RefreshToken.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1, "login deve gravar exatamente uma linha em refresh_tokens")

            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(
                row.tokenHash, sha256Hex(session.refreshToken),
                "token_hash deve ser o SHA-256 do valor devolvido ao cliente"
            )
            XCTAssertNotEqual(
                row.tokenHash, session.refreshToken,
                "o refresh token nunca existe em texto puro no banco"
            )
        }
    }

    func testRefreshWithValidTokenRotatesAndReturnsNewTokens() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            let result = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(result.status, .ok)
            let newSession = try XCTUnwrap(result.session)
            XCTAssertNotEqual(newSession.accessToken, session.accessToken)
            XCTAssertNotEqual(newSession.refreshToken, session.refreshToken)

            let rows = try await RefreshToken.query(on: app.db).all()
            XCTAssertEqual(rows.count, 2, "rotação deve criar uma linha nova sem apagar a antiga")
        }
    }

    func testReusingARotatedRefreshTokenIsRejected() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)
            let firstRotation = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(firstRotation.status, .ok)

            let secondAttempt = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(secondAttempt.status, .unauthorized)
            XCTAssertEqual(secondAttempt.error?.code, .unauthorized)
        }
    }

    func testExpiredRefreshTokenIsRejected() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            guard let row = try await RefreshToken.query(on: app.db)
                .filter(\.$tokenHash == sha256Hex(session.refreshToken))
                .first()
            else {
                return XCTFail("linha de refresh_tokens não encontrada após login")
            }
            row.expiresAt = Date().addingTimeInterval(-60)
            try await row.save(on: app.db)

            let result = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .unauthorized)
        }
    }

    func testUnknownRefreshTokenIsRejectedWithoutRevealingExistence() async throws {
        try await TestSupport.withApp { app in
            let result = try await postRefresh(app: app, token: "token-que-nunca-existiu-\(UUID().uuidString)")
            XCTAssertEqual(result.status, .unauthorized)
            XCTAssertEqual(result.error?.code, .unauthorized)
        }
    }

    /// Prova que inexistente/expirado/revogado devolvem exatamente o mesmo corpo — nenhum
    /// deles pode entregar um oráculo sobre qual dos três motivos causou o 401 (T-04-04).
    func testAllRefreshFailureReasonsReturnTheSameErrorShape() async throws {
        try await TestSupport.withApp { app in
            let unknown = try await postRefresh(app: app, token: "inexistente-\(UUID().uuidString)")

            let expiredSession = try await login(app: app)
            guard let expiredRow = try await RefreshToken.query(on: app.db)
                .filter(\.$tokenHash == sha256Hex(expiredSession.refreshToken))
                .first()
            else {
                return XCTFail("linha de refresh_tokens não encontrada para o caso expirado")
            }
            expiredRow.expiresAt = Date().addingTimeInterval(-60)
            try await expiredRow.save(on: app.db)
            let expired = try await postRefresh(app: app, token: expiredSession.refreshToken)

            let revokedSession = try await login(app: app)
            let logoutStatus = try await postLogout(app: app, token: revokedSession.refreshToken)
            XCTAssertEqual(logoutStatus, .noContent)
            let revoked = try await postRefresh(app: app, token: revokedSession.refreshToken)

            for result in [unknown, expired, revoked] {
                XCTAssertEqual(result.status, .unauthorized)
                XCTAssertEqual(
                    result.error?.code, .unauthorized,
                    "inexistente, expirado e revogado devem devolver exatamente o mesmo APIErrorCode"
                )
            }
        }
    }

    func testLogoutRevokesTokenServerSide() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            let logoutStatus = try await postLogout(app: app, token: session.refreshToken)
            XCTAssertEqual(logoutStatus, .noContent)

            let afterLogout = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(
                afterLogout.status, .unauthorized,
                "o mesmo refresh token usado em /refresh após /logout deve ser rejeitado (D-11)"
            )
        }
    }

    func testLogoutIsIdempotent() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            let first = try await postLogout(app: app, token: session.refreshToken)
            XCTAssertEqual(first, .noContent)

            let second = try await postLogout(app: app, token: session.refreshToken)
            XCTAssertEqual(second, .noContent, "logout de um token já revogado continua respondendo 204")
        }
    }
}

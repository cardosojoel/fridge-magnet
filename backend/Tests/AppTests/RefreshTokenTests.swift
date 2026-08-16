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
    /// `subject` fixo permite logar como o mesmo usuário mais de uma vez (Task 2: "segundo
    /// login do mesmo usuário cria uma família nova").
    private func login(app: Application, subject: String = UUID().uuidString) async throws -> SessionResponse {
        let token = try await TestSupport.makeAppleIdentityToken(subject: subject)
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

    // MARK: Task 2 — detecção de reuso revogando a família inteira de tokens

    /// Cenário de roubo completo (T-04-01): T1 → T2 (rotação legítima) → T1 reapresentado
    /// (sinal de reuso). A resposta é 401 e T2 — o token vivo até então — também passa a
    /// ser rejeitado, porque a família inteira caiu. Prova ainda que toda linha daquele
    /// `family_id` fica com `revoked_at` preenchido, e que a família de um segundo login
    /// do mesmo usuário não é afetada.
    func testReusedRefreshTokenRevokesFamily() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let session = try await login(app: app, subject: subject)
            let t1 = session.refreshToken

            let rotateToT2 = try await postRefresh(app: app, token: t1)
            XCTAssertEqual(rotateToT2.status, .ok)
            let t2 = try XCTUnwrap(rotateToT2.session).refreshToken

            // Reapresenta T1, já rotacionado — a assinatura de roubo/replay.
            let reuseAttempt = try await postRefresh(app: app, token: t1)
            XCTAssertEqual(reuseAttempt.status, .unauthorized)
            XCTAssertEqual(reuseAttempt.error?.code, .unauthorized)

            // T2 era o token vivo até este ponto — a família inteira deve tê-lo derrubado.
            let t2AfterReuse = try await postRefresh(app: app, token: t2)
            XCTAssertEqual(
                t2AfterReuse.status, .unauthorized,
                "reapresentar um token já rotacionado deve revogar a família inteira, inclusive o token mais recente"
            )

            guard let originalRow = try await RefreshToken.query(on: app.db)
                .filter(\.$tokenHash == sha256Hex(t1))
                .first()
            else {
                return XCTFail("linha original de refresh_tokens não encontrada")
            }
            let familyID = originalRow.familyID

            let familyRows = try await RefreshToken.query(on: app.db)
                .filter(\.$familyID == familyID)
                .all()
            XCTAssertEqual(familyRows.count, 2, "T1 e T2 devem pertencer à mesma família")
            for row in familyRows {
                XCTAssertNotNil(row.revokedAt, "toda linha da família comprometida deve ter revoked_at preenchido")
            }

            // Segundo login do mesmo usuário — família nova, não afetada pela revogação acima.
            let secondSession = try await login(app: app, subject: subject)
            XCTAssertNotEqual(
                secondSession.refreshToken, t1,
                "um novo login deve emitir um refresh token novo, nunca reaproveitar um já revogado"
            )
            let secondRotation = try await postRefresh(app: app, token: secondSession.refreshToken)
            XCTAssertEqual(
                secondRotation.status, .ok,
                "a revogação da família comprometida não pode afetar a família de um novo login do mesmo usuário"
            )
        }
    }

    /// Protege contra a implementação excessivamente agressiva que derrubaria a sessão de
    /// todo mundo a cada renovação: uma cadeia de rotações normal (T1→T2→T3, nunca
    /// reapresentando um token já usado) não pode disparar `revokeFamily` nenhuma vez.
    func testNormalRotationChainDoesNotRevokeFamily() async throws {
        try await TestSupport.withApp { app in
            let session = try await login(app: app)

            let rotateToT2 = try await postRefresh(app: app, token: session.refreshToken)
            XCTAssertEqual(rotateToT2.status, .ok)
            let t2 = try XCTUnwrap(rotateToT2.session).refreshToken

            let rotateToT3 = try await postRefresh(app: app, token: t2)
            XCTAssertEqual(rotateToT3.status, .ok)
            let t3 = try XCTUnwrap(rotateToT3.session).refreshToken

            guard let currentRow = try await RefreshToken.query(on: app.db)
                .filter(\.$tokenHash == sha256Hex(t3))
                .first()
            else {
                return XCTFail("T3 não encontrado em refresh_tokens")
            }
            XCTAssertNil(currentRow.revokedAt, "o token vivo mais recente da cadeia não pode estar revogado")

            let familyRows = try await RefreshToken.query(on: app.db)
                .filter(\.$familyID == currentRow.familyID)
                .all()
            XCTAssertEqual(familyRows.count, 3, "T1, T2 e T3 devem pertencer à mesma família")
            let liveCount = familyRows.filter { $0.revokedAt == nil }.count
            XCTAssertEqual(
                liveCount, 1,
                "rotação normal em cadeia revoga a linha antiga a cada passo, mas nunca a família inteira de uma vez"
            )

            // A cadeia continua funcionando token a token — nenhuma revogação de família a
            // atrapalhou no caminho.
            let rotateToT4 = try await postRefresh(app: app, token: t3)
            XCTAssertEqual(rotateToT4.status, .ok)
        }
    }
}

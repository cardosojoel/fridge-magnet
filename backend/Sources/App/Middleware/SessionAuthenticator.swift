import Fluent
import JWT
import Vapor

/// `User` participa da autenticação de request do Vapor — só isso. Declarado aqui (não em
/// `Identity.swift`, plano 01-01) porque é este arquivo que introduz a primeira dependência
/// de `User` em autenticação de rota; `Identity.swift` continua descrevendo só o modelo de
/// dados.
extension User: Authenticatable {}

/// Autentica requests via Bearer JWT — o `accessToken` emitido por
/// `POST /api/v1/auth/session`. Verifica a assinatura ES256 e carrega o `User` do `sub`.
///
/// Nenhuma decisão de acesso a casa sai daqui: este middleware só estabelece quem é o
/// requisitante. `HouseholdContextMiddleware` (que roda depois, nas rotas escopadas) decide
/// o que esse requisitante pode ver.
struct SessionAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for req: Request) async throws {
        let payload: AccessTokenPayload
        do {
            payload = try await req.jwt.verify(bearer.token, as: AccessTokenPayload.self)
        } catch {
            // Token inválido/expirado: não autentica. `User.guardMiddleware()`, registrado
            // junto deste autenticador nas rotas protegidas, converte a ausência de sessão
            // em 401 — o mesmo padrão de "nenhum oráculo de motivo" do plano 01-01.
            return
        }

        guard let userID = UUID(uuidString: payload.subject.value) else {
            return
        }

        guard let user = try await User.find(userID, on: req.db) else {
            return
        }

        req.auth.login(user)
    }
}

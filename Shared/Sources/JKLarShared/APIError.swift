import Foundation

/// Vocabulário de erro de toda a API do JK Lar.
///
/// Arquivo próprio (separado de `AuthDTO.swift`) porque este é o conjunto de códigos de
/// erro consumido por planos de várias ondas — não é específico do fluxo de identidade.
///
/// Os cinco caminhos de rejeição de token da Task 2 (chave errada, `aud` errado, `iss`
/// errado, `exp` vencido, token forjado) devolvem todos `.invalidToken` — nunca uma
/// mensagem que diferencie o motivo, para não entregar a um atacante um oráculo sobre o
/// estado do JWKS ou sobre quais tokens já existiram.
public enum APIErrorCode: String, Codable, Sendable {
    case unauthorized
    case forbidden
    case invalidToken
    case householdFull
    case inviteInvalid
    case inviteExpired
    case validation
    case internalError
    /// `POST /api/v1/households` quando o usuário já pertence a uma casa (409) — plano 01-02.
    case alreadyMember
    /// `PATCH /api/v1/households/current/members/:memberID/role` (409) — rebaixar este
    /// membro deixaria a casa sem nenhum admin. Plano 01-06; reaproveitado pelo plano 01-10
    /// nas rotas de remoção e saída, que podem violar a mesma invariante.
    case lastAdmin
    /// `DELETE /api/v1/households/current/members/:memberID` (409) — o admin tentou remover
    /// a si mesmo por esta rota. Sair tem rota própria (`DELETE .../membership`), que aplica
    /// a invariante de último admin em vez de escapar dela (plano 01-10).
    case cannotRemoveSelf
}

/// Corpo de erro padrão devolvido por qualquer rota da API.
///
/// `message` é sempre um texto seguro para exibir ao usuário — nunca vaza detalhe interno
/// (stack trace, motivo específico de rejeição, nome de coluna, etc.).
public struct APIErrorResponse: Codable, Sendable {
    public var code: APIErrorCode
    public var message: String

    public init(code: APIErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

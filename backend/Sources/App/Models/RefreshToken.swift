import Fluent
import Foundation

/// Uma linha por refresh token emitido — nunca o valor cru, só o hash SHA-256
/// (`SessionService.hash`). `family_id` agrupa toda a cadeia de rotações de um mesmo
/// login: `SessionService.rotate` preserva o `family_id` a cada renovação, e
/// `SessionService.revokeFamily` revoga a família inteira quando um token já rotacionado
/// é reapresentado (T-04-01, plano 01-04 Task 2).
///
/// Sem RLS — mesma decisão registrada em `CreateIdentitySchema` para `users`: esta tabela
/// é consultada por `POST /api/v1/auth/refresh` e `POST /api/v1/auth/logout`, rotas que
/// rodam deliberadamente fora de qualquer contexto de casa (o cliente chama `/refresh`
/// justamente quando o access token — e, com ele, qualquer sessão autenticada — já
/// expirou).
final class RefreshToken: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// Agrupa toda a cadeia de rotações de um mesmo login. Preservado por `rotate`,
    /// revogado inteiro por `revokeFamily` na detecção de reuso.
    @Field(key: "family_id")
    var familyID: UUID

    /// SHA-256 do valor cru — o valor cru em si nunca é persistido em lugar nenhum além da
    /// resposta HTTP que o cria.
    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// `nil` enquanto a linha está ativa. Preenchido por `rotate` (rotação normal) ou por
    /// `revoke`/`revokeFamily` (logout ou detecção de reuso).
    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    /// Aponta para a linha nova emitida na rotação que revogou esta — auditoria da cadeia,
    /// não usado para nenhuma decisão de autorização.
    @OptionalParent(key: "replaced_by_id")
    var replacedBy: RefreshToken?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        familyID: UUID,
        tokenHash: String,
        expiresAt: Date,
        revokedAt: Date? = nil,
        replacedByID: RefreshToken.IDValue? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.familyID = familyID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.$replacedBy.id = replacedByID
    }
}

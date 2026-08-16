import Fluent
import Foundation

/// Um convite de entrada numa casa (D-05/D-06). Reutilizável por várias pessoas diferentes
/// até `expires_at` (7 dias) ou revogação — não é consumido no primeiro uso.
///
/// A tabela correspondente (`CreateHouseholdInvites`) é a única do projeto com `ENABLE` sem
/// `FORCE ROW LEVEL SECURITY`: quem aceita um convite ainda não tem contexto de casa nenhum,
/// então a resolução do código passa pela função `resolve_invite` (`SECURITY DEFINER`), não
/// por uma consulta direta a este modelo sem contexto.
final class HouseholdInvite: Model, @unchecked Sendable {
    static let schema = "household_invites"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    /// 6 caracteres, gerado por `InviteCodeGenerator` (CSPRNG). Único por índice — uma
    /// colisão no INSERT é tratada gerando de novo, nunca sobrescrevendo a linha existente.
    @Field(key: "code")
    var code: String

    @Parent(key: "created_by_user_id")
    var createdBy: User

    @Field(key: "expires_at")
    var expiresAt: Date

    /// `nil` enquanto o convite está ativo. Revogação explícita fica fora do escopo desta
    /// fatia (nenhuma rota deste plano a expõe) — o campo já existe no schema para quando
    /// essa rota for adicionada, sem precisar de outra migration.
    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        code: String,
        createdByUserID: User.IDValue,
        expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.$household.id = householdID
        self.code = code
        self.$createdBy.id = createdByUserID
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

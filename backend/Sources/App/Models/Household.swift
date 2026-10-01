import Fluent
import Foundation

/// Uma "casa" do FridgeMagnet — o raiz do tenant. Toda tabela de domínio das Fases 2 a 10 escopa
/// por `household_id`; esta é a tabela que esse `household_id` referencia.
final class Household: Model, @unchecked Sendable {
    static let schema = "households"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// Vínculo entre um `User` e uma `Household`, com o papel (`role`) desse membro nela
/// (IDENT-06). `unique(household_id, user_id)` no schema garante que um usuário pertence a,
/// no máximo, uma linha por casa — e, combinado com o 409 do `HouseholdController` em
/// `POST /api/v1/households`, a uma única casa no total nesta fatia.
final class HouseholdMember: Model, @unchecked Sendable {
    static let schema = "household_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @Parent(key: "user_id")
    var user: User

    /// "admin" | "adulto" | "crianca" — espelha `MemberRole` do contrato compartilhado.
    /// Decidido sempre no servidor (T-02-03): nunca lido de um campo de request.
    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        userID: User.IDValue,
        role: String
    ) {
        self.id = id
        self.$household.id = householdID
        self.$user.id = userID
        self.role = role
    }
}

import Foundation

/// Papel de um membro dentro de uma casa (IDENT-06). Nunca aceito do cliente na criação da
/// casa — de propósito, `MemberRole` não aparece em `CreateHouseholdRequest`: o papel do
/// criador é sempre `.admin`, decidido no servidor (T-02-03).
public enum MemberRole: String, Codable, Sendable {
    case admin
    case adulto
    case crianca
}

/// Corpo de `POST /api/v1/households`.
///
/// Deliberadamente não carrega `role` nem `household_id`: um campo que não existe no tipo
/// não pode ser lido por engano, mesmo que o corpo JSON bruto do request contenha essas
/// chaves (zero-trust do front-end, `.claude/CLAUDE.md`).
public struct CreateHouseholdRequest: Codable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// Casa do JK Lar, do ponto de vista do membro autenticado que fez o request.
public struct HouseholdDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var memberCount: Int
    /// Papel do requisitante nesta casa — nunca o papel de outro membro.
    public var myRole: MemberRole

    public init(id: UUID, name: String, memberCount: Int, myRole: MemberRole) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
        self.myRole = myRole
    }
}

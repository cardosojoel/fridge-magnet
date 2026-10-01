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

/// Casa do FridgeMagnet, do ponto de vista do membro autenticado que fez o request.
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

/// Convite para entrar numa casa (D-05). Devolvido por `POST .../invites` e listado por
/// `GET .../invites` — o código em si não é um segredo de posse única (é reutilizável por
/// 7 dias, D-06), então re-expor o mesmo `InviteDTO` na listagem não vaza nada que o link
/// compartilhado já não revele.
public struct InviteDTO: Codable, Sendable {
    public var code: String
    public var url: String
    public var expiresAt: Date

    public init(code: String, url: String, expiresAt: Date) {
        self.code = code
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Corpo de `POST /api/v1/households/join`.
///
/// Carrega **só** o código: o papel de quem entra é decidido no servidor, sempre `.adulto`
/// (D-07) — um campo que não existe no tipo não pode ser lido por engano, mesmo que o corpo
/// JSON bruto do request contenha essas chaves (zero-trust do front-end, `.claude/CLAUDE.md`).
public struct JoinHouseholdRequest: Codable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

/// Um membro da casa do requisitante, para `GET /api/v1/households/current/members`.
/// `id` é o id da linha de `household_members` (não o `user.id`) — é o mesmo valor usado
/// como `memberID` em `PATCH .../members/:memberID/role` e em
/// `DELETE .../members/:memberID` (plano 01-10).
public struct MemberDTO: Codable, Sendable {
    public var id: UUID
    /// O `user.id` real por trás desta linha — distinto de `id` (linha de
    /// `household_members`) de propósito. Plano 02-06: o seletor de menção estruturado
    /// (D-06) precisa apontar `CreateRecadoRequest.mentionedUserIDs`/`MentionDTO.userID` para
    /// o `user_id` que o backend valida contra `household_members.user_id`
    /// (`RecadoController.resolveHouseholdMemberUserIDs`) — mandar `id` (a linha de
    /// membership) ali seria sempre rejeitado com 422 `notHouseholdMember` para qualquer
    /// pessoa que não seja o próprio requisitante.
    public var userID: UUID
    public var displayName: String?
    public var role: MemberRole
    public var joinedAt: Date
    /// Verdadeiro só na linha do próprio requisitante — sempre computado no servidor
    /// (comparação de `user.id`), nunca inferido no cliente por nome ou posição na lista.
    /// Plano 01-10: é o que permite `HouseholdViewModel.canRemove(_:)` esconder a ação de
    /// remover na própria linha sem depender de um heurístico do lado do cliente (nomes
    /// duplicados na mesma casa não são impossíveis).
    public var isSelf: Bool

    public init(id: UUID, userID: UUID, displayName: String?, role: MemberRole, joinedAt: Date, isSelf: Bool) {
        self.id = id
        self.userID = userID
        self.displayName = displayName
        self.role = role
        self.joinedAt = joinedAt
        self.isSelf = isSelf
    }
}

/// Corpo de `PATCH /api/v1/households/current/members/:memberID/role`. Só o admin pode
/// enviar este request (`RequireRoleMiddleware([.admin])`) — o papel resultante ainda assim
/// é sempre um dos três valores válidos de `MemberRole`, nunca uma string livre.
public struct UpdateMemberRoleRequest: Codable, Sendable {
    public var role: MemberRole

    public init(role: MemberRole) {
        self.role = role
    }
}

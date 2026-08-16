import Fluent
import FluentSQL
import Foundation
import JKLarShared
import Vapor

/// Contexto de tenant resolvido para o request — a casa e o papel do requisitante nela.
/// Nunca construído a partir de um campo de request; sempre da linha real de
/// `household_members` do usuário autenticado.
struct HouseholdContext: Sendable {
    var householdID: UUID
    var role: MemberRole
}

private struct HouseholdContextStorageKey: StorageKey {
    typealias Value = HouseholdContext
}

private struct ScopedDatabaseStorageKey: StorageKey {
    typealias Value = any Database
}

extension Request {
    /// Contexto de casa resolvido por `HouseholdContextMiddleware` — `nil` fora de rotas
    /// escopadas.
    var householdContext: HouseholdContext? {
        self.storage[HouseholdContextStorageKey.self]
    }

    /// Conexão transacional com `app.current_household_id` (e `app.current_user_id`) já
    /// aplicados nesta transação. Toda leitura/escrita de uma rota protegida por
    /// `HouseholdContextMiddleware` **deve** usar esta conexão — `req.db` puro não carrega
    /// o contexto de tenant aplicado via `SET LOCAL`/`set_config(..., true)`, porque esse
    /// contexto só existe dentro da transação que o aplicou.
    var scopedDB: any Database {
        self.storage[ScopedDatabaseStorageKey.self] ?? self.db
    }
}

/// Para requests autenticados em rotas escopadas por casa: abre uma transação, resolve a
/// linha de `household_members` do usuário, aplica `app.current_household_id` **dentro**
/// dessa transação via `set_config($1, $2, true)` parametrizado — nunca por interpolação de
/// string, nunca fora de transação (o terceiro argumento `true` é o que torna o valor local
/// à transação, equivalente a `SET LOCAL`; em pool de conexões um valor aplicado fora desse
/// escopo sobreviveria ao request e vazaria para o próximo, 01-RESEARCH.md Pitfall 2) — e
/// roda o restante do handler dentro do mesmo bloco.
///
/// Se o usuário ainda não tem casa, o contexto fica ausente e a rota responde 403
/// `forbidden` — fail-closed, nunca um erro genérico que sugira instabilidade.
struct HouseholdContextMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        return try await req.db.transaction { transactionDB in
            try await Self.applyCurrentUserContext(userID: userID, on: transactionDB)

            guard let membership = try await HouseholdMember.query(on: transactionDB)
                .filter(\.$user.$id == userID)
                .first()
            else {
                return try Self.forbiddenResponse()
            }

            let householdID = membership.$household.id
            try await Self.applyCurrentHouseholdContext(householdID: householdID, on: transactionDB)

            guard let role = MemberRole(rawValue: membership.role) else {
                req.logger.error("household_members.role inválido: \(membership.role)")
                throw Abort(.internalServerError)
            }

            req.storage[HouseholdContextStorageKey.self] = HouseholdContext(householdID: householdID, role: role)
            req.storage[ScopedDatabaseStorageKey.self] = transactionDB

            return try await next.respond(to: req)
        }
    }

    /// `app.current_user_id` — o bootstrap que permite a própria linha de
    /// `household_members` do requisitante ser encontrada antes de `app.current_household_id`
    /// existir (ver comentário na policy, `CreateHouseholdSchema`). Sempre o `sub` já
    /// verificado do JWT — nunca um valor vindo de um campo de request.
    static func applyCurrentUserContext(userID: UUID, on database: any Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("HouseholdContextMiddleware exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("SELECT set_config('app.current_user_id', \(bind: userID.uuidString), true)").run()
    }

    static func applyCurrentHouseholdContext(householdID: UUID, on database: any Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("HouseholdContextMiddleware exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("SELECT set_config('app.current_household_id', \(bind: householdID.uuidString), true)").run()
    }

    private static func forbiddenResponse() throws -> Response {
        let response = Response(status: .forbidden)
        try response.content.encode(
            APIErrorResponse(code: .forbidden, message: "Você ainda não pertence a uma casa."),
            as: .json
        )
        return response
    }

    /// Mesmo bootstrap de `respond(to:chainingTo:)`, mas fora do encadeamento de middleware
    /// de uma rota — usado por `AuthController` para popular `SessionResponse.household`
    /// logo após o login, quando a sessão ainda não é um request autenticado de rota
    /// escopada. Devolve `nil` (não lança) quando o usuário ainda não tem casa — este não é
    /// um caminho de erro em `/auth/session`.
    static func resolveHouseholdSummary(userID: UUID, database: any Database) async throws -> HouseholdSummaryDTO? {
        try await database.transaction { transactionDB in
            try await Self.applyCurrentUserContext(userID: userID, on: transactionDB)

            guard let membership = try await HouseholdMember.query(on: transactionDB)
                .filter(\.$user.$id == userID)
                .first()
            else {
                return nil
            }

            let householdID = membership.$household.id
            try await Self.applyCurrentHouseholdContext(householdID: householdID, on: transactionDB)

            guard let household = try await Household.find(householdID, on: transactionDB) else {
                return nil
            }

            return HouseholdSummaryDTO(id: householdID, name: household.name)
        }
    }
}

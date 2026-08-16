import Fluent
import FluentSQL

/// Migration do **plano de sessão de produção** — tabela `refresh_tokens`, plano 01-04.
///
/// Deliberadamente **sem** Row-Level Security: `POST /api/v1/auth/refresh` e
/// `POST /api/v1/auth/logout` rodam fora de qualquer contexto de casa (mesma decisão
/// registrada em `CreateIdentitySchema` para `users`/`linked_identities` — o acesso aqui é
/// sempre chaveado por `token_hash`, nunca por `household_id`).
///
/// Roda no database **owner** (`jklar_owner`, ver `configure.swift`) — o papel de runtime
/// `jklar_app` só recebe o `GRANT` de DML explícito no fim desta migration, nunca DDL.
struct CreateRefreshTokens: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("refresh_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("family_id", .uuid, .required)
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("replaced_by_id", .uuid, .references("refresh_tokens", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateRefreshTokens exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // `family_id` — lido a cada rotação e a cada revogação de família (T-04-01).
        try await sql.raw("CREATE INDEX idx_refresh_tokens_family_id ON refresh_tokens (family_id)").run()
        // `user_id` — não usado nesta fatia por nenhuma rota, mas espelha o índice já
        // existente em toda outra tabela chaveada por usuário; consulta administrativa
        // futura ("listar sessões ativas de um usuário") o reaproveita sem migration nova.
        try await sql.raw("CREATE INDEX idx_refresh_tokens_user_id ON refresh_tokens (user_id)").run()

        // jklar_app é o papel de runtime do backend (NOSUPERUSER NOBYPASSRLS, criado por
        // scripts/dev-db.sh) — só ele recebe DML nas tabelas de aplicação.
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON refresh_tokens TO jklar_app").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("refresh_tokens").delete()
    }
}

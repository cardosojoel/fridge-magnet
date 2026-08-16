import Fluent
import FluentSQL

/// Migration do **plano de identidade** — tabelas `users` e `linked_identities`.
///
/// Deliberadamente **sem** Row-Level Security: são consultadas pelo `AuthController` antes
/// de existir qualquer contexto de casa (`household_id`), e o acesso é sempre chaveado
/// pelo `sub` verificado do provedor, nunca por um `household_id` de request. O plano de
/// tenant (`households`, `household_members`, plano 01-02) tem sua própria migration, com
/// RLS `ENABLE` + `FORCE` desde a primeira versão. Reavaliar esta decisão se alguma rota
/// de domínio passar a ler `users`/`linked_identities` diretamente.
///
/// Roda no database **owner** (`jklar_owner`, ver `configure.swift`) — o papel de runtime
/// `jklar_app` só recebe o `GRANT` de DML explícito no fim desta migration, nunca DDL.
struct CreateIdentitySchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("display_name", .string)
            .field("gender", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema("linked_identities")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_subject", .string, .required)
            .field("email", .string)
            .field("email_verified", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "provider", "provider_subject")
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateIdentitySchema exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // Índice parcial que viabiliza D-03 (unificação por e-mail verificado, plano
        // 01-08): busca, não varredura, e só sobre e-mails que já foram verificados.
        try await sql.raw("""
            CREATE INDEX idx_linked_identities_verified_email
            ON linked_identities (lower(email))
            WHERE email_verified = true
            """).run()

        // jklar_app é o papel de runtime do backend (NOSUPERUSER NOBYPASSRLS, criado por
        // scripts/dev-db.sh) — só ele recebe DML nas tabelas de aplicação.
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON users TO jklar_app").run()
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON linked_identities TO jklar_app").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("linked_identities").delete()
        try await database.schema("users").delete()
    }
}

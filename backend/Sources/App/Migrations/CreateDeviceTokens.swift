import Fluent
import FluentSQL

/// Migration do **plano de push** (01-11) — tabela `device_tokens`, com Row-Level Security
/// `ENABLE`+`FORCE` desde esta primeira versão, nunca retrofitada.
///
/// Roda no database **owner** (`jklar_owner`, ver `configure.swift`) — o papel de runtime
/// `jklar_app` só recebe o `GRANT` de DML explícito no fim desta migration, nunca DDL.
struct CreateDeviceTokens: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("device_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("apns_token", .string, .required)
            .field("platform", .string, .required)
            .field("environment", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "apns_token")
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateDeviceTokens exige um SQLDatabase (FluentSQL escape hatch)")
        }

        try await sql.raw(
            "CREATE INDEX idx_device_tokens_household_id ON device_tokens (household_id)"
        ).run()

        try await sql.raw("ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY").run()
        try await sql.raw("ALTER TABLE device_tokens FORCE ROW LEVEL SECURITY").run()

        // Duas cláusulas OR, não uma só (diferente de `households`, igual a
        // `household_members` em `CreateHouseholdSchema`): `apns_token` é `unique`
        // globalmente, e "o mesmo dispositivo trocando de casa" (must_have deste plano) só
        // funciona sem virar lixo acumulado se a linha antiga continuar visível para o
        // próprio dono do token mesmo depois que `household_id` mudou de baixo dela. Sob
        // `FORCE`, nem `jklar_owner` (dono da tabela) escapa da policy — então uma policy de
        // cláusula única (`household_id = app.current_household_id`) tornaria essa linha
        // permanentemente invisível assim que a casa do usuário mudasse, e o upsert bateria
        // no índice único em vez de mover a linha (o mesmo raciocínio "Rule 1 — bug de
        // plano" já registrado no comentário de `household_members` em
        // `CreateHouseholdSchema`, aplicado aqui a um problema diferente). A cláusula extra
        // só compara contra o `user_id` do requisitante autenticado (aplicado por
        // `HouseholdContextMiddleware` antes de qualquer query) — nunca contra um valor de
        // request, e nunca abre visibilidade do token de outro usuário numa casa diferente
        // da atual (T-11-01, T-11-06).
        try await sql.raw("""
            CREATE POLICY household_isolation ON device_tokens
            USING (
                household_id = NULLIF(current_setting('app.current_household_id', true), '')::uuid
                OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
            )
            """).run()

        // jklar_app é o papel de runtime do backend (NOSUPERUSER NOBYPASSRLS) — só ele
        // recebe DML na tabela de aplicação.
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON device_tokens TO jklar_app").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("device_tokens").delete()
    }
}

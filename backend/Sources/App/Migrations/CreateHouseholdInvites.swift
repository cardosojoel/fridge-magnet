import Fluent
import FluentSQL

/// Migration do **plano de convite** (01-06) — tabela `household_invites`, a função
/// `resolve_invite` que resolve um código antes de existir contexto de casa, e a função
/// irmã `invite_exists` que só existe para distinguir "código inexistente" de "código
/// expirado" sem abrir um caminho de leitura mais amplo do que esse.
///
/// Roda no database **owner** (`fridgemagnet_owner`, ver `configure.swift`) — o papel de runtime
/// `fridgemagnet_app` só recebe os `GRANT`s explícitos no fim desta migration, nunca DDL.
struct CreateHouseholdInvites: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("household_invites")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("code", .string, .required)
            .field("created_by_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "code")
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateHouseholdInvites exige um SQLDatabase (FluentSQL escape hatch)")
        }

        try await sql.raw(
            "CREATE INDEX idx_household_invites_household_id ON household_invites (household_id)"
        ).run()

        // Diferença deliberada em relação a `households`/`household_members`
        // (`CreateHouseholdSchema`): ENABLE **sem** FORCE. Quem aceita um convite ainda não
        // tem `app.current_household_id` nenhum — precisa de um caminho que resolva o
        // código sem que a policy o cegue. Esse caminho é `resolve_invite`, `SECURITY
        // DEFINER`: como a tabela ficou sem FORCE, o dono (`fridgemagnet_owner`, quem a função roda
        // como) fica isento da policy por padrão do Postgres. `fridgemagnet_app` continua submetido
        // à policy em qualquer consulta direta — só recebe `GRANT EXECUTE` das duas funções
        // abaixo, nunca `SELECT` direto na tabela sem contexto (T-06-05, T-06-09).
        try await sql.raw("ALTER TABLE household_invites ENABLE ROW LEVEL SECURITY").run()
        try await sql.raw("""
            CREATE POLICY household_isolation ON household_invites
            USING (household_id = NULLIF(current_setting('app.current_household_id', true), '')::uuid)
            """).run()

        // `resolve_invite` — único caminho para transformar um código em `household_id`
        // antes de existir contexto de casa. Devolve só o `household_id`, nunca a linha
        // inteira: um código errado não distingue "não existe" de "expirou" para quem está
        // de fora (T-06-06). `code = upper(p_code)` normaliza a comparação — o gerador só
        // produz maiúsculas, mas quem digita do papel pode digitar minúsculo.
        try await sql.raw("""
            CREATE FUNCTION resolve_invite(p_code text) RETURNS uuid
            LANGUAGE sql STABLE SECURITY DEFINER
            SET search_path = public
            AS $$
                SELECT household_id FROM household_invites
                WHERE code = upper(p_code) AND revoked_at IS NULL AND expires_at > now()
                LIMIT 1
            $$
            """).run()

        // `invite_exists` — o "segundo caminho igualmente confinado" que o join usa só para
        // decidir entre `inviteInvalid` (código nunca existiu) e `inviteExpired` (código
        // existe mas está vencido/revogado), sem conceder `SELECT` direto na tabela.
        try await sql.raw("""
            CREATE FUNCTION invite_exists(p_code text) RETURNS boolean
            LANGUAGE sql STABLE SECURITY DEFINER
            SET search_path = public
            AS $$
                SELECT EXISTS (SELECT 1 FROM household_invites WHERE code = upper(p_code))
            $$
            """).run()

        // fridgemagnet_app é o papel de runtime do backend (NOSUPERUSER NOBYPASSRLS). UPDATE fica
        // concedido de antemão para a rota de revogação (fora do escopo desta fatia) não
        // exigir outra migration — continua RLS-scoped como qualquer outro UPDATE.
        try await sql.raw("GRANT SELECT, INSERT, UPDATE ON household_invites TO fridgemagnet_app").run()
        try await sql.raw("GRANT EXECUTE ON FUNCTION resolve_invite(text) TO fridgemagnet_app").run()
        try await sql.raw("GRANT EXECUTE ON FUNCTION invite_exists(text) TO fridgemagnet_app").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("CreateHouseholdInvites exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("DROP FUNCTION IF EXISTS invite_exists(text)").run()
        try await sql.raw("DROP FUNCTION IF EXISTS resolve_invite(text)").run()
        try await database.schema("household_invites").delete()
    }
}

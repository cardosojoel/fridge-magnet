import Fluent
import FluentSQL

/// Migration do **plano de tenant** — tabelas `households` e `household_members`, com Row-
/// Level Security `ENABLE` + `FORCE` desde esta primeira versão (nunca retrofitada).
///
/// `household_id` + policy RLS é a convenção herdada por toda tabela de domínio das Fases 2
/// a 10 — decisão de arquitetura já fechada em PROJECT.md (zero-trust) e 01-RESEARCH.md
/// Pattern 2. `FORCE` é obrigatório: sem ele, o dono da tabela (`jklar_owner`, que roda esta
/// migration) ignoraria a policy por padrão no PostgreSQL 17, e o teste de isolamento da
/// Task 2 passaria sem provar nada caso alguém conectasse acidentalmente como dono.
///
/// Roda no database **owner** (`jklar_owner`, ver `configure.swift`) — o papel de runtime
/// `jklar_app` só recebe o `GRANT` de DML explícito no fim desta migration, nunca DDL.
struct CreateHouseholdSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("households")
            .id()
            .field("name", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema("household_members")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "household_id", "user_id")
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateHouseholdSchema exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // `households` — a raiz do tenant. `NULLIF` é obrigatório: sem ele, um
        // `current_setting` ausente devolve string vazia e o cast para uuid levanta erro em
        // vez de negar acesso — o comportamento correto é zero linhas (fail-closed), não
        // exceção.
        try await sql.raw("ALTER TABLE households ENABLE ROW LEVEL SECURITY").run()
        try await sql.raw("ALTER TABLE households FORCE ROW LEVEL SECURITY").run()
        try await sql.raw("""
            CREATE POLICY household_isolation ON households
            USING (id = NULLIF(current_setting('app.current_household_id', true), '')::uuid)
            """).run()

        // `household_members` — mesma policy de `household_id`, **mais** uma segunda
        // cláusula OR sobre `user_id = app.current_user_id`. Esta segunda cláusula não está
        // no texto literal do plano, mas é necessária para o bootstrap funcionar: sob RLS
        // forçada, `jklar_app` (NOBYPASSRLS) não tem nenhuma forma de descobrir a casa de um
        // usuário sem já conhecer o `household_id` — a policy de uma cláusula só cria um
        // impasse (nenhuma linha nunca é visível antes de `app.current_household_id`
        // existir, mesmo para o próprio dono da linha). `HouseholdContextMiddleware` e
        // `HouseholdController` aplicam `app.current_user_id` (o `sub` do JWT verificado, sob
        // controle exclusivo do servidor) antes de qualquer outra coisa, exatamente para
        // resolver essa única linha própria — nunca para ler a linha de outra pessoa: a
        // cláusula só compara contra o `user_id` do requisitante autenticado, nunca um valor
        // vindo de um campo de request. (Rule 1 — bug de plano: a policy de cláusula única
        // tornaria toda leitura de `household_members` permanentemente vazia, inclusive para
        // o próprio dono da linha, então nenhuma rota deste plano conseguiria funcionar.)
        try await sql.raw("ALTER TABLE household_members ENABLE ROW LEVEL SECURITY").run()
        try await sql.raw("ALTER TABLE household_members FORCE ROW LEVEL SECURITY").run()
        try await sql.raw("""
            CREATE POLICY household_isolation ON household_members
            USING (
                household_id = NULLIF(current_setting('app.current_household_id', true), '')::uuid
                OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
            )
            """).run()

        // jklar_app é o papel de runtime do backend (NOSUPERUSER NOBYPASSRLS, criado por
        // scripts/dev-db.sh) — só ele recebe DML nas tabelas de aplicação.
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON households TO jklar_app").run()
        try await sql.raw("GRANT SELECT, INSERT, UPDATE, DELETE ON household_members TO jklar_app").run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("household_members").delete()
        try await database.schema("households").delete()
    }
}

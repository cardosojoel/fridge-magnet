import Fluent
import FluentSQL

/// Migration do **plano de mural** (02-01) — as cinco tabelas do mural de recados
/// (`recados`, `recado_photos`, `recado_reactions`, `recado_comments`, `recado_mentions`),
/// todas com Row-Level Security `ENABLE`+`FORCE` desde esta primeira versão, nunca
/// retrofitada, mesmo padrão de `CreateHouseholdSchema`/`CreateDeviceTokens`.
///
/// Diferente de `households`/`household_members`/`device_tokens`, nenhuma das cinco tabelas
/// aqui precisa da segunda cláusula OR de bootstrap (`OR user_id = app.current_user_id`):
/// toda linha desta fase nasce depois que `HouseholdContextMiddleware` já resolveu
/// `app.current_household_id`, então não existe o caso "encontrar a própria linha antes de
/// conhecer a própria casa" que motivou aquela cláusula extra em `household_members`/
/// `device_tokens` (02-RESEARCH.md Pattern 1).
///
/// Roda no database **owner** (`fridgemagnet_owner`, ver `configure.swift`) — o papel de runtime
/// `fridgemagnet_app` só recebe o `GRANT` de DML explícito no fim desta migration, nunca DDL.
struct CreateRecadoSchema: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Ordem de criação por causa das FKs: recados primeiro (referenciada por todas as
        // outras quatro), depois as quatro tabelas filhas.
        try await database.schema("recados")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("text", .string)
            .field("sequence", .int64, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema("recado_photos")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("recado_id", .uuid, .required, .references("recados", "id", onDelete: .cascade))
            .field("object_key", .string, .required)
            .field("position", .int, .required)
            .field("content_type", .string, .required)
            .field("byte_size", .int64, .required)
            .field("created_at", .datetime)
            .unique(on: "recado_id", "position")
            .unique(on: "object_key")
            .create()

        try await database.schema("recado_reactions")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("recado_id", .uuid, .required, .references("recados", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // D-07b: uma reação ativa por pessoa por recado — trocar de emoji substitui a
            // anterior, nunca acumula.
            .unique(on: "recado_id", "user_id")
            .create()

        try await database.schema("recado_comments")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("recado_id", .uuid, .required, .references("recados", "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("text", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // Deliberadamente sem coluna de comentário-pai: D-08 fixa lista plana, e não
            // declarar a coluna é o que impede alguém aninhar depois sem uma decisão
            // explícita.
            .create()

        try await database.schema("recado_mentions")
            .id()
            .field("household_id", .uuid, .required, .references("households", "id", onDelete: .cascade))
            .field("recado_id", .uuid, .references("recados", "id", onDelete: .cascade))
            .field("comment_id", .uuid, .references("recado_comments", "id", onDelete: .cascade))
            .field("mentioned_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "recado_id", "mentioned_user_id")
            .unique(on: "comment_id", "mentioned_user_id")
            // Tabela própria com PK própria e created_at de propósito: D-04 diz que a
            // menção é uma marcação sem estado hoje, e uma tabela com linha própria por
            // menção é exatamente a forma que aceita uma coluna de estado por migration
            // aditiva se o produto pedir isso numa fase futura — sem remodelar nada.
            .create()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateRecadoSchema exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // `sequence` — monotônico, dedicado à paginação por cursor (02-RESEARCH.md
        // Alternatives Considered: coluna própria em vez de comparação de tupla
        // `(created_at, id)`, que exigiria outro escape hatch de SQL bruto no caminho de
        // LEITURA, não só de migration). Sequence própria (não `GENERATED ALWAYS AS
        // IDENTITY`) porque o valor precisa ser lido pelo controller ANTES do insert
        // (`SELECT nextval(...)`), não só gerado implicitamente pelo INSERT.
        try await sql.raw("CREATE SEQUENCE recados_sequence_seq AS bigint").run()
        try await sql.raw(
            "ALTER TABLE recados ALTER COLUMN sequence SET DEFAULT nextval('recados_sequence_seq')"
        ).run()
        try await sql.raw("ALTER SEQUENCE recados_sequence_seq OWNED BY recados.sequence").run()
        try await sql.raw("GRANT USAGE, SELECT ON SEQUENCE recados_sequence_seq TO fridgemagnet_app").run()
        try await sql.raw("ALTER TABLE recados ADD CONSTRAINT recados_sequence_unique UNIQUE (sequence)").run()

        // Exatamente um pai por menção (recado OU comentário, nunca os dois, nunca
        // nenhum) — é o que permite D-09 (menção dentro de comentário) reusar esta mesma
        // tabela sem uma segunda tabela paralela.
        try await sql.raw("""
            ALTER TABLE recado_mentions ADD CONSTRAINT recado_mentions_one_parent
            CHECK ((recado_id IS NOT NULL) <> (comment_id IS NOT NULL))
            """).run()

        // Índices.
        try await sql.raw(
            "CREATE INDEX idx_recados_household_sequence ON recados (household_id, sequence DESC)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_photos_recado ON recado_photos (recado_id, position)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_reactions_recado ON recado_reactions (recado_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_comments_recado ON recado_comments (recado_id, created_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_mentions_user ON recado_mentions (mentioned_user_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_photos_household_id ON recado_photos (household_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_reactions_household_id ON recado_reactions (household_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_comments_household_id ON recado_comments (household_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX idx_recado_mentions_household_id ON recado_mentions (household_id)"
        ).run()

        // RLS — `ENABLE`+`FORCE` e a policy de cláusula única (sem `WITH CHECK`: o Postgres
        // reusa a expressão do `USING` também para o INSERT, é isso que impede gravar uma
        // linha com o `household_id` de outra casa) para cada uma das cinco tabelas, nesta
        // ordem.
        for table in ["recados", "recado_photos", "recado_reactions", "recado_comments", "recado_mentions"] {
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) ENABLE ROW LEVEL SECURITY").run()
            try await sql.raw("ALTER TABLE \(unsafeRaw: table) FORCE ROW LEVEL SECURITY").run()
            try await sql.raw("""
                CREATE POLICY household_isolation ON \(unsafeRaw: table)
                USING (household_id = NULLIF(current_setting('app.current_household_id', true), '')::uuid)
                """).run()
            try await sql.raw(
                "GRANT SELECT, INSERT, UPDATE, DELETE ON \(unsafeRaw: table) TO fridgemagnet_app"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("recado_mentions").delete()
        try await database.schema("recado_comments").delete()
        try await database.schema("recado_reactions").delete()
        try await database.schema("recado_photos").delete()
        try await database.schema("recados").delete()

        guard let sql = database as? SQLDatabase else {
            fatalError("CreateRecadoSchema exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("DROP SEQUENCE IF EXISTS recados_sequence_seq").run()
    }
}

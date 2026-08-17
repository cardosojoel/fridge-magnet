import Fluent
import FluentSQL

/// Migration do adendo D-14/D-15 (plano 02-11) — duas colunas aditivas em `recados`
/// (`pinned_at` para fixar, `archived_at` para arquivar) e dois índices parciais.
///
/// A migration original desta fase (`CreateRecadoSchema`, já mesclada) NÃO é editada —
/// disciplina de migration aditiva: um ambiente que já migrou (o banco de dogfooding da
/// família) só recebe o delta.
///
/// Nenhuma tabela nova, nenhuma policy nova, nenhuma concessão de DML nova: `recados` já
/// está sob `ENABLE`+`FORCE` de isolamento por linha com a política `household_isolation`
/// (ver `CreateRecadoSchema`), e a concessão de DML que `jklar_app` já tem vale para a
/// tabela inteira, colunas futuras incluídas — uma policy nova aqui seria uma segunda fonte
/// de verdade.
struct AddRecadoPinAndArchive: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Ambas as colunas são opcionais de propósito — coluna obrigatória sem valor padrão
        // falharia contra as linhas de recado que já existem no banco de dogfooding.
        try await database.schema("recados")
            .field("pinned_at", .datetime)
            .field("archived_at", .datetime)
            .update()

        guard let sql = database as? SQLDatabase else {
            fatalError("AddRecadoPinAndArchive exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // Índices PARCIAIS, não totais: a esmagadora maioria das linhas tem as duas colunas
        // nulas, então o índice parcial fica minúsculo e serve exatamente as duas consultas
        // novas — o bloco de fixados na primeira página do feed (fixação preenchida E
        // arquivamento ausente) e a listagem de arquivados do admin (arquivamento
        // preenchido).
        try await sql.raw("""
            CREATE INDEX idx_recados_household_pinned ON recados (household_id, pinned_at DESC)
            WHERE pinned_at IS NOT NULL AND archived_at IS NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX idx_recados_household_archived ON recados (household_id, archived_at DESC)
            WHERE archived_at IS NOT NULL
            """).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("AddRecadoPinAndArchive exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("DROP INDEX IF EXISTS idx_recados_household_pinned").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_recados_household_archived").run()

        try await database.schema("recados")
            .deleteField("pinned_at")
            .deleteField("archived_at")
            .update()
    }
}

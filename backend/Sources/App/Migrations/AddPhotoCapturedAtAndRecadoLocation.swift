import Fluent

/// Migration do adendo D-11/D-12 (plano 02-08) — quatro colunas aditivas: a data de captura
/// EXIF da foto (`recado_photos.captured_at`) e a localização opcional do recado
/// (`recados.location_text`/`location_lat`/`location_lng`).
///
/// A migration original desta fase (`CreateRecadoSchema`, já mesclada) NÃO é editada —
/// disciplina de migration aditiva: um ambiente que já migrou (o banco de dogfooding da
/// família) só recebe o delta.
///
/// As quatro colunas são deliberadamente opcionais: coluna obrigatória sem valor padrão
/// falharia contra as linhas de recado/foto que já existem no banco de dogfooding, e não há
/// dado existente para migrar — ausência ("sem metadado de captura", "sem localização") é um
/// estado legítimo e permanente dessas colunas, não um buraco a preencher.
///
/// Nenhuma tabela nova, nenhuma policy nova, nenhuma concessão de DML nova: `recados` e
/// `recado_photos` já estão sob `ENABLE`+`FORCE` de isolamento por linha com a política
/// `household_isolation` (ver `CreateRecadoSchema`), e a concessão de DML que `jklar_app` já
/// tem vale para a tabela inteira, colunas futuras incluídas — uma policy nova aqui seria
/// uma segunda fonte de verdade (T-02-59).
struct AddPhotoCapturedAtAndRecadoLocation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("recado_photos")
            .field("captured_at", .datetime)
            .update()

        try await database.schema("recados")
            .field("location_text", .string)
            .field("location_lat", .double)
            .field("location_lng", .double)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("recado_photos")
            .deleteField("captured_at")
            .update()

        try await database.schema("recados")
            .deleteField("location_text")
            .deleteField("location_lat")
            .deleteField("location_lng")
            .update()
    }
}

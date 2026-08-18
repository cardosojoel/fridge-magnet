import Fluent

/// Migration do adendo D-16 (plano 02-14) — duas colunas aditivas em `recados`: o instante
/// do evento (`event_at`) e a antecedência do lembrete em segundos
/// (`remind_offset_seconds`).
///
/// Nenhuma migration já mesclada é editada — disciplina de migration aditiva: um ambiente
/// que já migrou (o banco de dogfooding da família) só recebe o delta.
///
/// As duas colunas são deliberadamente opcionais: coluna obrigatória sem valor padrão
/// falharia contra as linhas de recado que já existem no banco de dogfooding, e ausência
/// ("sem lembrete") é um estado legítimo e permanente dessas colunas, não um buraco a
/// preencher. As duas andam sempre juntas — invariante mantida por
/// `RecadoController.normalizeReminder`/`buildDTO`, nunca pelo schema (mesmo precedente
/// das três colunas de localização).
///
/// Nenhum índice novo, então nenhum escape hatch de SQL bruto (ao contrário do plano
/// 02-11): as duas colunas não participam de nenhum filtro, ordenação ou junção do
/// servidor — quem lê o lembrete é o cliente, a partir do recado que o feed já devolveu
/// por `sequence`. Um índice que nenhuma consulta usa é custo de escrita sem benefício;
/// se um dia existir um varredor server-side de lembretes (caminho por APNs), o índice
/// nasce com ele.
///
/// Nenhuma tabela nova, nenhuma policy nova, nenhuma concessão de DML nova: `recados` já
/// está sob `ENABLE`+`FORCE` de isolamento por linha com a política `household_isolation`
/// (ver `CreateRecadoSchema`), e a concessão de DML que `jklar_app` já tem vale para a
/// tabela inteira, colunas futuras incluídas — uma policy nova aqui seria uma segunda
/// fonte de verdade.
struct AddRecadoEventReminder: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("recados")
            .field("event_at", .datetime)
            .field("remind_offset_seconds", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("recados")
            .deleteField("event_at")
            .deleteField("remind_offset_seconds")
            .update()
    }
}

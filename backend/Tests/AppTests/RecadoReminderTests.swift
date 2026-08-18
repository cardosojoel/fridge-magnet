@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// D-16 (plano 02-14): lembrete opcional com data/hora no recado — o par
/// `eventAt`/`remindOffsetSeconds`, o conjunto fechado de antecedências e a validação
/// server-side (par indivisível, conjunto fechado, disparo no futuro), contra Postgres
/// real. O cliente valida por conforto; o servidor é a linha de defesa (zero-trust).
final class RecadoReminderTests: XCTestCase {
    // MARK: Helpers privados de request (convenção do repositório — molde de
    // `RecadoControllerTests`)

    /// Data com segundos inteiros — o contrato viaja em ISO8601 sem fração de segundo,
    /// então uma data com fração não voltaria idêntica do round-trip.
    private static func wholeSecondDate(secondsFromNow: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + secondsFromNow).rounded())
    }

    private static func postRecado(
        app: Application,
        bearer: String,
        text: String? = nil,
        mentionedUserIDs: [UUID] = [],
        location: RecadoLocationDTO? = nil,
        eventAt: Date? = nil,
        remindOffsetSeconds: Int? = nil
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: RecadoDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(
                    CreateRecadoRequest(
                        text: text,
                        mentionedUserIDs: mentionedUserIDs,
                        location: location,
                        eventAt: eventAt,
                        remindOffsetSeconds: remindOffsetSeconds
                    ),
                    as: .json
                )
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTO = try res.content.decode(RecadoDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    private static func getFeed(
        app: Application,
        bearer: String,
        cursor: Int64? = nil
    ) async throws -> RecadoFeedPage {
        var path = "/api/v1/recados"
        if let cursor {
            path += "?cursor=\(cursor)"
        }
        var captured: RecadoFeedPage?
        try await app.testable().test(
            .GET, path,
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
                captured = try res.content.decode(RecadoFeedPage.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    /// Total de linhas de menção da casa inteira — usado pelo caso "par inválido não
    /// persiste NADA": depois da recusa não deve existir linha de menção nenhuma, nem
    /// órfã (o recado nem chegou a existir).
    private static func countAllMentionRows(app: Application, householdID: UUID) async throws -> Int {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            try await sql.raw("SELECT id FROM recado_mentions").all().count
        }
    }

    /// Formato de rede real do contrato (ISO8601, o padrão do `ContentConfiguration` do
    /// Vapor 4) — usado pelos corpos JSON literais abaixo. Formatter construído por
    /// chamada (`ISO8601DateFormatter` não é `Sendable`; custo irrelevante em teste).
    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// PATCH com corpo JSON LITERAL — os casos de "não veio" e "veio nulo" precisam montar
    /// o JSON de verdade nas duas formas: se construíssem o tipo em Swift e deixassem o
    /// encode decidir, provariam o encode, não o contrato de rede que o cliente real fala.
    private static func patchRecadoRawJSON(
        app: Application,
        bearer: String,
        recadoID: UUID,
        json: String
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: RecadoDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .PATCH, "/api/v1/recados/\(recadoID.uuidString)",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedDTO = try res.content.decode(RecadoDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    /// Grava um lembrete DIRETO no banco (sob a mesma conexão `jklar_app` com contexto de
    /// casa) — a única forma de montar o cenário "lembrete guardado que já passou": o
    /// servidor recusa criar um par vencido pela rota, e é isso mesmo.
    private static func writeReminderDirectly(
        app: Application,
        householdID: UUID,
        recadoID: UUID,
        eventAt: Date,
        remindOffsetSeconds: Int
    ) async throws {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            try await sql.raw("""
                UPDATE recados
                SET event_at = \(bind: eventAt), remind_offset_seconds = \(bind: remindOffsetSeconds)
                WHERE id = \(bind: recadoID)
                """).run()
        }
    }

    /// Busca o recado pelo feed do requisitante (fluxo + bloco de fixados) — confirma
    /// estado persistido pela mesma rota que o cliente usa.
    private static func findInFeed(app: Application, bearer: String, recadoID: UUID) async throws -> RecadoDTO {
        let page = try await Self.getFeed(app: app, bearer: bearer)
        let all = page.pinned + page.items
        return try XCTUnwrap(all.first { $0.id == recadoID }, "recado \(recadoID) ausente do feed")
    }

    // MARK: Task 2 — edição com semântica de presença

    func testUpdateWithoutReminderKeysPreservesStoredReminder() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let eventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "com lembrete",
                eventAt: eventAt, remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // Corpo que NÃO fala de lembrete — nenhuma das duas chaves presente.
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"texto corrigido","mentionedUserIDs":[]}"#
            )

            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertEqual(dto.text, "texto corrigido")
            XCTAssertEqual(dto.eventAt, eventAt, "não veio = preserva: mesmo instante")
            XCTAssertEqual(dto.remindOffsetSeconds, 900, "não veio = preserva: mesma antecedência")
        }
    }

    func testUpdateWithExplicitNullReminderClearsIt() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "com lembrete",
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200), remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // As duas chaves PRESENTES e nulas — "veio nulo" é remoção, não sinônimo de
            // "não veio".
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"com lembrete","mentionedUserIDs":[],"eventAt":null,"remindOffsetSeconds":null}"#
            )

            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertNil(dto.eventAt, "veio nulo = remove")
            XCTAssertNil(dto.remindOffsetSeconds)

            // E o estado persistido concorda com a resposta.
            let inFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recadoID)
            XCTAssertNil(inFeed.eventAt)
            XCTAssertNil(inFeed.remindOffsetSeconds)
        }
    }

    func testUpdateWithNewValidPairReplacesTheStoredOne() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "com lembrete",
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200), remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let newEventAt = Self.wholeSecondDate(secondsFromNow: 14400)
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"com lembrete","mentionedUserIDs":[],"eventAt":"\#(Self.iso(newEventAt))","remindOffsetSeconds":3600}"#
            )

            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertEqual(dto.eventAt, newEventAt, "par novo substitui o guardado")
            XCTAssertEqual(dto.remindOffsetSeconds, 3600)
        }
    }

    func testUpdateOfHistoricRecadoWithPastReminderIsAllowed() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let posted = try await Self.postRecado(app: app, bearer: author.token, text: "consulta do mês passado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // Lembrete já VENCIDO gravado direto no banco — a rota recusa criar par
            // vencido (e é isso mesmo), então este é o único caminho para o cenário.
            let pastEventAt = Self.wholeSecondDate(secondsFromNow: -86400)
            try await Self.writeReminderDirectly(
                app: app, householdID: household.id, recadoID: recadoID,
                eventAt: pastEventAt, remindOffsetSeconds: 900
            )

            // Corrigir o texto SEM falar de lembrete: a validação de passado não pode
            // rodar — não há par novo no corpo.
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"consulta do mês passado (corrigido)","mentionedUserIDs":[]}"#
            )

            XCTAssertEqual(patched.status, .ok, "corrigir recado antigo nunca é bloqueado pela validação de passado")
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertEqual(dto.eventAt, pastEventAt, "o lembrete vencido é preservado intocado")
            XCTAssertEqual(dto.remindOffsetSeconds, 900)
        }
    }

    func testUpdateWithNewPairWhoseFireTimeIsInThePastIsRejectedAndNothingChanges() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let originalEventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "original",
                eventAt: originalEventAt, remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // Evento daqui a dez minutos com um dia de antecedência: disparo no passado.
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"tentativa","mentionedUserIDs":[],"eventAt":"\#(Self.iso(Self.wholeSecondDate(secondsFromNow: 600)))","remindOffsetSeconds":86400}"#
            )

            XCTAssertEqual(patched.status, .badRequest)
            XCTAssertEqual(patched.error?.code, .validation)

            let inFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recadoID)
            XCTAssertEqual(inFeed.text, "original", "nada mudou depois da recusa")
            XCTAssertEqual(inFeed.eventAt, originalEventAt)
            XCTAssertEqual(inFeed.remindOffsetSeconds, 900)
        }
    }

    func testUpdateWithOffsetOutsideTheClosedSetIsRejectedAndNothingChanges() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let originalEventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "original",
                eventAt: originalEventAt, remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"tentativa","mentionedUserIDs":[],"eventAt":"\#(Self.iso(Self.wholeSecondDate(secondsFromNow: 7200)))","remindOffsetSeconds":600}"#
            )

            XCTAssertEqual(patched.status, .badRequest)
            XCTAssertEqual(patched.error?.code, .validation)

            let inFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recadoID)
            XCTAssertEqual(inFeed.eventAt, originalEventAt)
            XCTAssertEqual(inFeed.remindOffsetSeconds, 900)
        }
    }

    func testUpdateWithHalfPairIsRejectedAndNothingChanges() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let originalEventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "original",
                eventAt: originalEventAt, remindOffsetSeconds: 900
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // Só uma das duas chaves (a outra AUSENTE).
            let onlyEvent = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"tentativa","mentionedUserIDs":[],"eventAt":"\#(Self.iso(Self.wholeSecondDate(secondsFromNow: 7200)))"}"#
            )
            XCTAssertEqual(onlyEvent.status, .badRequest)
            XCTAssertEqual(onlyEvent.error?.code, .validation)

            // Uma preenchida e a outra NULA.
            let mixedNull = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"tentativa","mentionedUserIDs":[],"eventAt":null,"remindOffsetSeconds":900}"#
            )
            XCTAssertEqual(mixedNull.status, .badRequest)
            XCTAssertEqual(mixedNull.error?.code, .validation)

            let inFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recadoID)
            XCTAssertEqual(inFeed.eventAt, originalEventAt, "nada mudou depois das duas recusas")
            XCTAssertEqual(inFeed.remindOffsetSeconds, 900)
        }
    }

    func testNonAuthorWithMalformedReminderGetsNotAuthorNotValidation() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]
            let nonAuthor = members[2]

            let posted = try await Self.postRecado(app: app, bearer: author.token, text: "recado alheio")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // O corpo do não-autor carrega um lembrete MALFORMADO de propósito: se a
            // resposta fosse .validation, a rota teria interpretado o corpo antes de
            // checar autoria (T-02-60/T-02-84).
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: nonAuthor.token, recadoID: recadoID,
                json: #"{"text":"invadindo","mentionedUserIDs":[],"eventAt":null,"remindOffsetSeconds":900}"#
            )

            XCTAssertEqual(patched.status, .forbidden)
            XCTAssertEqual(patched.error?.code, .notAuthor, "autoria vem ANTES de qualquer interpretação do corpo")
        }
    }

    func testUpdateAbsentOverAbsentInventsNothing() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let posted = try await Self.postRecado(app: app, bearer: author.token, text: "sem lembrete")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"sem lembrete ainda","mentionedUserIDs":[]}"#
            )

            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertNil(dto.eventAt, "ausente sobre ausente não inventa nada")
            XCTAssertNil(dto.remindOffsetSeconds)
        }
    }

    func testLegacyClientBodyWithoutReminderKeysPreservesStoredReminder() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let eventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "com lembrete",
                eventAt: eventAt, remindOffsetSeconds: 300
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // O corpo EXATO que um cliente anterior a este plano monta (só texto e
            // menções — nem localização, nem lembrete): compatibilidade para trás é
            // comportamento testado, não promessa.
            let patched = try await Self.patchRecadoRawJSON(
                app: app, bearer: author.token, recadoID: recadoID,
                json: #"{"text":"editado por cliente antigo","mentionedUserIDs":[]}"#
            )

            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertEqual(dto.eventAt, eventAt, "um cliente que não conhece lembrete nunca apaga o de ninguém")
            XCTAssertEqual(dto.remindOffsetSeconds, 300)
        }
    }

    // MARK: Task 1 — fatia traçadora: criação com lembrete

    func testCreateWithValidReminderEchoesThePair() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            let eventAt = Self.wholeSecondDate(secondsFromNow: 7200)
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "consulta do pediatra",
                eventAt: eventAt, remindOffsetSeconds: 3600
            )

            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertEqual(dto.eventAt, eventAt, "o instante do evento volta exatamente como foi enviado")
            XCTAssertEqual(dto.remindOffsetSeconds, 3600, "a antecedência volta exatamente como foi enviada")
        }
    }

    func testEveryOffsetInTheClosedSetIsAccepted() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            // Percorre `allCases` em vez de repetir seis literais — se alguém acrescentar
            // um sétimo valor ao enum, este teste passa a cobri-lo sozinho.
            for offset in ReminderOffset.allCases {
                // Evento longe o bastante para o disparo (evento − antecedência) ficar no
                // futuro mesmo com a maior antecedência do conjunto.
                let eventAt = Self.wholeSecondDate(
                    secondsFromNow: TimeInterval(offset.rawValue) + 3600
                )
                let posted = try await Self.postRecado(
                    app: app, bearer: author.token, text: "evento \(offset.rawValue)s",
                    eventAt: eventAt, remindOffsetSeconds: offset.rawValue
                )
                XCTAssertEqual(posted.status, .created, "antecedência \(offset.rawValue)s é do conjunto fechado")
                XCTAssertEqual(posted.dto?.remindOffsetSeconds, offset.rawValue)
                XCTAssertEqual(posted.dto?.eventAt, eventAt)
            }
        }
    }

    func testOffsetOutsideTheClosedSetIsRejectedAndNothingIsStored() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            // Dez minutos em segundos — plausível, mas fora do conjunto fechado.
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "não deve existir",
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200), remindOffsetSeconds: 600
            )

            XCTAssertEqual(posted.status, .badRequest)
            XCTAssertEqual(posted.error?.code, .validation, "400 tipado do próprio projeto, nunca o genérico")

            let feed = try await Self.getFeed(app: app, bearer: author.token)
            XCTAssertTrue(feed.items.isEmpty, "nenhum recado foi gravado depois da recusa")
        }
    }

    func testNegativeOffsetIsRejectedByTheSamePath() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            // Negativa nunca está no conjunto fechado — não existe regra separada para ela.
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "não deve existir",
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200), remindOffsetSeconds: -300
            )

            XCTAssertEqual(posted.status, .badRequest)
            XCTAssertEqual(posted.error?.code, .validation)
        }
    }

    func testHalfPairIsRejectedInBothDirections() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            // Só o instante do evento, sem antecedência.
            let onlyEvent = try await Self.postRecado(
                app: app, bearer: author.token, text: "metade um",
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200)
            )
            XCTAssertEqual(onlyEvent.status, .badRequest)
            XCTAssertEqual(onlyEvent.error?.code, .validation)

            // Só a antecedência, sem instante.
            let onlyOffset = try await Self.postRecado(
                app: app, bearer: author.token, text: "metade dois",
                remindOffsetSeconds: 900
            )
            XCTAssertEqual(onlyOffset.status, .badRequest)
            XCTAssertEqual(onlyOffset.error?.code, .validation)

            let feed = try await Self.getFeed(app: app, bearer: author.token)
            XCTAssertTrue(feed.items.isEmpty, "nada foi persistido em nenhuma das duas metades")
        }
    }

    func testPairWhoseFireTimeIsInThePastIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]

            // Evento daqui a dez minutos com antecedência de um dia: o EVENTO está no
            // futuro, mas o disparo (evento − antecedência) já passou — o evento estar no
            // futuro não basta.
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "disparo no passado",
                eventAt: Self.wholeSecondDate(secondsFromNow: 600),
                remindOffsetSeconds: ReminderOffset.oneDay.rawValue
            )

            XCTAssertEqual(posted.status, .badRequest)
            XCTAssertEqual(posted.error?.code, .validation)
        }
    }

    func testCreateWithoutReminderStillWorksWithMentionAndLocation() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]
            let mentioned = members[0]

            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "sem lembrete nenhum",
                mentionedUserIDs: [mentioned.userID],
                location: RecadoLocationDTO(text: "Praça Central", lat: -27.59, lng: -48.55)
            )

            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertNil(dto.eventAt, "sem lembrete: as duas pontas ausentes na DTO")
            XCTAssertNil(dto.remindOffsetSeconds)
            XCTAssertEqual(dto.mentions.map(\.userID), [mentioned.userID], "menção continua funcionando")
            XCTAssertEqual(dto.location?.text, "Praça Central", "localização continua funcionando")
        }
    }

    func testInvalidReminderRejectsTheWholeRequestIncludingMentions() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[1]
            let mentioned = members[0]

            // O corpo traz uma menção VÁLIDA junto do par inválido: se qualquer coisa
            // fosse persistida pela metade, a linha de menção denunciaria.
            let posted = try await Self.postRecado(
                app: app, bearer: author.token, text: "não deve existir",
                mentionedUserIDs: [mentioned.userID],
                eventAt: Self.wholeSecondDate(secondsFromNow: 7200), remindOffsetSeconds: 600
            )

            XCTAssertEqual(posted.status, .badRequest)
            XCTAssertEqual(posted.error?.code, .validation)

            let feed = try await Self.getFeed(app: app, bearer: author.token)
            XCTAssertTrue(feed.items.isEmpty, "o recado não existe depois da recusa")

            let mentionRows = try await Self.countAllMentionRows(app: app, householdID: household.id)
            XCTAssertEqual(mentionRows, 0, "a pessoa marcada no mesmo corpo não recebeu linha de menção")
        }
    }
}

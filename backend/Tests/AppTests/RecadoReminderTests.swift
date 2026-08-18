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

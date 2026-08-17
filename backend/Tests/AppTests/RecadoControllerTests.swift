@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Prova ponta a ponta do plano 02-01 (MURAL-01 parte texto, MURAL-05): postar um recado de
/// texto e lê-lo de volta no feed cronológico da própria casa, contra Postgres real.
final class RecadoControllerTests: XCTestCase {
    // MARK: Helpers de request (mesmo padrão de DeviceTokenTests)

    private static func postRecado(
        app: Application,
        bearer: String,
        rawBody: [String: String]? = nil,
        text: String? = nil,
        mentionedUserIDs: [UUID] = []
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: RecadoDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                if let rawBody {
                    try req.content.encode(rawBody, as: .json)
                } else {
                    try req.content.encode(
                        CreateRecadoRequest(text: text, mentionedUserIDs: mentionedUserIDs), as: .json
                    )
                }
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
    ) async throws -> (status: HTTPStatus, page: RecadoFeedPage?) {
        var path = "/api/v1/recados"
        if let cursor {
            path += "?cursor=\(cursor)"
        }
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedPage: RecadoFeedPage?
        try await app.testable().test(
            .GET, path,
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedPage = try res.content.decode(RecadoFeedPage.self)
                }
            }
        )
        return (capturedStatus, capturedPage)
    }

    private static func patchRecado(
        app: Application,
        bearer: String,
        recadoID: UUID,
        text: String?,
        mentionedUserIDs: [UUID] = []
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: RecadoDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .PATCH, "/api/v1/recados/\(recadoID.uuidString)",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(UpdateRecadoRequest(text: text, mentionedUserIDs: mentionedUserIDs), as: .json)
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

    private static func deleteRecado(
        app: Application,
        bearer: String,
        recadoID: UUID
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .DELETE, "/api/v1/recados/\(recadoID.uuidString)",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status != .noContent {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedError)
    }

    private static func countMentionRows(
        app: Application,
        householdID: UUID,
        recadoID: UUID
    ) async throws -> Int {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            try await sql.raw(
                "SELECT * FROM recado_mentions WHERE recado_id = \(bind: recadoID)"
            ).all().count
        }
    }

    private static func fetchMentionCreatedAt(
        app: Application,
        householdID: UUID,
        recadoID: UUID,
        mentionedUserID: UUID
    ) async throws -> Date? {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            guard let row = try await sql.raw("""
                SELECT created_at FROM recado_mentions
                WHERE recado_id = \(bind: recadoID) AND mentioned_user_id = \(bind: mentionedUserID)
                """).first() else {
                return nil
            }
            return try row.decode(column: "created_at", as: Date.self)
        }
    }

    // MARK: Task 1 — fatia ponta a ponta

    func testPostTextRecadoThenFeedReturnsIt() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "Bom dia, família!")
            XCTAssertEqual(posted.status, .created)
            let createdDTO = try XCTUnwrap(posted.dto)
            XCTAssertEqual(createdDTO.text, "Bom dia, família!")
            XCTAssertTrue(createdDTO.isMine)

            let fetched = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(fetched.status, .ok)
            let page = try XCTUnwrap(fetched.page)
            let first = try XCTUnwrap(page.items.first)
            XCTAssertEqual(first.id, createdDTO.id)
            XCTAssertEqual(first.text, "Bom dia, família!")
            XCTAssertTrue(first.isMine, "o autor precisa ver isMine=true no próprio recado")
            XCTAssertTrue(first.photos.isEmpty)
            XCTAssertTrue(first.mentions.isEmpty)
            XCTAssertTrue(first.reactions.isEmpty)
            XCTAssertEqual(first.commentCount, 0)
        }
    }

    func testPostWithForgedAuthorAndHouseholdInBodyIsIgnored() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            // Corpo bruto (não `CreateRecadoRequest`, que nem carrega esses campos) com
            // `authorId`/`householdId` forjados — a decodificação ignora as chaves que o
            // tipo não declara, então isto prova que o servidor nunca lê esses valores do
            // request, mesmo que estejam no JSON (mesmo padrão de
            // `testRegisterNewDeviceScopesToServerResolvedIdentityIgnoringBodyOverride`).
            let bogusAuthorID = UUID()
            let bogusHouseholdID = UUID()
            let posted = try await Self.postRecado(
                app: app,
                bearer: admin.token,
                rawBody: [
                    "text": "recado normal",
                    "authorId": bogusAuthorID.uuidString,
                    "householdId": bogusHouseholdID.uuidString,
                ]
            )
            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertEqual(dto.authorID, admin.userID)
            XCTAssertNotEqual(dto.authorID, bogusAuthorID)
        }
    }

    func testPostRecadoWithNullTextIsAccepted() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            // D-01: um recado só-foto nasce vazio (texto nulo) e ganha as fotos no confirm
            // do plano 02-04 — a regra "texto OU foto" é do compose, não desta rota.
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: nil)
            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertNil(dto.text)
        }
    }

    // MARK: Task 2 — edição/remoção só pelo autor (D-03), 404 vs 403

    func testAnotherMemberCannotEditRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado do admin")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let patched = try await Self.patchRecado(
                app: app, bearer: adult.token, recadoID: recadoID, text: "editado por outro"
            )
            XCTAssertEqual(patched.status, .forbidden)
            XCTAssertEqual(patched.error?.code, .notAuthor)
        }
    }

    func testAdminCannotEditAnotherMembersRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]

            let posted = try await Self.postRecado(app: app, bearer: adult.token, text: "recado do adulto")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // D-03: sem exceção de moderação para admin — este é o teste que garante isso.
            let patched = try await Self.patchRecado(
                app: app, bearer: admin.token, recadoID: recadoID, text: "editado pelo admin"
            )
            XCTAssertEqual(patched.status, .forbidden)
            XCTAssertEqual(patched.error?.code, .notAuthor)
        }
    }

    func testAnotherMemberCannotDeleteRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado do admin")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let deleted = try await Self.deleteRecado(app: app, bearer: adult.token, recadoID: recadoID)
            XCTAssertEqual(deleted.status, .forbidden)
            XCTAssertEqual(deleted.error?.code, .notAuthor)
        }
    }

    func testAdminCannotDeleteAnotherMembersRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]

            let posted = try await Self.postRecado(app: app, bearer: adult.token, text: "recado do adulto")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let deleted = try await Self.deleteRecado(app: app, bearer: admin.token, recadoID: recadoID)
            XCTAssertEqual(deleted.status, .forbidden)
            XCTAssertEqual(deleted.error?.code, .notAuthor)
        }
    }

    func testAuthorCanEditOwnRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "texto original")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let patched = try await Self.patchRecado(
                app: app, bearer: admin.token, recadoID: recadoID, text: "texto novo"
            )
            XCTAssertEqual(patched.status, .ok)
            XCTAssertEqual(patched.dto?.text, "texto novo")
        }
    }

    func testAuthorCanDeleteOwnRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "para apagar")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let deleted = try await Self.deleteRecado(app: app, bearer: admin.token, recadoID: recadoID)
            XCTAssertEqual(deleted.status, .noContent)

            let fetched = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(fetched.page?.items.contains(where: { $0.id == recadoID }), false)
        }
    }

    func testRecadoFromAnotherHouseholdIsNotFound() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            let posted = try await Self.postRecado(app: app, bearer: adminB.token, text: "recado da casa B")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // RLS já escopou a consulta na casa do requisitante — um recado de outra casa
            // cai aqui como inexistente, não como proibido (404, nunca 403).
            let patched = try await Self.patchRecado(
                app: app, bearer: adminA.token, recadoID: recadoID, text: "tentativa"
            )
            XCTAssertEqual(patched.status, .notFound)

            let deleted = try await Self.deleteRecado(app: app, bearer: adminA.token, recadoID: recadoID)
            XCTAssertEqual(deleted.status, .notFound)
        }
    }

    // MARK: Plano 02-02 — menções estruturadas (D-05, D-06)

    func testMentioningThreeMembersWritesThreeMentionRows() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 4)
            let admin = members[0]
            let mentionedIDs = [members[1].userID, members[2].userID, members[3].userID]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "reunião hoje", mentionedUserIDs: mentionedIDs
            )
            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertEqual(Set(dto.mentions.map(\.userID)), Set(mentionedIDs))

            let recadoID = try XCTUnwrap(dto.id)
            let count = try await Self.countMentionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 3)
        }
    }

    func testMentioningUserFromAnotherHouseholdIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            let posted = try await Self.postRecado(
                app: app, bearer: adminA.token, text: "recado", mentionedUserIDs: [adminB.userID]
            )
            XCTAssertEqual(posted.status, .unprocessableEntity)
            XCTAssertEqual(posted.error?.code, .notHouseholdMember)
        }
    }

    func testMentioningUnknownUUIDIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado", mentionedUserIDs: [UUID()]
            )
            XCTAssertEqual(posted.status, .unprocessableEntity)
            XCTAssertEqual(posted.error?.code, .notHouseholdMember)
        }
    }

    func testDuplicateMentionIDsCollapseToOneRow() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado",
                mentionedUserIDs: [adult.userID, adult.userID]
            )
            XCTAssertEqual(posted.status, .created)
            let dto = try XCTUnwrap(posted.dto)
            XCTAssertEqual(dto.mentions.count, 1)

            let recadoID = try XCTUnwrap(dto.id)
            let count = try await Self.countMentionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 1, "ids repetidos geram uma única linha, não erro de constraint")
        }
    }

    func testEmptyMentionListCreatesRecadoWithoutMentions() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado sem marcação", mentionedUserIDs: []
            )
            XCTAssertEqual(posted.status, .created)
            XCTAssertEqual(posted.dto?.mentions.isEmpty, true)
        }
    }

    func testPatchReplacesMentionSetPreservingSurvivingRows() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 4)
            let admin = members[0]
            let keptMember = members[1]
            let removedMember = members[2]
            let addedMember = members[3]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "original",
                mentionedUserIDs: [keptMember.userID, removedMember.userID]
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let keptCreatedAtBefore = try await Self.fetchMentionCreatedAt(
                app: app, householdID: household.id, recadoID: recadoID, mentionedUserID: keptMember.userID
            )
            XCTAssertNotNil(keptCreatedAtBefore)

            try await Task.sleep(nanoseconds: 10_000_000) // 10ms — garante created_at mensurável se recriado

            let patched = try await Self.patchRecado(
                app: app, bearer: admin.token, recadoID: recadoID, text: "editado",
                mentionedUserIDs: [keptMember.userID, addedMember.userID]
            )
            XCTAssertEqual(patched.status, .ok)
            let dto = try XCTUnwrap(patched.dto)
            XCTAssertEqual(Set(dto.mentions.map(\.userID)), Set([keptMember.userID, addedMember.userID]))

            let count = try await Self.countMentionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 2, "a retirada some, a acrescentada entra, a mantida não duplica")

            let keptCreatedAtAfter = try await Self.fetchMentionCreatedAt(
                app: app, householdID: household.id, recadoID: recadoID, mentionedUserID: keptMember.userID
            )
            XCTAssertEqual(
                keptCreatedAtAfter, keptCreatedAtBefore,
                "a linha de menção que permanece mantém o created_at original, não é apagada+recriada"
            )
        }
    }

    func testRejectedMentionLeavesNoRecadoRow() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "não deveria existir", mentionedUserIDs: [UUID()]
            )
            XCTAssertEqual(posted.status, .unprocessableEntity)

            let fetched = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(fetched.page?.items.isEmpty, true, "nenhum recado deve ter sido gravado")
        }
    }
}

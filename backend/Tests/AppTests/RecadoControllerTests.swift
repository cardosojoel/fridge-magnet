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

    // MARK: Helpers de request — plano 02-03 (reações)

    private static func putReaction(
        app: Application,
        bearer: String,
        recadoID: UUID,
        rawBody: [String: String]? = nil,
        kind: ReactionKind? = nil
    ) async throws -> (status: HTTPStatus, summary: RecadoReactionSummaryDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedSummary: RecadoReactionSummaryDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .PUT, "/api/v1/recados/\(recadoID.uuidString)/reactions",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                if let rawBody {
                    try req.content.encode(rawBody, as: .json)
                } else if let kind {
                    try req.content.encode(SetReactionRequest(kind: kind), as: .json)
                }
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedSummary = try res.content.decode(RecadoReactionSummaryDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedSummary, capturedError)
    }

    private static func deleteReaction(
        app: Application,
        bearer: String,
        recadoID: UUID
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .DELETE, "/api/v1/recados/\(recadoID.uuidString)/reactions",
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

    private static func countReactionRows(
        app: Application,
        householdID: UUID,
        recadoID: UUID
    ) async throws -> Int {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            try await sql.raw(
                "SELECT * FROM recado_reactions WHERE recado_id = \(bind: recadoID)"
            ).all().count
        }
    }

    private static func fetchReactionKindAndUpdatedAt(
        app: Application,
        householdID: UUID,
        recadoID: UUID,
        userID: UUID
    ) async throws -> (kind: String, updatedAt: Date)? {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            guard let row = try await sql.raw("""
                SELECT kind, updated_at FROM recado_reactions
                WHERE recado_id = \(bind: recadoID) AND user_id = \(bind: userID)
                """).first() else {
                return nil
            }
            let kind = try row.decode(column: "kind", as: String.self)
            let updatedAt = try row.decode(column: "updated_at", as: Date.self)
            return (kind, updatedAt)
        }
    }

    // MARK: Helpers de request — plano 02-03 (comentários)

    private static func postComment(
        app: Application,
        bearer: String,
        recadoID: UUID,
        rawBody: [String: String]? = nil,
        text: String? = nil,
        mentionedUserIDs: [UUID] = []
    ) async throws -> (status: HTTPStatus, dto: CommentDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: CommentDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados/\(recadoID.uuidString)/comments",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                if let rawBody {
                    try req.content.encode(rawBody, as: .json)
                } else {
                    try req.content.encode(
                        CreateCommentRequest(text: text ?? "", mentionedUserIDs: mentionedUserIDs), as: .json
                    )
                }
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTO = try res.content.decode(CommentDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    private static func getComments(
        app: Application,
        bearer: String,
        recadoID: UUID
    ) async throws -> (status: HTTPStatus, comments: [CommentDTO]?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedComments: [CommentDTO]?
        try await app.testable().test(
            .GET, "/api/v1/recados/\(recadoID.uuidString)/comments",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedComments = try res.content.decode([CommentDTO].self)
                }
            }
        )
        return (capturedStatus, capturedComments)
    }

    private static func countCommentRows(
        app: Application,
        householdID: UUID,
        recadoID: UUID
    ) async throws -> Int {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            try await sql.raw(
                "SELECT * FROM recado_comments WHERE recado_id = \(bind: recadoID)"
            ).all().count
        }
    }

    private static func mentionHasCommentParentOnly(
        app: Application,
        householdID: UUID,
        commentID: UUID,
        mentionedUserID: UUID
    ) async throws -> Bool {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            guard let row = try await sql.raw("""
                SELECT (recado_id IS NULL AND comment_id = \(bind: commentID)) AS ok
                FROM recado_mentions
                WHERE comment_id = \(bind: commentID) AND mentioned_user_id = \(bind: mentionedUserID)
                """).first() else {
                return false
            }
            return try row.decode(column: "ok", as: Bool.self)
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

    // MARK: Plano 02-03 — reações de conjunto fechado (D-07, D-07b)

    func testReactingWritesRowAndReturnsSummary() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let reacted = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .love)
            XCTAssertEqual(reacted.status, .ok)
            XCTAssertEqual(reacted.summary?.myReaction, .love)
            XCTAssertEqual(reacted.summary?.reactions.first?.kind, .love)
            XCTAssertEqual(reacted.summary?.reactions.first?.count, 1)

            let count = try await Self.countReactionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 1)
        }
    }

    func testReactingTwiceReplacesInsteadOfAccumulating() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let firstReaction = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .love)
            XCTAssertEqual(firstReaction.status, .ok)

            try await Task.sleep(nanoseconds: 10_000_000) // garante updated_at mensurável se recriado

            let secondReaction = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .laugh)
            XCTAssertEqual(secondReaction.status, .ok)
            XCTAssertEqual(secondReaction.summary?.myReaction, .laugh)

            let count = try await Self.countReactionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 1, "trocar de emoji substitui a anterior, nunca acumula (D-07b)")

            let row = try await Self.fetchReactionKindAndUpdatedAt(
                app: app, householdID: household.id, recadoID: recadoID, userID: admin.userID
            )
            XCTAssertEqual(row?.kind, "laugh")
        }
    }

    func testOutOfSetReactionKindIsRejectedWithoutWritingRow() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let reacted = try await Self.putReaction(
                app: app, bearer: admin.token, recadoID: recadoID, rawBody: ["kind": "fogo"]
            )
            XCTAssertEqual(reacted.status, .badRequest)

            let count = try await Self.countReactionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 0, "um valor fora do conjunto fechado nunca grava nenhuma linha")
        }
    }

    func testMissingReactionKindIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let reacted = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, rawBody: [:])
            XCTAssertEqual(reacted.status, .badRequest)
        }
    }

    func testTwoDifferentPeopleReactingProducesSummaryCountByKind() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            _ = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .love)
            let secondReaction = try await Self.putReaction(app: app, bearer: adult.token, recadoID: recadoID, kind: .love)
            XCTAssertEqual(secondReaction.status, .ok)
            XCTAssertEqual(secondReaction.summary?.reactions.first(where: { $0.kind == .love })?.count, 2)
        }
    }

    func testClearingReactionOnlyRemovesRequesterRow() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            _ = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .love)
            _ = try await Self.putReaction(app: app, bearer: adult.token, recadoID: recadoID, kind: .wow)

            let cleared = try await Self.deleteReaction(app: app, bearer: adult.token, recadoID: recadoID)
            XCTAssertEqual(cleared.status, .noContent)

            let count = try await Self.countReactionRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 1, "B apagando a própria reação não remove a de A")

            let row = try await Self.fetchReactionKindAndUpdatedAt(
                app: app, householdID: household.id, recadoID: recadoID, userID: admin.userID
            )
            XCTAssertNotNil(row, "a reação de A continua intacta")
        }
    }

    func testClearingReactionWithoutActiveOneIsIdempotent() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let cleared = try await Self.deleteReaction(app: app, bearer: admin.token, recadoID: recadoID)
            XCTAssertEqual(cleared.status, .noContent, "DELETE sem reação ativa é idempotente, sem erro")
        }
    }

    func testReactionSummaryCountsByKindAndReportsMyReaction() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let adult1 = members[1]
            let adult2 = members[2]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            _ = try await Self.putReaction(app: app, bearer: admin.token, recadoID: recadoID, kind: .love)
            _ = try await Self.putReaction(app: app, bearer: adult1.token, recadoID: recadoID, kind: .love)
            _ = try await Self.putReaction(app: app, bearer: adult2.token, recadoID: recadoID, kind: .wow)

            let fetched = try await Self.getFeed(app: app, bearer: admin.token)
            let dto = try XCTUnwrap(fetched.page?.items.first(where: { $0.id == recadoID }))
            XCTAssertEqual(dto.myReaction, .love, "o resumo do feed traz a reação do próprio requisitante")
            XCTAssertEqual(dto.reactions.first(where: { $0.kind == .love })?.count, 2)
            XCTAssertEqual(dto.reactions.first(where: { $0.kind == .wow })?.count, 1)
        }
    }

    func testReactAndClearOnRecadoFromAnotherHouseholdReturnsNotFound() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]
            let posted = try await Self.postRecado(app: app, bearer: adminB.token, text: "recado da casa B")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let reacted = try await Self.putReaction(app: app, bearer: adminA.token, recadoID: recadoID, kind: .love)
            XCTAssertEqual(reacted.status, .notFound)

            let cleared = try await Self.deleteReaction(app: app, bearer: adminA.token, recadoID: recadoID)
            XCTAssertEqual(cleared.status, .notFound)
        }
    }

    func testReactionWithForgedUserIdInBodyUsesJWTIdentity() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let bogusUserID = UUID()
            let reacted = try await Self.putReaction(
                app: app, bearer: admin.token, recadoID: recadoID,
                rawBody: ["kind": "love", "userId": bogusUserID.uuidString]
            )
            XCTAssertEqual(reacted.status, .ok)

            let row = try await Self.fetchReactionKindAndUpdatedAt(
                app: app, householdID: household.id, recadoID: recadoID, userID: admin.userID
            )
            XCTAssertNotNil(row, "a reação foi gravada com o user_id do JWT, não do corpo forjado")
        }
    }

    // MARK: Plano 02-03 — comentários em lista plana cronológica (D-08)

    func testCreateCommentReturnsCreatedWithAuthorInfo() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // MURAL-04: um membro comenta no recado de outro sem restrição de papel — é o
            // caminho normal, não uma exceção.
            let commented = try await Self.postComment(
                app: app, bearer: adult.token, recadoID: recadoID, text: "primeiro comentário"
            )
            XCTAssertEqual(commented.status, .created)
            let dto = try XCTUnwrap(commented.dto)
            XCTAssertEqual(dto.text, "primeiro comentário")
            XCTAssertTrue(dto.isMine)
            XCTAssertEqual(dto.authorID, adult.userID)
            XCTAssertEqual(dto.authorDisplayName, "Membro 1")
        }
    }

    func testCommentsAreFlatAndChronological() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            _ = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: "primeiro")
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: "segundo")
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: "terceiro")

            let fetched = try await Self.getComments(app: app, bearer: admin.token, recadoID: recadoID)
            XCTAssertEqual(fetched.status, .ok)
            let comments = try XCTUnwrap(fetched.comments)
            XCTAssertEqual(
                comments.map(\.text), ["primeiro", "segundo", "terceiro"],
                "lista plana em ordem cronológica crescente (D-08)"
            )
        }
    }

    func testEmptyCommentTextIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let commented = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: "   ")
            XCTAssertEqual(commented.status, .badRequest)
            XCTAssertEqual(commented.error?.code, .validation)

            let count = try await Self.countCommentRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 0)
        }
    }

    func testCommentTextOverLimitIsRejected() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let longText = String(repeating: "a", count: 5001)
            let commented = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: longText)
            XCTAssertEqual(commented.status, .badRequest)
            XCTAssertEqual(commented.error?.code, .validation)
        }
    }

    func testCommentMentionOutsideHouseholdIsRejectedWritingNoRows() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let commented = try await Self.postComment(
                app: app, bearer: admin.token, recadoID: recadoID, text: "comentário", mentionedUserIDs: [UUID()]
            )
            XCTAssertEqual(commented.status, .unprocessableEntity)
            XCTAssertEqual(commented.error?.code, .notHouseholdMember)

            let count = try await Self.countCommentRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(count, 0, "menção fora da casa recusa o comentário inteiro, nenhuma linha gravada")
        }
    }

    func testCommentMentionWritesRowWithCommentParent() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let commented = try await Self.postComment(
                app: app, bearer: admin.token, recadoID: recadoID, text: "olha isso", mentionedUserIDs: [adult.userID]
            )
            XCTAssertEqual(commented.status, .created)
            let commentID = try XCTUnwrap(commented.dto?.id)
            XCTAssertEqual(commented.dto?.mentions.map(\.userID), [adult.userID])

            let hasCommentParentOnly = try await Self.mentionHasCommentParentOnly(
                app: app, householdID: household.id, commentID: commentID, mentionedUserID: adult.userID
            )
            XCTAssertTrue(hasCommentParentOnly, "a menção do comentário grava comment_id, recado_id fica nulo (D-09)")
        }
    }

    func testCommentAndListOnRecadoFromAnotherHouseholdReturnsNotFound() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]
            let posted = try await Self.postRecado(app: app, bearer: adminB.token, text: "recado da casa B")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let commented = try await Self.postComment(app: app, bearer: adminA.token, recadoID: recadoID, text: "tentativa")
            XCTAssertEqual(commented.status, .notFound)

            let fetched = try await Self.getComments(app: app, bearer: adminA.token, recadoID: recadoID)
            XCTAssertEqual(fetched.status, .notFound)
        }
    }

    func testCommentWithForgedAuthorIdUsesJWTIdentity() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let bogusAuthorID = UUID()
            let commented = try await Self.postComment(
                app: app, bearer: admin.token, recadoID: recadoID,
                rawBody: ["text": "comentário", "authorId": bogusAuthorID.uuidString]
            )
            XCTAssertEqual(commented.status, .created)
            XCTAssertEqual(commented.dto?.authorID, admin.userID)
            XCTAssertNotEqual(commented.dto?.authorID, bogusAuthorID)
        }
    }

    func testFeedCardShowsRealCommentCountAndLatestTwo() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            for index in 1...5 {
                _ = try await Self.postComment(app: app, bearer: admin.token, recadoID: recadoID, text: "comentário \(index)")
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let fetched = try await Self.getFeed(app: app, bearer: admin.token)
            let dto = try XCTUnwrap(fetched.page?.items.first(where: { $0.id == recadoID }))
            XCTAssertEqual(dto.commentCount, 5)
            XCTAssertEqual(dto.latestComments.map(\.text), ["comentário 4", "comentário 5"])
        }
    }

    func testDeletingRecadoDeletesItsComments() async throws {
        try await TestSupport.withApp { app in
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado")
            let recadoID = try XCTUnwrap(posted.dto?.id)

            let commented = try await Self.postComment(
                app: app, bearer: adult.token, recadoID: recadoID, text: "vai sumir", mentionedUserIDs: [admin.userID]
            )
            let commentID = try XCTUnwrap(commented.dto?.id)

            let deleted = try await Self.deleteRecado(app: app, bearer: admin.token, recadoID: recadoID)
            XCTAssertEqual(deleted.status, .noContent)

            let commentCount = try await Self.countCommentRows(app: app, householdID: household.id, recadoID: recadoID)
            XCTAssertEqual(commentCount, 0, "apagar o recado apaga os comentários dele")

            let mentionCount = try await TestSupport.withAppRoleConnection(app: app, householdID: household.id) { sql in
                try await sql.raw("SELECT * FROM recado_mentions WHERE comment_id = \(bind: commentID)").all().count
            }
            XCTAssertEqual(mentionCount, 0, "as menções desse comentário também somem")
        }
    }
}

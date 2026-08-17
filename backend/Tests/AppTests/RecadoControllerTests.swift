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
        text: String? = nil
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
                    try req.content.encode(CreateRecadoRequest(text: text), as: .json)
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
}

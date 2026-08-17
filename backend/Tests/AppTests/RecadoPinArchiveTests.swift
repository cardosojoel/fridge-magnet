@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// D-14/D-15 (plano 02-11): fixar/desafixar e arquivar/desarquivar com a matriz de
/// autorização completa — autor não-admin, admin e terceiro membro são casos DISTINTOS
/// (o autor dos recados de teste é sempre um adulto não-admin; sem isso "o autor pode" e
/// "o admin pode" não provariam duas origens independentes de permissão).
final class RecadoPinArchiveTests: XCTestCase {
    // MARK: Helpers privados de request (convenção do repositório — cada classe de teste
    // tem os próprios auxiliares, molde de `RecadoControllerTests`)

    private static func postRecado(app: Application, bearer: String, text: String) async throws -> RecadoDTO {
        var captured: RecadoDTO?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(CreateRecadoRequest(text: text), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                captured = try res.content.decode(RecadoDTO.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    private static func getFeed(app: Application, bearer: String, cursor: Int64? = nil) async throws -> RecadoFeedPage {
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

    /// As rotas de fixar/desafixar nunca mandam corpo — não existe campo que o cliente
    /// possa enviar que participe da decisão de autorização (T-02-66).
    @discardableResult
    private static func pinRequest(
        app: Application,
        method: HTTPMethod,
        bearer: String,
        recadoID: UUID
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        var status: HTTPStatus = .internalServerError
        var dto: RecadoDTO?
        try await app.testable().test(
            method, "/api/v1/recados/\(recadoID)/pin",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                status = res.status
                dto = try? res.content.decode(RecadoDTO.self)
            }
        )
        return (status, dto)
    }

    @discardableResult
    private static func pin(app: Application, bearer: String, recadoID: UUID) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        try await pinRequest(app: app, method: .PUT, bearer: bearer, recadoID: recadoID)
    }

    @discardableResult
    private static func unpin(app: Application, bearer: String, recadoID: UUID) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        try await pinRequest(app: app, method: .DELETE, bearer: bearer, recadoID: recadoID)
    }

    /// Encontra o recado no feed do requisitante (fluxo + bloco de fixados) — usado para
    /// confirmar estado persistido depois de uma operação, pela mesma rota que o cliente usa.
    private static func findInFeed(app: Application, bearer: String, recadoID: UUID) async throws -> RecadoDTO {
        let page = try await getFeed(app: app, bearer: bearer)
        let all = page.pinned + page.items
        return try XCTUnwrap(all.first { $0.id == recadoID }, "recado \(recadoID) ausente do feed")
    }

    // MARK: Task 1 — fixar/desafixar (D-14)

    func testAuthorNonAdminCanPinOwnRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "meu recado")
            let (status, dto) = try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNotNil(try XCTUnwrap(dto).pinnedAt, "fixar devolve o instante de fixação preenchido")
        }
    }

    func testAdminCanPinOtherMembersRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "recado do adulto")
            let (status, dto) = try await Self.pin(app: app, bearer: admin.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNotNil(try XCTUnwrap(dto).pinnedAt)
        }
    }

    func testThirdMemberCannotPinOthersRecadoAndNothingIsWritten() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]
            let third = members[2]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "recado alheio")
            let (status, _) = try await Self.pin(app: app, bearer: third.token, recadoID: recado.id)
            XCTAssertEqual(status, .forbidden)

            // Nada foi gravado: o recado continua não fixado no feed.
            let fromFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertNil(fromFeed.pinnedAt)
        }
    }

    func testUnpinFollowsSameAuthorizationMatrix() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]
            let third = members[2]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "para desafixar")

            // Autor fixa; terceiro membro NÃO desafixa (403) e a fixação permanece.
            try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)
            let (thirdStatus, _) = try await Self.unpin(app: app, bearer: third.token, recadoID: recado.id)
            XCTAssertEqual(thirdStatus, .forbidden)
            let stillPinned = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertNotNil(stillPinned.pinnedAt, "403 do terceiro membro não pode ter desafixado")

            // Admin desafixa recado alheio.
            let (adminStatus, adminDTO) = try await Self.unpin(app: app, bearer: admin.token, recadoID: recado.id)
            XCTAssertEqual(adminStatus, .ok)
            XCTAssertNil(try XCTUnwrap(adminDTO).pinnedAt)

            // Autor fixa de novo e desafixa o próprio.
            try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)
            let (authorStatus, authorDTO) = try await Self.unpin(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(authorStatus, .ok)
            XCTAssertNil(try XCTUnwrap(authorDTO).pinnedAt)
        }
    }

    func testPinIsIdempotentAndPreservesOriginalInstant() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "fixado duas vezes")

            let (firstStatus, firstDTO) = try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(firstStatus, .ok)
            let originalInstant = try XCTUnwrap(try XCTUnwrap(firstDTO).pinnedAt)

            // Retentativa de rede: fixar de novo devolve 200 e PRESERVA o instante
            // original — nunca reordena o bloco de fixados.
            let (secondStatus, secondDTO) = try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(secondStatus, .ok)
            let preservedInstant = try XCTUnwrap(try XCTUnwrap(secondDTO).pinnedAt)
            XCTAssertEqual(originalInstant, preservedInstant, "retentativa nunca sobrescreve o instante de fixação")
        }
    }

    func testUnpinWhenNotPinnedIsIdempotent() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "nunca fixado")
            let (status, dto) = try await Self.unpin(app: app, bearer: author.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNil(try XCTUnwrap(dto).pinnedAt)
        }
    }

    func testPinAndUnpinOnRecadoFromAnotherHouseholdIs404() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            let recadoB = try await Self.postRecado(app: app, bearer: adminB.token, text: "da casa B")

            // 404, nunca 403: a rota não confirma a existência de linha alheia (T-02-67).
            let (pinStatus, _) = try await Self.pin(app: app, bearer: adminA.token, recadoID: recadoB.id)
            XCTAssertEqual(pinStatus, .notFound)
            let (unpinStatus, _) = try await Self.unpin(app: app, bearer: adminA.token, recadoID: recadoB.id)
            XCTAssertEqual(unpinStatus, .notFound)
        }
    }

    func testPermissionSignalsArePerRequesterRole() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]
            let third = members[2]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "sinais de permissão")

            // Autor (adulto não-admin): pode fixar e arquivar, NUNCA desarquivar.
            let asAuthor = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertTrue(asAuthor.canPin)
            XCTAssertTrue(asAuthor.canArchive)
            XCTAssertFalse(asAuthor.canUnarchive)

            // Admin em recado alheio: pode tudo, inclusive desarquivar.
            let asAdmin = try await Self.findInFeed(app: app, bearer: admin.token, recadoID: recado.id)
            XCTAssertTrue(asAdmin.canPin)
            XCTAssertTrue(asAdmin.canArchive)
            XCTAssertTrue(asAdmin.canUnarchive)

            // Terceiro membro (nem autor nem admin): nenhum sinal.
            let asThird = try await Self.findInFeed(app: app, bearer: third.token, recadoID: recado.id)
            XCTAssertFalse(asThird.canPin)
            XCTAssertFalse(asThird.canArchive)
            XCTAssertFalse(asThird.canUnarchive)
        }
    }
}

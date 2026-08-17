@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Corretude da paginação por cursor do feed (MURAL-05) — 02-RESEARCH.md Pitfall 2: uma
/// linha inserida entre duas buscas de página nunca aparece duas vezes nem desaparece.
final class RecadoFeedPaginationTests: XCTestCase {
    // MARK: Helpers de request (copiados de RecadoControllerTests — convenção do repositório
    // já usada por `DeviceTokenTests`/`RLSIsolationTests`: cada classe de teste tem os
    // próprios auxiliares privados)

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

    @discardableResult
    private static func postRecados(
        app: Application,
        bearer: String,
        count: Int,
        prefix: String = "recado"
    ) async throws -> [RecadoDTO] {
        var results: [RecadoDTO] = []
        for index in 0..<count {
            results.append(try await postRecado(app: app, bearer: bearer, text: "\(prefix) \(index)"))
        }
        return results
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

    // MARK: Casos

    func testFeedReturnsNewestFirst() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecados(app: app, bearer: admin.token, count: 5)

            let page = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(page.items.map(\.id), posted.reversed().map(\.id))
        }
    }

    func testFeedPageSizeIsTwentyAndCursorAdvances() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let posted = try await Self.postRecados(app: app, bearer: admin.token, count: 25)

            let firstPage = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(firstPage.items.count, 20)
            let nextCursor = try XCTUnwrap(firstPage.nextCursor)

            let secondPage = try await Self.getFeed(app: app, bearer: admin.token, cursor: nextCursor)
            XCTAssertEqual(secondPage.items.count, 5)
            XCTAssertNil(secondPage.nextCursor)

            let allIDs = Set((firstPage.items + secondPage.items).map(\.id))
            XCTAssertEqual(allIDs.count, 25)
            XCTAssertEqual(Set(posted.map(\.id)), allIDs)
        }
    }

    func testNoDuplicateOrSkippedRowWhenRecadoInsertedBetweenPages() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let originalPosted = try await Self.postRecados(app: app, bearer: admin.token, count: 25)

            let firstPage = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertEqual(firstPage.items.count, 20)
            let cursor = try XCTUnwrap(firstPage.nextCursor)

            // Três recados novos entram no topo do feed ENTRE as duas buscas de página —
            // exatamente o cenário do Pitfall 2.
            try await Self.postRecados(app: app, bearer: admin.token, count: 3, prefix: "novo")

            let secondPage = try await Self.getFeed(app: app, bearer: admin.token, cursor: cursor)

            let combinedIDs = (firstPage.items + secondPage.items).map(\.id)
            let combinedIDSet = Set(combinedIDs)
            XCTAssertEqual(
                combinedIDs.count, combinedIDSet.count,
                "nenhuma linha pode aparecer duas vezes entre as duas páginas"
            )

            let originalIDs = Set(originalPosted.map(\.id))
            XCTAssertTrue(
                originalIDs.isSubset(of: combinedIDSet),
                "nenhum dos 25 originais pode ficar fora das duas páginas somadas"
            )
            // Os 3 novos podem legitimamente não aparecer (estão acima do cursor) — o que
            // este teste proíbe é repetir ou perder um dos 25 originais, não exige que os
            // 3 novos apareçam.
        }
    }

    func testFeedIsScopedToRequesterHousehold() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            try await Self.postRecados(app: app, bearer: adminA.token, count: 2, prefix: "casa A")
            try await Self.postRecados(app: app, bearer: adminB.token, count: 3, prefix: "casa B")

            let feedA = try await Self.getFeed(app: app, bearer: adminA.token)
            XCTAssertEqual(feedA.items.count, 2)
            XCTAssertTrue(feedA.items.allSatisfy { $0.authorID == adminA.userID })
        }
    }

    func testEmptyFeedReturnsEmptyItemsAndNilCursor() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]

            let page = try await Self.getFeed(app: app, bearer: admin.token)
            XCTAssertTrue(page.items.isEmpty)
            XCTAssertNil(page.nextCursor)
        }
    }

    func testForgedCursorStaysInsideRequesterHousehold() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            let aFirst = try await Self.postRecado(app: app, bearer: adminA.token, text: "casa A #1")
            let postedB = try await Self.postRecados(app: app, bearer: adminB.token, count: 3, prefix: "casa B")
            let aSecond = try await Self.postRecado(app: app, bearer: adminA.token, text: "casa A #2")

            // Cursor forjado: sequence de um recado real, mas da casa B — pertence ao
            // espaço global da sequence compartilhada, nunca ao domínio da casa A. Como o
            // filtro de household roda combinado ao de cursor na mesma consulta, um cursor
            // de outra casa só desloca a janela do próprio requisitante na própria casa.
            let forgedCursor = try XCTUnwrap(postedB.first?.sequence)

            let feedA = try await Self.getFeed(app: app, bearer: adminA.token, cursor: forgedCursor)
            XCTAssertTrue(
                feedA.items.allSatisfy { $0.authorID == adminA.userID },
                "o cursor forjado nunca pode trazer recados de outra casa"
            )
            XCTAssertEqual(
                feedA.items.map(\.id), [aFirst.id],
                "só o recado de A com sequence menor que o cursor forjado deve aparecer"
            )
            _ = aSecond
        }
    }
}

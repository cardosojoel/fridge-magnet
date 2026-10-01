@testable import App
import Fluent
import Foundation
import FridgeMagnetShared
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

    /// As rotas de arquivar/desarquivar também nunca mandam corpo (T-02-66).
    @discardableResult
    private static func archiveRequest(
        app: Application,
        method: HTTPMethod,
        bearer: String,
        recadoID: UUID
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        var status: HTTPStatus = .internalServerError
        var dto: RecadoDTO?
        try await app.testable().test(
            method, "/api/v1/recados/\(recadoID)/archive",
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
    private static func archive(app: Application, bearer: String, recadoID: UUID) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        try await archiveRequest(app: app, method: .PUT, bearer: bearer, recadoID: recadoID)
    }

    @discardableResult
    private static func unarchive(app: Application, bearer: String, recadoID: UUID) async throws -> (status: HTTPStatus, dto: RecadoDTO?) {
        try await archiveRequest(app: app, method: .DELETE, bearer: bearer, recadoID: recadoID)
    }

    private static func getArchived(app: Application, bearer: String) async throws -> (status: HTTPStatus, items: [RecadoDTO]?) {
        var status: HTTPStatus = .internalServerError
        var items: [RecadoDTO]?
        try await app.testable().test(
            .GET, "/api/v1/recados/archived",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                status = res.status
                items = try? res.content.decode([RecadoDTO].self)
            }
        )
        return (status, items)
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

    // MARK: Task 2 — arquivar/desarquivar e painel do admin (D-15)

    func testAuthorNonAdminCanArchiveOwnRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "para arquivar")
            let (status, dto) = try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNotNil(try XCTUnwrap(dto).archivedAt, "arquivar devolve o instante de arquivamento preenchido")
        }
    }

    func testAdminCanArchiveOtherMembersRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado pelo admin")
            let (status, dto) = try await Self.archive(app: app, bearer: admin.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNotNil(try XCTUnwrap(dto).archivedAt)
        }
    }

    func testThirdMemberCannotArchiveOthersRecadoAndNothingChanges() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]
            let third = members[2]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "recado alheio")
            let (status, _) = try await Self.archive(app: app, bearer: third.token, recadoID: recado.id)
            XCTAssertEqual(status, .forbidden)

            // Nada mudou: o recado continua visível no feed do autor, não arquivado.
            let fromFeed = try await Self.findInFeed(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertNil(fromFeed.archivedAt)
        }
    }

    func testArchivingPinnedRecadoClearsPinInSameSave() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "fixado e arquivado")
            try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)

            let (status, dto) = try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(status, .ok)
            let archived = try XCTUnwrap(dto)
            XCTAssertNotNil(archived.archivedAt)
            XCTAssertNil(archived.pinnedAt, "um recado fora do mural não pode continuar preso ao topo do mural")

            // A listagem do admin confirma o estado persistido: arquivado E sem fixação.
            let (_, items) = try await Self.getArchived(app: app, bearer: admin.token)
            let listed = try XCTUnwrap(try XCTUnwrap(items).first { $0.id == recado.id })
            XCTAssertNotNil(listed.archivedAt)
            XCTAssertNil(listed.pinnedAt)
        }
    }

    func testArchivingAlreadyArchivedRecadoIs404() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado duas vezes")
            try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)

            // Já saiu do mural — a segunda tentativa não o encontra.
            let (status, _) = try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(status, .notFound)
        }
    }

    func testNonAdminGets403OnArchivedList() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            // Negado pelo RequireRoleMiddleware antes de o handler rodar.
            let (status, _) = try await Self.getArchived(app: app, bearer: author.token)
            XCTAssertEqual(status, .forbidden)
        }
    }

    func testNonAdminGets403OnUnarchiveEvenForOwnArchivedRecado() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            // O cenário exato de D-15: o autor não-admin arquivou o PRÓPRIO recado — e
            // mesmo assim não o recupera sozinho. É o único caso que distingue "só admin
            // desarquiva" de "só o autor desarquiva".
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado pelo próprio autor")
            let (archiveStatus, _) = try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(archiveStatus, .ok)

            let (status, _) = try await Self.unarchive(app: app, bearer: author.token, recadoID: recado.id)
            XCTAssertEqual(status, .forbidden)
        }
    }

    func testAdminListsArchivedNewestFirstScopedToHousehold() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            let author = members[1]
            let adminB = membersB[0]

            // Casa B tem um recado arquivado DE VERDADE — linha real a não ser vista
            // (uma lista vazia por ausência de dado não provaria isolamento).
            let recadoB = try await Self.postRecado(app: app, bearer: adminB.token, text: "arquivado da casa B")
            try await Self.archive(app: app, bearer: adminB.token, recadoID: recadoB.id)

            let first = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado primeiro")
            let second = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado depois")
            try await Self.archive(app: app, bearer: author.token, recadoID: first.id)
            try await Self.archive(app: app, bearer: author.token, recadoID: second.id)

            let (status, items) = try await Self.getArchived(app: app, bearer: admin.token)
            XCTAssertEqual(status, .ok)
            let list = try XCTUnwrap(items)

            // Do mais recentemente arquivado para o mais antigo, cada item com o instante
            // preenchido — e nada da casa B.
            XCTAssertEqual(list.map(\.id), [second.id, first.id])
            XCTAssertTrue(list.allSatisfy { $0.archivedAt != nil })
            XCTAssertFalse(list.contains { $0.id == recadoB.id }, "recado arquivado de outra casa nunca aparece")
        }
    }

    func testAdminUnarchivesAndPinIsNeverRestored() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "vai e volta")
            try await Self.pin(app: app, bearer: author.token, recadoID: recado.id)
            try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)

            let (status, dto) = try await Self.unarchive(app: app, bearer: admin.token, recadoID: recado.id)
            XCTAssertEqual(status, .ok)
            let restored = try XCTUnwrap(dto)
            XCTAssertNil(restored.archivedAt, "desarquivar limpa o arquivamento")
            XCTAssertNil(restored.pinnedAt, "desarquivar nunca restaura fixação — fixar de novo é ação explícita")
        }
    }

    func testUnarchiveWhenNotArchivedIsIdempotent() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "nunca arquivado")
            let (status, dto) = try await Self.unarchive(app: app, bearer: admin.token, recadoID: recado.id)

            XCTAssertEqual(status, .ok)
            XCTAssertNil(try XCTUnwrap(dto).archivedAt)
        }
    }

    func testUnarchiveOnRecadoFromAnotherHouseholdIs404() async throws {
        try await TestSupport.withApp { app in
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let adminA = membersA[0]
            let adminB = membersB[0]

            let recadoB = try await Self.postRecado(app: app, bearer: adminB.token, text: "da casa B")
            try await Self.archive(app: app, bearer: adminB.token, recadoID: recadoB.id)

            // 404, nunca 403 de handler: a RLS torna a linha invisível (T-02-67).
            let (status, _) = try await Self.unarchive(app: app, bearer: adminA.token, recadoID: recadoB.id)
            XCTAssertEqual(status, .notFound)
        }
    }

    // MARK: Task 3 — recado arquivado invisível em toda rota; forma do feed (D-15/D-14)

    /// Tabela das nove operações de recado por id — todas devem responder 404 contra um
    /// recado arquivado, para QUALQUER papel (T-02-64/T-02-68: um 404 que dependesse do
    /// papel seria, ele próprio, um oráculo de existência da linha).
    private static func assertAllRecadoRoutesReturn404(app: Application, bearer: String, recadoID: UUID) async throws {
        struct RouteCase {
            let name: String
            let method: HTTPMethod
            let suffix: String
            let encodeBody: ((inout XCTHTTPRequest) throws -> Void)?
        }
        let routeCases: [RouteCase] = [
            .init(name: "editar", method: .PATCH, suffix: "", encodeBody: {
                try $0.content.encode(UpdateRecadoRequest(text: "edição impossível"), as: .json)
            }),
            .init(name: "apagar", method: .DELETE, suffix: "", encodeBody: nil),
            .init(name: "fixar", method: .PUT, suffix: "/pin", encodeBody: nil),
            .init(name: "desafixar", method: .DELETE, suffix: "/pin", encodeBody: nil),
            .init(name: "arquivar", method: .PUT, suffix: "/archive", encodeBody: nil),
            .init(name: "definir reação", method: .PUT, suffix: "/reactions", encodeBody: {
                try $0.content.encode(SetReactionRequest(kind: .love), as: .json)
            }),
            .init(name: "remover reação", method: .DELETE, suffix: "/reactions", encodeBody: nil),
            .init(name: "listar comentários", method: .GET, suffix: "/comments", encodeBody: nil),
            .init(name: "criar comentário", method: .POST, suffix: "/comments", encodeBody: {
                try $0.content.encode(CreateCommentRequest(text: "comentário impossível"), as: .json)
            }),
        ]

        for routeCase in routeCases {
            try await app.testable().test(
                routeCase.method, "/api/v1/recados/\(recadoID)\(routeCase.suffix)",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                    try routeCase.encodeBody?(&req)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(
                        res.status, .notFound,
                        "\(routeCase.name) deve responder 404 para recado arquivado — como se a linha não existisse"
                    )
                }
            )
        }
    }

    func testArchivedRecadoIsNotFoundOnEveryRecadoRoute() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "arquivado e inalcançável")
            try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)

            // As nove operações, rodadas DUAS vezes: como autor e como admin — invisível
            // para todo papel, inclusive quem poderia desarquivar.
            try await Self.assertAllRecadoRoutesReturn404(app: app, bearer: author.token, recadoID: recado.id)
            try await Self.assertAllRecadoRoutesReturn404(app: app, bearer: admin.token, recadoID: recado.id)
        }
    }

    func testArchivedRecadoDisappearsFromFeedForEveryRole() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]
            let third = members[2]

            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "some do mural de todos")
            try await Self.archive(app: app, bearer: author.token, recadoID: recado.id)

            for bearer in [author.token, admin.token, third.token] {
                let page = try await Self.getFeed(app: app, bearer: bearer)
                let all = page.pinned + page.items
                XCTAssertFalse(
                    all.contains { $0.id == recado.id },
                    "recado arquivado some do feed de TODOS — autor, admin e demais membros"
                )
            }
        }
    }

    func testUnarchiveReturnsRecadoToNaturalChronologicalPosition() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let admin = members[0]
            let author = members[1]

            let recadoA = try await Self.postRecado(app: app, bearer: author.token, text: "A, o mais antigo")
            let recadoB = try await Self.postRecado(app: app, bearer: author.token, text: "B, postado depois")

            try await Self.archive(app: app, bearer: author.token, recadoID: recadoA.id)
            let (status, _) = try await Self.unarchive(app: app, bearer: admin.token, recadoID: recadoA.id)
            XCTAssertEqual(status, .ok)

            // A volta à posição da chave de ordenação original (sequence) — B, postado
            // depois, continua ACIMA de A; desarquivar nunca põe o recado no topo.
            let page = try await Self.getFeed(app: app, bearer: author.token)
            let ids = page.items.map(\.id)
            let indexA = try XCTUnwrap(ids.firstIndex(of: recadoA.id))
            let indexB = try XCTUnwrap(ids.firstIndex(of: recadoB.id))
            XCTAssertLessThan(indexB, indexA, "B continua acima de A no fluxo cronológico")
        }
    }

    func testPinMovesRecadoToBlockAndUnpinReturnsItToStream() async throws {
        try await TestSupport.withApp { app in
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            let author = members[1]

            let recadoA = try await Self.postRecado(app: app, bearer: author.token, text: "A, fixável")
            let recadoB = try await Self.postRecado(app: app, bearer: author.token, text: "B, do fluxo")

            // Fixar move A do fluxo para o bloco na busca seguinte.
            try await Self.pin(app: app, bearer: author.token, recadoID: recadoA.id)
            let pinnedPage = try await Self.getFeed(app: app, bearer: author.token)
            XCTAssertTrue(pinnedPage.pinned.contains { $0.id == recadoA.id })
            XCTAssertFalse(pinnedPage.items.contains { $0.id == recadoA.id })
            XCTAssertTrue(pinnedPage.items.contains { $0.id == recadoB.id })

            // Desafixar devolve A ao fluxo na posição cronológica dele (abaixo de B).
            try await Self.unpin(app: app, bearer: author.token, recadoID: recadoA.id)
            let unpinnedPage = try await Self.getFeed(app: app, bearer: author.token)
            XCTAssertTrue(unpinnedPage.pinned.isEmpty)
            let ids = unpinnedPage.items.map(\.id)
            XCTAssertEqual(ids, [recadoB.id, recadoA.id])
        }
    }
}

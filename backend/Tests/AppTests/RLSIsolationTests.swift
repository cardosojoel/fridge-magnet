@testable import App
import Fluent
import FluentSQL
import Foundation
import FridgeMagnetShared
import XCTVapor

/// Prova de isolamento entre casas (IDENT-05) contra Postgres real — a conexão de teste é
/// `fridgemagnet_app`, o mesmo papel de runtime do backend (NOBYPASSRLS), nunca `fridgemagnet_owner`.
final class RLSIsolationTests: XCTestCase {
    private struct CreatedHousehold {
        var userID: UUID
        var accessToken: String
        var householdID: UUID
        var householdName: String
    }

    private func createHousehold(app: Application, name: String) async throws -> CreatedHousehold {
        let user = try await TestSupport.createTestUser(app: app, displayName: name)
        let userID = try user.requireID()
        let accessToken = try await TestSupport.makeAccessToken(app: app, userID: userID)

        var householdID: UUID?
        try await app.testable().test(
            .POST, "/api/v1/households",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: accessToken)
                try req.content.encode(["name": name], as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                let dto = try res.content.decode(HouseholdDTO.self)
                householdID = dto.id
            }
        )

        return CreatedHousehold(
            userID: userID,
            accessToken: accessToken,
            householdID: try XCTUnwrap(householdID),
            householdName: name
        )
    }

    func testCrossHouseholdQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await createHousehold(app: app, name: "Casa A")
            let houseB = try await createHousehold(app: app, name: "Casa B")

            // A conexão de teste está autenticada como fridgemagnet_app, não fridgemagnet_owner — se
            // rodasse como dono, as policies seriam ignoradas e toda asserção abaixo
            // "passaria" sem provar isolamento nenhum.
            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                guard let row = try await sql.raw("SELECT current_user").first() else {
                    return XCTFail("SELECT current_user não devolveu nenhuma linha")
                }
                let currentUser = try row.decode(column: "current_user", as: String.self)
                XCTAssertEqual(
                    currentUser, "fridgemagnet_app",
                    "a conexão de teste precisa estar sujeita à RLS (fridgemagnet_app), não bypassá-la (fridgemagnet_owner)"
                )
            }

            // household_members da casa B, sob o contexto da casa A: zero linhas.
            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM household_members WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(
                    rows.count, 0,
                    "uma sessão da casa A não pode ver household_members da casa B"
                )
            }

            // households da casa B, sob o contexto da casa A: zero linhas.
            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM households WHERE id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(
                    rows.count, 0,
                    "uma sessão da casa A não pode ver a linha de households da casa B"
                )
            }

            // GET /api/v1/households/current autenticado como o membro de A nunca devolve o
            // id da casa B.
            try await app.testable().test(
                .GET, "/api/v1/households/current",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: houseA.accessToken)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .ok)
                    let dto = try res.content.decode(HouseholdDTO.self)
                    XCTAssertEqual(dto.id, houseA.householdID)
                    XCTAssertNotEqual(
                        dto.id, houseB.householdID,
                        "a resposta de /households/current da casa A nunca pode conter o id da casa B"
                    )
                }
            )

            // Sem nenhum contexto de casa definido: households devolve zero linhas — fail-
            // closed (NULLIF na policy), não um erro de cast de uuid.
            try await TestSupport.withAppRoleConnection(app: app, householdID: nil) { sql in
                let rows = try await sql.raw("SELECT * FROM households").all()
                XCTAssertEqual(
                    rows.count, 0,
                    "sem contexto de casa, households deve devolver zero linhas, nunca lançar um erro de cast"
                )
            }
        }
    }
}

@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Prova de isolamento entre casas nas cinco tabelas do mural (T-02-01) contra Postgres
/// real — a conexão de teste é `jklar_app`, o mesmo papel de runtime do backend
/// (NOBYPASSRLS), nunca `jklar_owner`. Segue `RLSIsolationTests.swift` linha a linha.
final class RecadoRLSIsolationTests: XCTestCase {
    private struct SeededHouse {
        var householdID: UUID
        var adminID: UUID
        var adminToken: String
        var recadoID: UUID
    }

    /// Cria uma casa com um recado postado por rota real, e grava direto pelo papel dono
    /// (`app.db(.owner)`) uma linha de cada uma das quatro tabelas filhas — para que exista
    /// linha real desta casa a não ser vista sob o contexto de outra.
    private func seedHouseWithChildRows(app: Application, label: String) async throws -> SeededHouse {
        let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
        let admin = members[0]

        var capturedRecadoID: UUID?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
                try req.content.encode(CreateRecadoRequest(text: "recado de \(label)"), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                let dto = try res.content.decode(RecadoDTO.self)
                capturedRecadoID = dto.id
            }
        )
        let recadoID = try XCTUnwrap(capturedRecadoID)

        var capturedHouseholdID: UUID?
        try await app.testable().test(
            .GET, "/api/v1/households/current",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
                let dto = try res.content.decode(HouseholdDTO.self)
                capturedHouseholdID = dto.id
            }
        )
        let householdID = try XCTUnwrap(capturedHouseholdID)

        // `jklar_owner` não tem `BYPASSRLS` (dev-db.sh) — sob `FORCE ROW LEVEL SECURITY`
        // nem o dono da tabela escapa da policy, então o próprio INSERT do seed precisa do
        // mesmo `app.current_household_id` que a produção aplica, dentro da mesma
        // transação (mesma função usada por `HouseholdContextMiddleware`/`configure.swift`,
        // não uma reimplementação em teste).
        try await app.db(.owner).transaction { transactionDB in
            try await HouseholdContextMiddleware.applyCurrentHouseholdContext(
                householdID: householdID, on: transactionDB
            )

            let photo = RecadoPhoto(
                householdID: householdID,
                recadoID: recadoID,
                objectKey: "households/\(householdID)/recados/\(recadoID)/seed.jpg",
                position: 0,
                contentType: "image/jpeg",
                byteSize: 1024
            )
            try await photo.save(on: transactionDB)

            let reaction = RecadoReaction(
                householdID: householdID,
                recadoID: recadoID,
                userID: admin.userID,
                kind: ReactionKind.love.rawValue
            )
            try await reaction.save(on: transactionDB)

            let comment = RecadoComment(
                householdID: householdID,
                recadoID: recadoID,
                authorID: admin.userID,
                text: "comentário seed de \(label)"
            )
            try await comment.save(on: transactionDB)

            let mention = RecadoMention(
                householdID: householdID,
                recadoID: recadoID,
                mentionedUserID: admin.userID
            )
            try await mention.save(on: transactionDB)
        }

        return SeededHouse(householdID: householdID, adminID: admin.userID, adminToken: admin.token, recadoID: recadoID)
    }

    func testConnectionIsSubjectToRLS() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                guard let row = try await sql.raw("SELECT current_user").first() else {
                    return XCTFail("SELECT current_user não devolveu nenhuma linha")
                }
                let currentUser = try row.decode(column: "current_user", as: String.self)
                XCTAssertEqual(
                    currentUser, "jklar_app",
                    "a conexão de teste precisa estar sujeita à RLS (jklar_app), não bypassá-la (jklar_owner)"
                )
            }
        }
    }

    func testCrossHouseholdRecadoQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM recados WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(rows.count, 0, "uma sessão da casa A não pode ver recados da casa B")
            }
        }
    }

    func testCrossHouseholdRecadoPhotosQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM recado_photos WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(rows.count, 0, "uma sessão da casa A não pode ver recado_photos da casa B")
            }
        }
    }

    func testCrossHouseholdRecadoMentionsQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM recado_mentions WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(rows.count, 0, "uma sessão da casa A não pode ver recado_mentions da casa B")
            }
        }
    }

    func testCrossHouseholdRecadoReactionsQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM recado_reactions WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(rows.count, 0, "uma sessão da casa A não pode ver recado_reactions da casa B")
            }
        }
    }

    func testCrossHouseholdRecadoCommentsQueryReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                let rows = try await sql.raw(
                    "SELECT * FROM recado_comments WHERE household_id = \(bind: houseB.householdID.uuidString)::uuid"
                ).all()
                XCTAssertEqual(rows.count, 0, "uma sessão da casa A não pode ver recado_comments da casa B")
            }
        }
    }

    func testInsertWithForeignHouseholdIDIsRejected() async throws {
        try await TestSupport.withApp { app in
            let houseA = try await seedHouseWithChildRows(app: app, label: "Casa A")
            let houseB = try await seedHouseWithChildRows(app: app, label: "Casa B")

            do {
                try await TestSupport.withAppRoleConnection(app: app, householdID: houseA.householdID) { sql in
                    // A policy omite `WITH CHECK`, então o Postgres reusa a expressão do
                    // `USING` também para o INSERT — uma linha com household_id de outra
                    // casa nunca satisfaz `household_id = app.current_household_id`.
                    try await sql.raw("""
                        INSERT INTO recados (id, household_id, author_id, sequence, created_at, updated_at)
                        VALUES (
                            \(bind: UUID()), \(bind: houseB.householdID), \(bind: houseA.adminID),
                            nextval('recados_sequence_seq'), now(), now()
                        )
                        """).run()
                }
                XCTFail("INSERT com household_id de outra casa deveria falhar sob a policy RLS")
            } catch {
                // Esperado — a policy rejeita a linha.
            }
        }
    }

    func testQueryWithoutHouseholdContextReturnsEmpty() async throws {
        try await TestSupport.withApp { app in
            _ = try await seedHouseWithChildRows(app: app, label: "Casa A")

            // Fail-closed (NULLIF na policy), não um erro de cast de uuid.
            try await TestSupport.withAppRoleConnection(app: app, householdID: nil) { sql in
                let rows = try await sql.raw("SELECT * FROM recados").all()
                XCTAssertEqual(
                    rows.count, 0,
                    "sem contexto de casa, recados deve devolver zero linhas, nunca lançar um erro de cast"
                )
            }
        }
    }
}

@testable import App
import Fluent
import Foundation
import FridgeMagnetShared
import XCTVapor

/// Cobre os oito casos de `<behavior>` da Task 1 do plano 01-06 — convite por código CSPRNG,
/// validade de 7 dias, e a corrida de aceitação sob o cap de 10 membros.
final class InviteTests: XCTestCase {
    // MARK: Helpers de request

    private static func postHousehold(
        app: Application,
        bearer: String,
        name: String = "Família Silva"
    ) async throws -> HouseholdDTO {
        var captured: HouseholdDTO?
        try await app.testable().test(
            .POST, "/api/v1/households",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(["name": name], as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                captured = try res.content.decode(HouseholdDTO.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    private static func postInvite(
        app: Application,
        bearer: String?
    ) async throws -> (status: HTTPStatus, dto: InviteDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: InviteDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/households/current/invites",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTO = try res.content.decode(InviteDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    private static func getInvites(
        app: Application,
        bearer: String?
    ) async throws -> (status: HTTPStatus, dtos: [InviteDTO]?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTOs: [InviteDTO]?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .GET, "/api/v1/households/current/invites",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedDTOs = try res.content.decode([InviteDTO].self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTOs, capturedError)
    }

    private static func postJoin(
        app: Application,
        bearer: String?,
        code: String
    ) async throws -> (status: HTTPStatus, dto: HouseholdDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: HouseholdDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/households/join",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
                try req.content.encode(JoinHouseholdRequest(code: code), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedDTO = try res.content.decode(HouseholdDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    /// Conta membros lendo `GET /api/v1/households/current` (via um bearer já membro da
    /// casa) em vez de consultar `household_members` diretamente pela conexão de runtime
    /// sem contexto — uma query direta em `app.db` sempre devolveria zero sob RLS forçada,
    /// sem `app.current_household_id` aplicado (fail-closed by design, não um bug do teste).
    private static func memberCount(app: Application, bearer: String) async throws -> Int {
        var captured: HouseholdDTO?
        try await app.testable().test(
            .GET, "/api/v1/households/current",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                captured = try res.content.decode(HouseholdDTO.self)
            }
        )
        return try XCTUnwrap(captured).memberCount
    }

    private static func makeUserAndToken(app: Application, displayName: String? = nil) async throws -> (id: UUID, token: String) {
        let user = try await TestSupport.createTestUser(app: app, displayName: displayName)
        let userID = try user.requireID()
        let token = try await TestSupport.makeAccessToken(app: app, userID: userID)
        return (userID, token)
    }

    // MARK: POST /api/v1/households/current/invites

    func testCreateInviteAsAdminReturnsSixCharacterCodeAndSevenDayExpiry() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let before = Date()
            let result = try await Self.postInvite(app: app, bearer: admin.token)
            XCTAssertEqual(result.status, .created)

            let dto = try XCTUnwrap(result.dto)
            XCTAssertEqual(dto.code.count, 6)
            XCTAssertEqual(dto.url, "fridgemagnet://join/\(dto.code)")

            let expectedExpiry = before.addingTimeInterval(7 * 24 * 60 * 60)
            XCTAssertEqual(dto.expiresAt.timeIntervalSince(expectedExpiry), 0, accuracy: 5)
        }
    }

    // MARK: POST /api/v1/households/join

    func testSameInviteAcceptedByTwoDifferentPeopleWorksBothTimes() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let invite = try await Self.postInvite(app: app, bearer: admin.token)
            let code = try XCTUnwrap(invite.dto?.code)

            let first = try await Self.makeUserAndToken(app: app, displayName: "Primeira Pessoa")
            let firstJoin = try await Self.postJoin(app: app, bearer: first.token, code: code)
            XCTAssertEqual(firstJoin.status, .ok)
            XCTAssertEqual(firstJoin.dto?.myRole, .adulto)

            let second = try await Self.makeUserAndToken(app: app, displayName: "Segunda Pessoa")
            let secondJoin = try await Self.postJoin(app: app, bearer: second.token, code: code)
            XCTAssertEqual(secondJoin.status, .ok, "convite deve ser reutilizável dentro dos 7 dias (D-06)")
            XCTAssertEqual(secondJoin.dto?.myRole, .adulto)
            XCTAssertEqual(secondJoin.dto?.memberCount, 3)
        }
    }

    func testJoinWithExpiredInviteReturnsInviteExpired() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            let household = try await Self.postHousehold(app: app, bearer: admin.token)

            let expiredInvite = HouseholdInvite(
                householdID: household.id,
                code: "EXPIRD",
                createdByUserID: admin.id,
                expiresAt: Date().addingTimeInterval(-3600)
            )
            try await expiredInvite.save(on: app.db(.owner))

            let joiner = try await Self.makeUserAndToken(app: app, displayName: "Atrasado")
            let result = try await Self.postJoin(app: app, bearer: joiner.token, code: "EXPIRD")
            XCTAssertEqual(result.error?.code, .inviteExpired)
        }
    }

    func testJoinWithUnknownCodeReturnsInviteInvalid() async throws {
        try await TestSupport.withApp { app in
            let joiner = try await Self.makeUserAndToken(app: app, displayName: "Curioso")
            let result = try await Self.postJoin(app: app, bearer: joiner.token, code: "ZZZZZZ")
            XCTAssertEqual(result.error?.code, .inviteInvalid)
        }
    }

    func testJoinWhenHouseholdAtCapacityReturnsHouseholdFull() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let invite = try await Self.postInvite(app: app, bearer: admin.token)
            let code = try XCTUnwrap(invite.dto?.code)

            // Admin já é o 1º membro — mais 9 chegam a 10 (o cap).
            for index in 0..<9 {
                let member = try await Self.makeUserAndToken(app: app, displayName: "Membro \(index)")
                let joined = try await Self.postJoin(app: app, bearer: member.token, code: code)
                XCTAssertEqual(joined.status, .ok)
            }

            let eleventh = try await Self.makeUserAndToken(app: app, displayName: "Excedente")
            let result = try await Self.postJoin(app: app, bearer: eleventh.token, code: code)
            XCTAssertEqual(result.status, .conflict)
            XCTAssertEqual(result.error?.code, .householdFull)
        }
    }

    /// Nomeado conforme a linha `01-04` do 01-VALIDATION.md — prova que o `SELECT ... FOR
    /// UPDATE` na linha da casa fecha a corrida do cap de 10 (T-06-02, 01-RESEARCH.md
    /// Pitfall 3): duas aceitações concorrentes com a casa em 9 membros produzem exatamente
    /// um sucesso e um `householdFull`, nunca 11 membros.
    func testJoinRejectsAtCapacity() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let invite = try await Self.postInvite(app: app, bearer: admin.token)
            let code = try XCTUnwrap(invite.dto?.code)

            // Admin já é o 1º membro — mais 8 chegam a 9, deixando exatamente uma vaga.
            for index in 0..<8 {
                let member = try await Self.makeUserAndToken(app: app, displayName: "Membro \(index)")
                let joined = try await Self.postJoin(app: app, bearer: member.token, code: code)
                XCTAssertEqual(joined.status, .ok)
            }

            let membersBeforeRace = try await Self.memberCount(app: app, bearer: admin.token)
            XCTAssertEqual(membersBeforeRace, 9)

            let candidateA = try await Self.makeUserAndToken(app: app, displayName: "Candidata A")
            let candidateB = try await Self.makeUserAndToken(app: app, displayName: "Candidato B")

            async let resultA = Self.postJoin(app: app, bearer: candidateA.token, code: code)
            async let resultB = Self.postJoin(app: app, bearer: candidateB.token, code: code)
            let (raceA, raceB) = try await (resultA, resultB)

            let statuses = [raceA.status, raceB.status]
            let successCount = statuses.filter { $0 == .ok }.count
            let conflictCount = statuses.filter { $0 == .conflict }.count
            XCTAssertEqual(successCount, 1, "uma corrida de 9→11 deve produzir exatamente um sucesso")
            XCTAssertEqual(conflictCount, 1, "e exatamente um householdFull, nunca dois sucessos")

            let errorCodes = [raceA.error?.code, raceB.error?.code].compactMap { $0 }
            XCTAssertEqual(errorCodes, [.householdFull])

            let finalCount = try await Self.memberCount(app: app, bearer: admin.token)
            XCTAssertEqual(finalCount, 10, "o cap de 10 nunca pode ser ultrapassado, mesmo sob corrida")
        }
    }

    func testJoinWithCodeOfExistingMemberReturnsOkWithoutDuplicateRow() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let invite = try await Self.postInvite(app: app, bearer: admin.token)
            let code = try XCTUnwrap(invite.dto?.code)

            // Admin reapresenta o próprio código de convite da própria casa.
            let result = try await Self.postJoin(app: app, bearer: admin.token, code: code)
            XCTAssertEqual(result.status, .ok)
            XCTAssertEqual(result.dto?.myRole, .admin, "reapresentar o código não pode mudar o papel de quem já é membro")
            XCTAssertEqual(
                result.dto?.memberCount, 1,
                "reapresentar um código já aceito não pode criar uma segunda linha em household_members"
            )
        }
    }

    // MARK: GET /api/v1/households/current/invites

    func testListInvitesReturnsOnlyLiveInvitesOfTheCurrentHousehold() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let created = try await Self.postInvite(app: app, bearer: admin.token)

            let result = try await Self.getInvites(app: app, bearer: admin.token)
            XCTAssertEqual(result.status, .ok)
            let createdCode = try XCTUnwrap(created.dto?.code)
            XCTAssertEqual(result.dtos?.map(\.code), [createdCode])
        }
    }

    // MARK: InviteCodeGenerator — alfabeto sem ambiguidade (unit, sem Application)

    func testInviteCodeGeneratorNeverProducesAmbiguousCharactersAndRarelyRepeats() {
        let ambiguousCharacters: Set<Character> = ["0", "O", "1", "I", "L"]
        var generatedCodes: Set<String> = []

        for _ in 0..<200 {
            let code = InviteCodeGenerator.generate()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(
                code.allSatisfy { !ambiguousCharacters.contains($0) },
                "código \(code) contém um caractere ambíguo"
            )
            generatedCodes.insert(code)
        }

        XCTAssertEqual(generatedCodes.count, 200, "200 códigos de 31^6 possibilidades não devem colidir entre si")
    }
}

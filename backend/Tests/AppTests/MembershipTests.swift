@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Cobre os nove casos de `<behavior>` da Task 1 do plano 01-10 — remoção admin-only
/// (`DELETE .../members/:memberID`), saída auto-serviço (`DELETE .../membership`), e a
/// invariante "a casa nunca fica sem admin" (`wouldLeaveHouseholdWithoutAdmin`, extraída no
/// plano 01-06 e reusada aqui, não reimplementada) aplicada às duas rotas novas sob o mesmo
/// `FOR UPDATE` da casa. Mesmo padrão de helpers duplicados de `InviteTests`/
/// `RoleEnforcementTests` — sem estado compartilhado entre os três arquivos.
final class MembershipTests: XCTestCase {
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
        bearer: String
    ) async throws -> (status: HTTPStatus, dto: InviteDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: InviteDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/households/current/invites",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
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

    private static func postJoin(
        app: Application,
        bearer: String,
        code: String
    ) async throws -> (status: HTTPStatus, dto: HouseholdDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: HouseholdDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/households/join",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
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

    private static func getMembers(
        app: Application,
        bearer: String
    ) async throws -> (status: HTTPStatus, dtos: [MemberDTO]?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTOs: [MemberDTO]?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .GET, "/api/v1/households/current/members",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedDTOs = try res.content.decode([MemberDTO].self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTOs, capturedError)
    }

    private static func patchMemberRole(
        app: Application,
        bearer: String,
        memberID: UUID,
        role: MemberRole
    ) async throws -> (status: HTTPStatus, dto: MemberDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: MemberDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .PATCH, "/api/v1/households/current/members/\(memberID.uuidString)/role",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(UpdateMemberRoleRequest(role: role), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedDTO = try res.content.decode(MemberDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    private static func deleteMember(
        app: Application,
        bearer: String,
        memberID: UUID
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .DELETE, "/api/v1/households/current/members/\(memberID.uuidString)",
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

    private static func deleteMembership(
        app: Application,
        bearer: String
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .DELETE, "/api/v1/households/current/membership",
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

    /// Cria uma casa com `admin` como criador e junta `member` a ela como `.adulto` via
    /// convite real (não inserção direta) — exercita o mesmo caminho de produção que o resto
    /// da suíte.
    private static func joinAsAdulto(
        app: Application,
        adminBearer: String,
        memberBearer: String
    ) async throws {
        let invite = try await Self.postInvite(app: app, bearer: adminBearer)
        let code = try XCTUnwrap(invite.dto?.code)
        let joined = try await Self.postJoin(app: app, bearer: memberBearer, code: code)
        XCTAssertEqual(joined.status, .ok)
    }

    // MARK: DELETE /api/v1/households/current/members/:memberID — admin remove outro membro

    func testAdminRemovesMemberReturns204AndMemberListShrinks() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let beforeRemoval = try await Self.getMembers(app: app, bearer: admin.token)
            XCTAssertEqual(beforeRemoval.dtos?.count, 2)
            let adultMemberID = try XCTUnwrap(beforeRemoval.dtos?.first { $0.displayName == "Adulto" }?.id)

            let removal = try await Self.deleteMember(app: app, bearer: admin.token, memberID: adultMemberID)
            XCTAssertEqual(removal.status, .noContent)

            let afterRemoval = try await Self.getMembers(app: app, bearer: admin.token)
            XCTAssertEqual(afterRemoval.dtos?.count, 1)
            XCTAssertEqual(afterRemoval.dtos?.first?.displayName, "Admin")
        }
    }

    func testRemovedMemberAccessTokenRejectedOnNextRequestEvenWithinTTL() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adultMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Adulto" }?.id)

            let removal = try await Self.deleteMember(app: app, bearer: admin.token, memberID: adultMemberID)
            XCTAssertEqual(removal.status, .noContent)

            // O access token do removido ainda está dentro dos 15 minutos de validade
            // criptográfica (TestSupport.makeAccessToken assina com esse mesmo TTL) — a
            // remoção precisa valer no request seguinte porque o pertencimento é resolvido do
            // banco a cada request por HouseholdContextMiddleware, nunca de uma claim do JWT
            // (T-10-03). Reapresentar o mesmo token aqui é o que prova isso.
            let afterRemoval = try await Self.getMembers(app: app, bearer: adult.token)
            XCTAssertEqual(afterRemoval.status, .forbidden, "token ainda válido, mas o membro já não pertence à casa")
            XCTAssertEqual(afterRemoval.error?.code, .forbidden)
        }
    }

    func testNonAdminCannotRemoveMember() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)
            let child = try await Self.makeUserAndToken(app: app, displayName: "Criança")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: child.token)

            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adultMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Adulto" }?.id)
            let childMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Criança" }?.id)

            // Rebaixa para .crianca de propósito (papel padrão de quem entra por convite é
            // .adulto, D-07) — exercita também o caminho "criança tenta remover".
            let demote = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: childMemberID, role: .crianca)
            XCTAssertEqual(demote.status, .ok)

            let adultAttempt = try await Self.deleteMember(app: app, bearer: adult.token, memberID: childMemberID)
            XCTAssertEqual(adultAttempt.status, .forbidden)
            XCTAssertEqual(adultAttempt.error?.code, .forbidden)

            let childAttempt = try await Self.deleteMember(app: app, bearer: child.token, memberID: adultMemberID)
            XCTAssertEqual(childAttempt.status, .forbidden)
            XCTAssertEqual(childAttempt.error?.code, .forbidden)
        }
    }

    func testRemoveMemberForCrossHouseholdMemberReturnsNotFound() async throws {
        try await TestSupport.withApp { app in
            let adminA = try await Self.makeUserAndToken(app: app, displayName: "Admin A")
            _ = try await Self.postHousehold(app: app, bearer: adminA.token, name: "Casa A")

            let adminB = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            _ = try await Self.postHousehold(app: app, bearer: adminB.token, name: "Casa B")
            let memberOfB = try await Self.makeUserAndToken(app: app, displayName: "Membro de B")
            try await Self.joinAsAdulto(app: app, adminBearer: adminB.token, memberBearer: memberOfB.token)

            let membersOfB = try await Self.getMembers(app: app, bearer: adminB.token)
            let crossHouseholdMemberID = try XCTUnwrap(membersOfB.dtos?.first { $0.displayName == "Membro de B" }?.id)

            // Admin A (Casa A) tenta remover um memberID que só existe na Casa B — sob RLS,
            // essa linha simplesmente não existe para o contexto de A: 404, nunca 403 e nunca
            // 204 (T-10-05).
            let result = try await Self.deleteMember(app: app, bearer: adminA.token, memberID: crossHouseholdMemberID)
            XCTAssertEqual(result.status, .notFound)
        }
    }

    func testAdminRemovingSelfReturnsCannotRemoveSelf() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adminMemberID = try XCTUnwrap(members.dtos?.first?.id)

            let result = try await Self.deleteMember(app: app, bearer: admin.token, memberID: adminMemberID)
            XCTAssertEqual(result.status, .conflict)
            XCTAssertEqual(result.error?.code, .cannotRemoveSelf)
        }
    }

    // MARK: DELETE /api/v1/households/current/membership — auto-serviço

    func testNonAdminMemberCanLeaveHouseholdWithoutAdmin() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let result = try await Self.deleteMembership(app: app, bearer: adult.token)
            XCTAssertEqual(result.status, .noContent)

            let afterLeave = try await Self.getMembers(app: app, bearer: admin.token)
            XCTAssertEqual(afterLeave.dtos?.count, 1)
        }
    }

    func testLastAdminCannotLeave() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let attempt = try await Self.deleteMembership(app: app, bearer: admin.token)
            XCTAssertEqual(attempt.status, .conflict)
            XCTAssertEqual(attempt.error?.code, .lastAdmin)

            let adult = try await Self.makeUserAndToken(app: app, displayName: "Segundo Admin")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)
            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adultMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Segundo Admin" }?.id)
            let promote = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: adultMemberID, role: .admin)
            XCTAssertEqual(promote.status, .ok)

            // Mesma chamada, agora aceita — a casa tem um segundo admin.
            let secondAttempt = try await Self.deleteMembership(app: app, bearer: admin.token)
            XCTAssertEqual(secondAttempt.status, .noContent)
        }
    }

    func testConcurrentLastTwoAdminsLeavingLeavesExactlyOneAdmin() async throws {
        try await TestSupport.withApp { app in
            let adminA = try await Self.makeUserAndToken(app: app, displayName: "Admin A")
            _ = try await Self.postHousehold(app: app, bearer: adminA.token)
            let adminB = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            try await Self.joinAsAdulto(app: app, adminBearer: adminA.token, memberBearer: adminB.token)
            let members = try await Self.getMembers(app: app, bearer: adminA.token)
            let adminBMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Admin B" }?.id)
            let promote = try await Self.patchMemberRole(app: app, bearer: adminA.token, memberID: adminBMemberID, role: .admin)
            XCTAssertEqual(promote.status, .ok)

            async let resultA = Self.deleteMembership(app: app, bearer: adminA.token)
            async let resultB = Self.deleteMembership(app: app, bearer: adminB.token)
            let (raceA, raceB) = try await (resultA, resultB)

            let statuses = [raceA.status, raceB.status]
            XCTAssertEqual(statuses.filter { $0 == .noContent }.count, 1, "exatamente uma das duas saídas concorrentes deve ter sucesso")
            XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1, "e exatamente um lastAdmin, nunca dois sucessos")

            let errorCodes = [raceA.error?.code, raceB.error?.code].compactMap { $0 }
            XCTAssertEqual(errorCodes, [.lastAdmin])

            // Quem recebeu lastAdmin é quem ficou — a casa termina com exatamente um membro,
            // e esse membro continua admin (a invariante nunca foi violada, mesmo sob corrida).
            let stayedBearer = raceA.status == .conflict ? adminA.token : adminB.token
            let remaining = try await Self.getMembers(app: app, bearer: stayedBearer)
            XCTAssertEqual(remaining.dtos?.count, 1)
            XCTAssertEqual(remaining.dtos?.first?.role, .admin)
        }
    }

    func testLeavingFreesSlotForNewJoinAtCapacity() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let invite = try await Self.postInvite(app: app, bearer: admin.token)
            let code = try XCTUnwrap(invite.dto?.code)

            // Admin é o 1º membro — mais 9 chegam a 10 (cap cheio).
            var memberTokens: [String] = []
            for index in 0..<9 {
                let member = try await Self.makeUserAndToken(app: app, displayName: "Membro \(index)")
                let joined = try await Self.postJoin(app: app, bearer: member.token, code: code)
                XCTAssertEqual(joined.status, .ok)
                memberTokens.append(member.token)
            }
            let full = try await Self.memberCount(app: app, bearer: admin.token)
            XCTAssertEqual(full, 10)

            let blockedCandidate = try await Self.makeUserAndToken(app: app, displayName: "Candidata Bloqueada")
            let blocked = try await Self.postJoin(app: app, bearer: blockedCandidate.token, code: code)
            XCTAssertEqual(blocked.status, .conflict)
            XCTAssertEqual(blocked.error?.code, .householdFull)

            // Um dos nove membros sai — libera exatamente uma vaga (a contagem lê o estado
            // real da tabela, não um contador cacheado).
            let leave = try await Self.deleteMembership(app: app, bearer: memberTokens[0])
            XCTAssertEqual(leave.status, .noContent)
            let afterLeave = try await Self.memberCount(app: app, bearer: admin.token)
            XCTAssertEqual(afterLeave, 9)

            let newCandidate = try await Self.makeUserAndToken(app: app, displayName: "Candidata Nova")
            let joinedAfterLeave = try await Self.postJoin(app: app, bearer: newCandidate.token, code: code)
            XCTAssertEqual(joinedAfterLeave.status, .ok)
            let finalCount = try await Self.memberCount(app: app, bearer: admin.token)
            XCTAssertEqual(finalCount, 10)
        }
    }
}

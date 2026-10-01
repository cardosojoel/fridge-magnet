@testable import App
import Fluent
import Foundation
import FridgeMagnetShared
import XCTVapor

/// Cobre os oito casos de `<behavior>` da Task 2 do plano 01-06 — papel resolvido sempre do
/// banco (IDENT-06), listagem de membros escopada por RLS, e a invariante de "a casa nunca
/// fica sem admin" aplicada ao rebaixamento (`PATCH .../role`). O middleware
/// (`RequireRoleMiddleware`), as rotas e a checagem de invariante (`wouldLeaveHouseholdWithoutAdmin`)
/// já existem desde a Task 1 (necessários para as rotas de convite ficarem admin-only) —
/// esta suíte é quem prova os 403/404/409 que essa infraestrutura promete.
final class RoleEnforcementTests: XCTestCase {
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

    private static func getMembers(
        app: Application,
        bearer: String?
    ) async throws -> (status: HTTPStatus, dtos: [MemberDTO]?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTOs: [MemberDTO]?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .GET, "/api/v1/households/current/members",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
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
        bearer: String?,
        memberID: UUID,
        role: MemberRole
    ) async throws -> (status: HTTPStatus, dto: MemberDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: MemberDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .PATCH, "/api/v1/households/current/members/\(memberID.uuidString)/role",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
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

    private static func makeUserAndToken(app: Application, displayName: String? = nil) async throws -> (id: UUID, token: String) {
        let user = try await TestSupport.createTestUser(app: app, displayName: displayName)
        let userID = try user.requireID()
        let token = try await TestSupport.makeAccessToken(app: app, userID: userID)
        return (userID, token)
    }

    /// Cria uma casa com `admin` como criador e junta `member` a ela como `.adulto` via
    /// convite real (não inserção direta) — exercita o mesmo caminho de produção que o
    /// resto da suíte.
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

    // MARK: POST /api/v1/households/current/invites — admin-only

    func testNonAdminCannotInvite() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let result = try await Self.postInvite(app: app, bearer: adult.token)
            XCTAssertEqual(result.status, .forbidden)
            XCTAssertEqual(result.error?.code, .forbidden)
        }
    }

    func testChildCannotInvite() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let child = try await Self.makeUserAndToken(app: app, displayName: "Criança")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: child.token)

            // Rebaixa a criança de .adulto (papel padrão de quem entra por convite, D-07)
            // para .crianca, para exercitar o caminho "criança tenta convidar".
            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let childMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Criança" }?.id)
            let demote = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: childMemberID, role: .crianca)
            XCTAssertEqual(demote.status, .ok)

            let result = try await Self.postInvite(app: app, bearer: child.token)
            XCTAssertEqual(result.status, .forbidden)
            XCTAssertEqual(result.error?.code, .forbidden)
        }
    }

    func testAdminCanInvite() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let result = try await Self.postInvite(app: app, bearer: admin.token)
            XCTAssertEqual(result.status, .created)
        }
    }

    // MARK: PATCH /api/v1/households/current/members/:memberID/role

    func testUpdateMemberRoleAsAdminSucceedsAsNonAdminIsForbidden() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adultMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Adulto" }?.id)

            // Não-admin tentando promover a si mesmo — 403, nunca chega a mudar nada.
            let forbidden = try await Self.patchMemberRole(app: app, bearer: adult.token, memberID: adultMemberID, role: .admin)
            XCTAssertEqual(forbidden.status, .forbidden)
            XCTAssertEqual(forbidden.error?.code, .forbidden)

            // Admin promovendo o mesmo membro — sucesso.
            let promoted = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: adultMemberID, role: .admin)
            XCTAssertEqual(promoted.status, .ok)
            XCTAssertEqual(promoted.dto?.role, .admin)
        }
    }

    func testAdminCannotDemoteSelfWhenSoleAdmin() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adminMemberID = try XCTUnwrap(members.dtos?.first?.id)

            let result = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: adminMemberID, role: .adulto)
            XCTAssertEqual(result.status, .conflict)
            XCTAssertEqual(result.error?.code, .lastAdmin)
        }
    }

    func testDemotionAcceptedAfterPromotingAnotherAdmin() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            let adult = try await Self.makeUserAndToken(app: app, displayName: "Segundo Admin")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let originalAdminMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Admin" }?.id)
            let adultMemberID = try XCTUnwrap(members.dtos?.first { $0.displayName == "Segundo Admin" }?.id)

            // Ainda um único admin — rebaixamento deve ser recusado.
            let stillOnlyAdmin = try await Self.patchMemberRole(
                app: app, bearer: admin.token, memberID: originalAdminMemberID, role: .adulto
            )
            XCTAssertEqual(stillOnlyAdmin.status, .conflict)
            XCTAssertEqual(stillOnlyAdmin.error?.code, .lastAdmin)

            // Promove o segundo membro a admin — agora há dois.
            let promote = try await Self.patchMemberRole(app: app, bearer: admin.token, memberID: adultMemberID, role: .admin)
            XCTAssertEqual(promote.status, .ok)

            // O mesmo rebaixamento do admin original agora é aceito.
            let nowAccepted = try await Self.patchMemberRole(
                app: app, bearer: admin.token, memberID: originalAdminMemberID, role: .adulto
            )
            XCTAssertEqual(nowAccepted.status, .ok)
            XCTAssertEqual(nowAccepted.dto?.role, .adulto)
        }
    }

    func testUpdateMemberRoleForCrossHouseholdMemberReturnsNotFoundNotForbidden() async throws {
        try await TestSupport.withApp { app in
            let adminA = try await Self.makeUserAndToken(app: app, displayName: "Admin A")
            _ = try await Self.postHousehold(app: app, bearer: adminA.token, name: "Casa A")

            let adminB = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            _ = try await Self.postHousehold(app: app, bearer: adminB.token, name: "Casa B")

            let memberOfB = try await Self.makeUserAndToken(app: app, displayName: "Membro de B")
            try await Self.joinAsAdulto(app: app, adminBearer: adminB.token, memberBearer: memberOfB.token)

            let membersOfB = try await Self.getMembers(app: app, bearer: adminB.token)
            let crossHouseholdMemberID = try XCTUnwrap(membersOfB.dtos?.first { $0.displayName == "Membro de B" }?.id)

            // Admin A (da Casa A) tenta trocar o papel de um memberID que só existe na Casa
            // B — sob RLS, essa linha simplesmente não existe para o contexto de A: 404, não
            // 403 (T-06-05).
            let result = try await Self.patchMemberRole(
                app: app, bearer: adminA.token, memberID: crossHouseholdMemberID, role: .admin
            )
            XCTAssertEqual(result.status, .notFound)
        }
    }

    // MARK: GET /api/v1/households/current/members

    func testGetMembersReturnsOnlyMembersOfRequesterHousehold() async throws {
        try await TestSupport.withApp { app in
            let adminA = try await Self.makeUserAndToken(app: app, displayName: "Admin A")
            _ = try await Self.postHousehold(app: app, bearer: adminA.token, name: "Casa A")
            let extraOfA = try await Self.makeUserAndToken(app: app, displayName: "Extra de A")
            try await Self.joinAsAdulto(app: app, adminBearer: adminA.token, memberBearer: extraOfA.token)

            let adminB = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            _ = try await Self.postHousehold(app: app, bearer: adminB.token, name: "Casa B")

            let resultA = try await Self.getMembers(app: app, bearer: adminA.token)
            XCTAssertEqual(resultA.status, .ok)
            let namesInA = Set(resultA.dtos?.map { $0.displayName ?? "" } ?? [])
            XCTAssertEqual(namesInA, ["Admin A", "Extra de A"])

            let resultB = try await Self.getMembers(app: app, bearer: adminB.token)
            XCTAssertEqual(resultB.status, .ok)
            let namesInB = Set(resultB.dtos?.map { $0.displayName ?? "" } ?? [])
            XCTAssertEqual(namesInB, ["Admin B"], "a casa B nunca pode ver o membro extra da casa A")
        }
    }

    // MARK: Nenhum papel lido de headers/query/content diretamente (IDENT-06)

    func testUpdateMemberRoleAlwaysDecodesFromTypedRequestBody() async throws {
        try await TestSupport.withApp { app in
            // Prova indireta de IDENT-06 em tempo de execução: um corpo com uma string de
            // papel inválida (fora do enum MemberRole) nunca decodifica — a rota só aceita
            // um dos três valores válidos, nunca uma string livre vinda do request.
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let members = try await Self.getMembers(app: app, bearer: admin.token)
            let adminMemberID = try XCTUnwrap(members.dtos?.first?.id)

            var capturedStatus: HTTPStatus = .internalServerError
            try await app.testable().test(
                .PATCH, "/api/v1/households/current/members/\(adminMemberID.uuidString)/role",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
                    try req.content.encode(["role": "super-admin-hackeado"], as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    capturedStatus = res.status
                }
            )
            XCTAssertEqual(capturedStatus, .badRequest, "um valor fora de MemberRole nunca decodifica com sucesso")
        }
    }
}

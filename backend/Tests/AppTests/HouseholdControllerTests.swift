@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Cobre os oito casos de `<behavior>` do plano 01-02 — `POST /api/v1/households`,
/// `GET /api/v1/households/current` e o preenchimento de `SessionResponse.household`.
final class HouseholdControllerTests: XCTestCase {
    private func postHouseholds(
        app: Application,
        bearer: String?,
        body: [String: String]
    ) async throws -> (status: HTTPStatus, dto: HouseholdDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: HouseholdDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/households",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
                try req.content.encode(body, as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTO = try res.content.decode(HouseholdDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )

        return (capturedStatus, capturedDTO, capturedError)
    }

    private func getCurrentHousehold(
        app: Application,
        bearer: String?
    ) async throws -> (status: HTTPStatus, dto: HouseholdDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: HouseholdDTO?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .GET, "/api/v1/households/current",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
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

    // MARK: POST /api/v1/households

    func testCreateHouseholdSetsCreatorAsAdmin() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app, displayName: "Joel")
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let result = try await postHouseholds(
                app: app,
                bearer: token,
                body: ["name": "Família Silva"]
            )

            XCTAssertEqual(result.status, .created)
            let dto = try XCTUnwrap(result.dto)
            XCTAssertEqual(dto.name, "Família Silva")
            XCTAssertEqual(dto.myRole, .admin)
            XCTAssertEqual(dto.memberCount, 1)
        }
    }

    func testCreateHouseholdWithoutAuthorizationIsRejected() async throws {
        try await TestSupport.withApp { app in
            let result = try await postHouseholds(app: app, bearer: nil, body: ["name": "Família Silva"])
            XCTAssertEqual(result.status, .unauthorized)
        }
    }

    func testCreateHouseholdIgnoresClientSuppliedRole() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app)
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let result = try await postHouseholds(
                app: app,
                bearer: token,
                body: ["name": "Casa", "role": "crianca"]
            )

            XCTAssertEqual(result.status, .created)
            XCTAssertEqual(
                result.dto?.myRole, .admin,
                "um role no corpo do request nunca pode mudar o papel do criador (T-02-03)"
            )
        }
    }

    func testCreateHouseholdWhenAlreadyMemberIsRejectedWithConflict() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app)
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let first = try await postHouseholds(app: app, bearer: token, body: ["name": "Primeira Casa"])
            XCTAssertEqual(first.status, .created)

            let second = try await postHouseholds(app: app, bearer: token, body: ["name": "Segunda Casa"])
            XCTAssertEqual(second.status, .conflict)
            XCTAssertEqual(second.error?.code, .alreadyMember)
        }
    }

    func testCreateHouseholdValidatesNameLength() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app)
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let empty = try await postHouseholds(app: app, bearer: token, body: ["name": ""])
            XCTAssertEqual(empty.status, .badRequest)
            XCTAssertEqual(empty.error?.code, .validation)

            let whitespaceOnly = try await postHouseholds(app: app, bearer: token, body: ["name": "   "])
            XCTAssertEqual(whitespaceOnly.status, .badRequest)
            XCTAssertEqual(whitespaceOnly.error?.code, .validation)

            let tooLong = try await postHouseholds(
                app: app,
                bearer: token,
                body: ["name": String(repeating: "a", count: 41)]
            )
            XCTAssertEqual(tooLong.status, .badRequest)
            XCTAssertEqual(tooLong.error?.code, .validation)

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1, "nenhuma tentativa inválida pode criar linhas extras")

            let householdsCount = try await Household.query(on: app.db).count()
            XCTAssertEqual(householdsCount, 0, "nenhum nome inválido pode criar uma casa")
        }
    }

    // MARK: GET /api/v1/households/current

    func testGetCurrentHouseholdReturnsSameHouseholdAndRole() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app)
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let created = try await postHouseholds(app: app, bearer: token, body: ["name": "Família Silva"])
            let createdID = try XCTUnwrap(created.dto?.id)

            let current = try await getCurrentHousehold(app: app, bearer: token)
            XCTAssertEqual(current.status, .ok)
            XCTAssertEqual(current.dto?.id, createdID)
            XCTAssertEqual(current.dto?.myRole, .admin)
        }
    }

    func testGetCurrentHouseholdForUserWithoutHouseholdIsForbidden() async throws {
        try await TestSupport.withApp { app in
            let user = try await TestSupport.createTestUser(app: app)
            let token = try await TestSupport.makeAccessToken(app: app, userID: try user.requireID())

            let result = try await getCurrentHousehold(app: app, bearer: token)
            XCTAssertEqual(result.status, .forbidden)
            XCTAssertEqual(result.error?.code, .forbidden)
        }
    }

    // MARK: SessionResponse.household (AuthController)

    func testSessionResponseIncludesHouseholdWhenUserAlreadyHasOne() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString
            let firstToken = try await TestSupport.makeAppleIdentityToken(subject: subject)

            var capturedUserID: UUID?
            try await app.testable().test(
                .POST, "/api/v1/auth/session",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    try req.content.encode(SessionRequest(provider: .apple, identityToken: firstToken), as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    let body = try res.content.decode(SessionResponse.self)
                    XCTAssertNil(body.household, "usuário recém-criado ainda não tem casa")
                    capturedUserID = body.user.id
                }
            )
            let userID = try XCTUnwrap(capturedUserID)

            let accessToken = try await TestSupport.makeAccessToken(app: app, userID: userID)
            let created = try await postHouseholds(app: app, bearer: accessToken, body: ["name": "Família Silva"])
            XCTAssertEqual(created.status, .created)

            let secondToken = try await TestSupport.makeAppleIdentityToken(subject: subject)
            try await app.testable().test(
                .POST, "/api/v1/auth/session",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    try req.content.encode(SessionRequest(provider: .apple, identityToken: secondToken), as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    let body = try res.content.decode(SessionResponse.self)
                    XCTAssertEqual(
                        body.household?.name, "Família Silva",
                        "SessionResponse.household deve vir preenchido quando o usuário já tem casa"
                    )
                }
            )
        }
    }
}

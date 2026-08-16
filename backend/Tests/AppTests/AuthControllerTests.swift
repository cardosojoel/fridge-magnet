@testable import App
import Fluent
import JKLarShared
import XCTVapor

/// Corpo de `/health`, replicado aqui porque `HealthResponse` é `private` em
/// `configure.swift` — `@testable import` não relaxa `private` (só `internal`).
private struct HealthPayload: Content {
    var status: String
    var database: String
}

final class AuthControllerTests: XCTestCase {
    // MARK: Task 1 — fatia traçadora

    func testHealthEndpointReturnsOKWhenDatabaseIsReachable() async throws {
        try await TestSupport.withApp { app in
            try await app.testable().test(.GET, "/health") { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
                let body = try res.content.decode(HealthPayload.self)
                XCTAssertEqual(body.status, "ok")
                XCTAssertEqual(body.database, "ok")
            }
        }
    }

    func testAppleSignInIssuesSession() async throws {
        try await TestSupport.withApp { app in
            let token = try await TestSupport.makeAppleIdentityToken(email: "member@example.com")
            let sessionRequest = SessionRequest(
                provider: .apple,
                identityToken: token,
                displayName: "Joel",
                gender: .masculino
            )

            try await app.testable().test(
                .POST, "/api/v1/auth/session",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    try req.content.encode(sessionRequest, as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .ok)
                    let body = try res.content.decode(SessionResponse.self)
                    XCTAssertEqual(body.expiresIn, 900)
                    XCTAssertFalse(body.accessToken.isEmpty)
                    XCTAssertFalse(body.refreshToken.isEmpty)
                    XCTAssertEqual(body.user.displayName, "Joel")
                    XCTAssertNil(body.household)
                }
            )

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1, "um identity token válido deve criar exatamente uma linha em users")

            let linkedCount = try await LinkedIdentity.query(on: app.db).count()
            XCTAssertEqual(
                linkedCount, 1,
                "um identity token válido deve criar exatamente uma linha em linked_identities"
            )
        }
    }
}

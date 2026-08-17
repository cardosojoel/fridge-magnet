@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Cobre os oito casos de `<behavior>` da Task 2 do plano 01-11 (registro de device token
/// escopado por casa, IDENT-05/IDENT-06; a rota de push de teste; o boot falhando de forma
/// clara sem credenciais de APNs) mais a correção de ambiente da opção c aprovada em D-16.
/// O envio de push nestes testes sempre passa por `FakePushClient` — nenhum teste fala com o
/// APNs de verdade.
final class DeviceTokenTests: XCTestCase {
    // MARK: Helpers de request (mesmo padrão de InviteTests/RoleEnforcementTests)

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

    private static func postInvite(app: Application, bearer: String) async throws -> InviteDTO {
        var captured: InviteDTO?
        try await app.testable().test(
            .POST, "/api/v1/households/current/invites",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                captured = try res.content.decode(InviteDTO.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    private static func postJoin(app: Application, bearer: String, code: String) async throws {
        try await app.testable().test(
            .POST, "/api/v1/households/join",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(JoinHouseholdRequest(code: code), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )
    }

    /// Junta `memberBearer` à casa de `adminBearer` como `.adulto`, via convite real.
    private static func joinAsAdulto(app: Application, adminBearer: String, memberBearer: String) async throws {
        let invite = try await Self.postInvite(app: app, bearer: adminBearer)
        try await Self.postJoin(app: app, bearer: memberBearer, code: invite.code)
    }

    private static func makeUserAndToken(
        app: Application,
        displayName: String? = nil
    ) async throws -> (id: UUID, token: String) {
        let user = try await TestSupport.createTestUser(app: app, displayName: displayName)
        let userID = try user.requireID()
        let token = try await TestSupport.makeAccessToken(app: app, userID: userID)
        return (userID, token)
    }

    private static func postDevice(
        app: Application,
        bearer: String?,
        body: DeviceRegistrationRequest
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/devices",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                if let bearer {
                    req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                }
                try req.content.encode(body, as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status != .created, res.status != .ok {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedError)
    }

    private static func fetchDeviceTokenRow(
        app: Application,
        householdID: UUID?,
        userID: UUID? = nil,
        apnsToken: String
    ) async throws -> (userID: UUID, householdID: UUID, environment: String, updatedAt: Date)? {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID, userID: userID) { sql in
            guard let row = try await sql.raw(
                "SELECT user_id, household_id, environment, updated_at FROM device_tokens WHERE apns_token = \(bind: apnsToken)"
            ).first() else {
                return nil
            }
            return (
                try row.decode(column: "user_id", as: UUID.self),
                try row.decode(column: "household_id", as: UUID.self),
                try row.decode(column: "environment", as: String.self),
                try row.decode(column: "updated_at", as: Date.self)
            )
        }
    }

    private static func countDeviceTokenRows(
        app: Application,
        householdID: UUID?,
        userID: UUID? = nil,
        apnsToken: String
    ) async throws -> Int {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID, userID: userID) { sql in
            try await sql.raw(
                "SELECT * FROM device_tokens WHERE apns_token = \(bind: apnsToken)"
            ).all().count
        }
    }

    // MARK: POST /api/v1/devices — registro escopado no servidor (IDENT-05, IDENT-06)

    func testRegisterNewDeviceScopesToServerResolvedIdentityIgnoringBodyOverride() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            let household = try await Self.postHousehold(app: app, bearer: admin.token)

            // Corpo bruto (não `DeviceRegistrationRequest`, que nem carrega esses campos)
            // com `userId`/`householdId` forjados — a decodificação ignora as chaves que o
            // tipo não declara, então isto prova que o servidor nunca lê esses valores do
            // request (IDENT-06), mesmo que estejam no JSON.
            let bogusUserID = UUID()
            let bogusHouseholdID = UUID()
            var capturedStatus: HTTPStatus = .internalServerError
            try await app.testable().test(
                .POST, "/api/v1/devices",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
                    try req.content.encode([
                        "apnsToken": "device-token-1",
                        "platform": "ios",
                        "environment": "sandbox",
                        "userId": bogusUserID.uuidString,
                        "householdId": bogusHouseholdID.uuidString,
                    ], as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    capturedStatus = res.status
                }
            )
            XCTAssertEqual(capturedStatus, .created)

            let row = try await Self.fetchDeviceTokenRow(app: app, householdID: household.id, apnsToken: "device-token-1")
            let unwrapped = try XCTUnwrap(row)
            XCTAssertEqual(unwrapped.userID, admin.id)
            XCTAssertEqual(unwrapped.householdID, household.id)
            XCTAssertNotEqual(unwrapped.userID, bogusUserID)
            XCTAssertNotEqual(unwrapped.householdID, bogusHouseholdID)
        }
    }

    func testReregisteringSameTokenUpdatesExistingRowWithoutDuplicate() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            let household = try await Self.postHousehold(app: app, bearer: admin.token)

            let first = try await Self.postDevice(
                app: app, bearer: admin.token,
                body: DeviceRegistrationRequest(apnsToken: "device-token-2", platform: .ios, environment: .sandbox)
            )
            XCTAssertEqual(first.status, .created)
            let fetchedFirstRow = try await Self.fetchDeviceTokenRow(
                app: app, householdID: household.id, apnsToken: "device-token-2"
            )
            let firstRow = try XCTUnwrap(fetchedFirstRow)

            try await Task.sleep(nanoseconds: 10_000_000) // 10ms — garante updated_at mensurável

            let second = try await Self.postDevice(
                app: app, bearer: admin.token,
                body: DeviceRegistrationRequest(apnsToken: "device-token-2", platform: .macos, environment: .production)
            )
            XCTAssertEqual(second.status, .ok, "reenviar o mesmo apnsToken é uma atualização, não uma criação")

            let count = try await Self.countDeviceTokenRows(app: app, householdID: household.id, apnsToken: "device-token-2")
            XCTAssertEqual(count, 1, "reenviar o mesmo apnsToken nunca cria uma segunda linha")

            let fetchedSecondRow = try await Self.fetchDeviceTokenRow(
                app: app, householdID: household.id, apnsToken: "device-token-2"
            )
            let secondRow = try XCTUnwrap(fetchedSecondRow)
            XCTAssertGreaterThan(secondRow.updatedAt, firstRow.updatedAt)
            XCTAssertEqual(secondRow.environment, "production")
        }
    }

    func testDeviceMovingHouseholdsMovesRowInsteadOfDuplicating() async throws {
        try await TestSupport.withApp { app in
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            let householdA = try await Self.postHousehold(app: app, bearer: admin.token, name: "Casa A")

            let otherAdmin = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            let householdB = try await Self.postHousehold(app: app, bearer: otherAdmin.token, name: "Casa B")

            let token = "device-token-switch-households"
            let registerA = try await Self.postDevice(
                app: app, bearer: admin.token,
                body: DeviceRegistrationRequest(apnsToken: token, platform: .ios, environment: .sandbox)
            )
            XCTAssertEqual(registerA.status, .created)

            // Simula "o mesmo usuário passou a pertencer à casa B" sem depender de um fluxo
            // de sair/entrar (fora do escopo desta fase — ver 01-10): move só a linha de
            // `household_members` diretamente, usando as mesmas GUCs de sessão que a
            // produção usa (papel `jklar_app`, nunca `jklar_owner`). A cláusula
            // `user_id = app.current_user_id` da policy de `household_members`
            // (`CreateHouseholdSchema`) é o que torna esta linha visível/atualizável mesmo
            // já não estando mais em `household_id = A`.
            try await TestSupport.withAppRoleConnection(
                app: app, householdID: householdB.id, userID: admin.id
            ) { sql in
                try await sql.raw("""
                    UPDATE household_members SET household_id = \(bind: householdB.id)
                    WHERE user_id = \(bind: admin.id)
                    """).run()
            }

            let registerAgain = try await Self.postDevice(
                app: app, bearer: admin.token,
                body: DeviceRegistrationRequest(apnsToken: token, platform: .ios, environment: .sandbox)
            )
            XCTAssertEqual(registerAgain.status, .ok, "reregistro deve atualizar a linha existente, não criar outra")

            let countUnderA = try await Self.countDeviceTokenRows(app: app, householdID: householdA.id, apnsToken: token)
            XCTAssertEqual(countUnderA, 0, "a linha não pode mais aparecer sob o contexto da casa A")

            let countUnderB = try await Self.countDeviceTokenRows(app: app, householdID: householdB.id, apnsToken: token)
            XCTAssertEqual(countUnderB, 1, "a linha deve existir sob o contexto da nova casa B")
        }
    }

    func testCrossHouseholdSessionCannotReadDeviceTokensOfAnotherHousehold() async throws {
        try await TestSupport.withApp { app in
            let adminA = try await Self.makeUserAndToken(app: app, displayName: "Admin A")
            _ = try await Self.postHousehold(app: app, bearer: adminA.token, name: "Casa A")

            let adminB = try await Self.makeUserAndToken(app: app, displayName: "Admin B")
            let householdB = try await Self.postHousehold(app: app, bearer: adminB.token, name: "Casa B")

            let registerB = try await Self.postDevice(
                app: app, bearer: adminB.token,
                body: DeviceRegistrationRequest(apnsToken: "device-token-b", platform: .ios, environment: .sandbox)
            )
            XCTAssertEqual(registerB.status, .created)

            // Confere que o token existe mesmo, sob o contexto correto (B).
            let countUnderB = try await Self.countDeviceTokenRows(app: app, householdID: householdB.id, apnsToken: "device-token-b")
            XCTAssertEqual(countUnderB, 1)

            // Sessão de A (household_id=A, user_id=adminA) não enxerga o token de B: nem a
            // cláusula de household bate, nem a de user_id (adminA != adminB) — T-11-01.
            let countUnderA = try await Self.countDeviceTokenRows(
                app: app, householdID: nil, userID: adminA.id, apnsToken: "device-token-b"
            )
            XCTAssertEqual(countUnderA, 0, "uma sessão da casa A não pode ver device_tokens da casa B")
        }
    }

    // MARK: POST /api/v1/dev/push-test — só existe fora de `.testing`/produção (T-11-04)

    func testPushTestRouteDoesNotExistOutsideDevelopment() async throws {
        try await TestSupport.withApp { app in
            // `.testing` nunca chama `DeviceController.registerDevRoutes` — mesmo
            // código-caminho de `.production` (nenhum dos dois é `.development`, ver
            // `configure.swift`). A ausência é estrutural (a rota nunca é adicionada a
            // `app.routes`), não uma checagem em runtime.
            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)

            var capturedStatus: HTTPStatus = .internalServerError
            try await app.testable().test(
                .POST, "/api/v1/dev/push-test",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    capturedStatus = res.status
                }
            )
            XCTAssertEqual(capturedStatus, .notFound)
        }
    }

    func testPushTestRouteForbidsNonAdmin() async throws {
        try await TestSupport.withApp { app in
            // Registra a rota diretamente sobre esta `Application` de teste — o mesmo que
            // `configure.swift` faria se `app.environment == .development`. O gate de
            // ambiente em si é verificado por inspeção de código, não repetido aqui.
            try DeviceController.registerDevRoutes(app)

            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            _ = try await Self.postHousehold(app: app, bearer: admin.token)
            let adult = try await Self.makeUserAndToken(app: app, displayName: "Adulto")
            try await Self.joinAsAdulto(app: app, adminBearer: admin.token, memberBearer: adult.token)

            var capturedStatus: HTTPStatus = .internalServerError
            try await app.testable().test(
                .POST, "/api/v1/dev/push-test",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: adult.token)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    capturedStatus = res.status
                }
            )
            XCTAssertEqual(capturedStatus, .forbidden)
        }
    }

    // MARK: Boot falha sem credenciais de APNs (T-11-07)

    func testAPNSConfigFromEnvironmentFailsWithClearMessageWhenAnyVariableMissing() throws {
        let keys = ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY_P8", "APNS_TOPIC"]
        let originalValues = keys.reduce(into: [String: String?]()) { result, key in
            result[key] = ProcessInfo.processInfo.environment[key]
        }
        defer {
            for key in keys {
                if let value = originalValues[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        func setAllFourPresent() {
            setenv("APNS_KEY_ID", "test-key-id", 1)
            setenv("APNS_TEAM_ID", "test-team-id", 1)
            setenv("APNS_PRIVATE_KEY_P8", "test-pem", 1)
            setenv("APNS_TOPIC", "com.jklar.app.test", 1)
        }

        setAllFourPresent()
        XCTAssertNoThrow(try APNSConfig.fromEnvironment(), "com as quatro presentes, a config carrega sem erro")

        for missingKey in keys {
            setAllFourPresent()
            unsetenv(missingKey)

            XCTAssertThrowsError(try APNSConfig.fromEnvironment()) { error in
                guard case let APNSConfig.LoadError.missingEnvironmentVariable(name) = error else {
                    return XCTFail("esperava missingEnvironmentVariable, achou \(error)")
                }
                XCTAssertEqual(name, missingKey, "a mensagem de erro precisa nomear exatamente a variável ausente")
            }
        }
    }

    // MARK: D-16 opção c — correção de ambiente no primeiro BadDeviceToken

    func testPushServiceCorrectsEnvironmentOnBadDeviceTokenAndRetriesOnce() async throws {
        try await TestSupport.withApp { app in
            try DeviceController.registerDevRoutes(app)

            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let admin = try await Self.makeUserAndToken(app: app, displayName: "Admin")
            let household = try await Self.postHousehold(app: app, bearer: admin.token)

            let deviceToken = "device-token-bad-env"
            // Cliente declara `production` no registro — o `FakePushClient` vai simular que
            // isso está errado (o build real era sandbox), forçando o caminho de correção.
            let register = try await Self.postDevice(
                app: app, bearer: admin.token,
                body: DeviceRegistrationRequest(apnsToken: deviceToken, platform: .ios, environment: .production)
            )
            XCTAssertEqual(register.status, .created)

            await fakeClient.failOnce(forDeviceToken: deviceToken)

            var capturedStatus: HTTPStatus = .internalServerError
            try await app.testable().test(
                .POST, "/api/v1/dev/push-test",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    capturedStatus = res.status
                }
            )
            XCTAssertEqual(capturedStatus, .ok)

            let sent = await fakeClient.sentNotifications
            XCTAssertEqual(sent.count, 1, "só o retry corrigido conta como envio bem-sucedido — a primeira tentativa falhou")
            XCTAssertEqual(sent.first?.environment, .sandbox, "BadDeviceToken em production deve corrigir para sandbox")

            let fetchedRow = try await Self.fetchDeviceTokenRow(
                app: app, householdID: household.id, apnsToken: deviceToken
            )
            let row = try XCTUnwrap(fetchedRow)
            XCTAssertEqual(row.environment, "sandbox", "a linha precisa ficar com o ambiente corrigido gravado")
        }
    }
}

/// Cliente falso de push — usado por `DeviceTokenTests` e por `RecadoMentionPushTests`
/// (plano 02-02), nenhum teste fala com o APNs de verdade. `failOnce(forDeviceToken:)` simula
/// exatamente um `BadDeviceToken` para o próximo envio a esse token; qualquer envio depois
/// disso (o retry corrigido de `PushService`) sucede e fica registrado em
/// `sentNotifications`. `failAlways(forDeviceToken:)` (plano 02-02) simula um token
/// permanentemente morto — cada envio a ele falha, num `Set` separado do de `failOnce` para
/// não alterar o comportamento existente do teste do D-16.
actor FakePushClient: PushClient {
    private(set) var sentNotifications: [(token: String, environment: APNSEnvironment, title: String, body: String)] = []
    private var tokensThatFailOnce: Set<String> = []
    private var tokensThatAlwaysFail: Set<String> = []

    func failOnce(forDeviceToken token: String) {
        tokensThatFailOnce.insert(token)
    }

    func failAlways(forDeviceToken token: String) {
        tokensThatAlwaysFail.insert(token)
    }

    func sendAlertNotification(
        deviceToken: String,
        environment: APNSEnvironment,
        title: String,
        body: String
    ) async throws {
        if tokensThatAlwaysFail.contains(deviceToken) {
            throw BadDeviceTokenError()
        }
        if tokensThatFailOnce.remove(deviceToken) != nil {
            throw BadDeviceTokenError()
        }
        sentNotifications.append((deviceToken, environment, title, body))
    }
}

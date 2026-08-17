import XCTest
import JKLarShared
import UserNotifications
@testable import JKLar

/// Transporte falso dedicado a `PushRegistrationServiceTests` — diferente do `FakeTransport`
/// de `APIClientRefreshTests.swift` (que faz `/auth/session` sempre falhar de propósito,
/// simulando credencial de provedor inválida), este aceita login sempre com sucesso e simula
/// renovação real (401 até o bearer virar o token pós-refresh, o mesmo padrão de
/// `APIClientRefreshTests.FakeTransport`), além de controlar separadamente quantas vezes
/// `POST /api/v1/devices` deve falhar antes de aceitar — o que permite provar a contagem
/// exata de tentativas do backoff (D-15).
actor PushTestTransport: APIClientTransport {
    private(set) var recordedRequests: [URLRequest] = []
    private var deviceRegistrationFailuresRemaining: Int
    private let deviceRegistrationAlwaysFails: Bool
    private var acceptedAccessToken: String
    private let refreshedAccessToken: String
    private let refreshedRefreshToken: String

    init(
        deviceRegistrationFailuresBeforeSuccess: Int = 0,
        deviceRegistrationAlwaysFails: Bool = false,
        acceptedAccessToken: String = "post-refresh-access",
        refreshedAccessToken: String = "post-refresh-access",
        refreshedRefreshToken: String = "post-refresh-refresh"
    ) {
        self.deviceRegistrationFailuresRemaining = deviceRegistrationFailuresBeforeSuccess
        self.deviceRegistrationAlwaysFails = deviceRegistrationAlwaysFails
        self.acceptedAccessToken = acceptedAccessToken
        self.refreshedAccessToken = refreshedAccessToken
        self.refreshedRefreshToken = refreshedRefreshToken
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let path = request.url!.path

        if path.hasSuffix("auth/refresh") {
            acceptedAccessToken = refreshedAccessToken
            return (try! ServerWire.encoder.encode(makeSession()), httpResponse(request.url!, 200))
        }

        if path.hasSuffix("auth/session") {
            acceptedAccessToken = refreshedAccessToken
            return (try! ServerWire.encoder.encode(makeSession()), httpResponse(request.url!, 200))
        }

        if path.hasSuffix("api/v1/devices") {
            if deviceRegistrationAlwaysFails {
                throw URLError(.networkConnectionLost)
            }
            if deviceRegistrationFailuresRemaining > 0 {
                deviceRegistrationFailuresRemaining -= 1
                throw URLError(.networkConnectionLost)
            }
            return (Data(), httpResponse(request.url!, 201))
        }

        // Rota autenticada genérica: só aceita o bearer atual — qualquer outro (incluindo
        // nil ou um access token velho) devolve 401, disparando a renovação automática de
        // `APIClient.send` (mesmo padrão de `APIClientRefreshTests`). O corpo devolvido é um
        // `HouseholdDTO` válido — `SessionStore.hydrate()`/`currentHousehold()` (usado por
        // `testRootViewStateRemainsInHouseholdAfterPrimerDecline`) decodifica isso de
        // verdade, não só checa o status.
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        if bearer == "Bearer \(acceptedAccessToken)" {
            let household = HouseholdDTO(id: UUID(), name: "Casa Teste", memberCount: 1, myRole: .admin)
            return (try! ServerWire.encoder.encode(household), httpResponse(request.url!, 200))
        }
        return (Data(), httpResponse(request.url!, 401))
    }

    func requestCount(pathSuffix: String) -> Int {
        recordedRequests.filter { ($0.url?.path ?? "").hasSuffix(pathSuffix) }.count
    }

    /// Decodifica os corpos de todas as chamadas a `POST /api/v1/devices` — usado para
    /// afirmar hex do token/plataforma/ambiente (D-16).
    func deviceRegistrationBodies() -> [DeviceRegistrationRequest] {
        recordedRequests
            .filter { ($0.url?.path ?? "").hasSuffix("api/v1/devices") }
            .compactMap { $0.httpBody }
            .compactMap { try? JSONDecoder().decode(DeviceRegistrationRequest.self, from: $0) }
    }

    private func makeSession() -> SessionResponse {
        SessionResponse(accessToken: refreshedAccessToken, refreshToken: refreshedRefreshToken, expiresIn: 900, user: UserDTO(id: UUID()))
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// Fake de `PushAuthorizationRequesting` — nenhum teste toca o prompt real do sistema.
actor FakeAuthorizationRequester: PushAuthorizationRequesting {
    private var result: Result<Bool, Error>
    private(set) var requestCount = 0

    init(result: Result<Bool, Error> = .success(true)) {
        self.result = result
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        return try result.get()
    }
}

/// Sleeper falso — devolve na hora e só registra os intervalos pedidos, para a suíte não
/// esperar segundos de verdade nem os testes de backoff ficarem lentos/flaky.
actor FakeBackoffSleeper: PushBackoffSleeping {
    private(set) var recordedDelays: [Double] = []

    func sleep(seconds: Double) async {
        recordedDelays.append(seconds)
    }
}

@MainActor
final class PushRegistrationServiceTests: XCTestCase {
    override func tearDown() {
        KeychainTokenStore.delete()
        UserDefaults.standard.removeObject(forKey: "com.jklar.push.lastKnownApnsTokenHex")
        UserDefaults.standard.removeObject(forKey: "com.jklar.push.primerShown")
        super.tearDown()
    }

    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeService(
        transport: PushTestTransport,
        authorizationResult: Result<Bool, Error> = .success(true)
    ) -> (PushRegistrationService, APIClient, FakeAuthorizationRequester, FakeBackoffSleeper) {
        let client = APIClient(transport: transport, baseURL: url())
        let requester = FakeAuthorizationRequester(result: authorizationResult)
        let sleeper = FakeBackoffSleeper()
        let service = PushRegistrationService(apiClient: client, notificationCenter: requester, sleeper: sleeper)
        return (service, client, requester, sleeper)
    }

    // MARK: - Task 1: registro, backoff, retomada, reregistro (D-15)

    func testDeviceTokenConvertedToHexAndRegisteredWithPlatformAndEnvironment() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"))
        let transport = PushTestTransport()
        let (service, _, _, _) = makeService(transport: transport)

        await service.registerDeviceToken(Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let bodies = await transport.deviceRegistrationBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.apnsToken, "deadbeef")
        #if os(iOS)
        XCTAssertEqual(bodies.first?.platform, .ios)
        #elseif os(macOS)
        XCTAssertEqual(bodies.first?.platform, .macos)
        #endif
        // D-16 opção c (01-11-SUMMARY.md): builds de teste/Debug sempre reportam sandbox —
        // o backend é quem corrige no primeiro BadDeviceToken, nunca o cliente infere.
        XCTAssertEqual(bodies.first?.environment, .sandbox)
    }

    func testNetworkFailureRetriesExactlyThreeTimesWithBackoff() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"))
        let transport = PushTestTransport(deviceRegistrationAlwaysFails: true)
        let (service, _, _, sleeper) = makeService(transport: transport)

        await service.registerDeviceToken(Data([0x01, 0x02]))

        let attempts = await transport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(attempts, 3, "nem 1, nem infinitas — exatamente 3 tentativas")

        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [2, 8], "backoff exponencial entre as 3 tentativas")
    }

    func testPendingRegistrationSurvivesRelaunchAndResumesAtNextLaunch() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"))
        let failingTransport = PushTestTransport(deviceRegistrationAlwaysFails: true)
        let (firstLaunchService, _, _, _) = makeService(transport: failingTransport)

        await firstLaunchService.registerDeviceToken(Data([0xAA, 0xBB]))
        let attemptsBeforeRelaunch = await failingTransport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(attemptsBeforeRelaunch, 3, "as 3 tentativas do primeiro lançamento esgotaram sem sucesso")

        // "Relançamento" = uma nova instância de PushRegistrationService (processo novo),
        // agora contra um backend que aceita — o token pendente sobrevive porque foi
        // persistido em UserDefaults por `registerDeviceToken`, não guardado só em memória.
        let succeedingTransport = PushTestTransport()
        let (secondLaunchService, _, _, _) = makeService(transport: succeedingTransport)

        await secondLaunchService.resumePendingRegistrationIfNeeded()

        let bodies = await succeedingTransport.deviceRegistrationBodies()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.apnsToken, "aabb", "o mesmo token pendente é retomado, não um novo")
    }

    func testNewLoginTriggersNewDeviceRegistration() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"))
        let transport = PushTestTransport()
        let (service, client, _, _) = makeService(transport: transport)

        // Um device token já é conhecido de uma sessão anterior — o primeiro registro conta
        // como 1 tentativa.
        await service.registerDeviceToken(Data([0x01, 0x02, 0x03]))
        let countBeforeLogin = await transport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(countBeforeLogin, 1)

        _ = try await client.createSession(provider: .apple, identityToken: "tok", displayName: nil, gender: nil)

        let countAfterLogin = await transport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(countAfterLogin, 2, "um novo login dispara um novo registro do token já conhecido")
    }

    func testSessionRenewalTriggersNewDeviceRegistration() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "stale-access", refreshToken: "old-refresh"))
        let transport = PushTestTransport(acceptedAccessToken: "post-refresh-access", refreshedAccessToken: "post-refresh-access")
        let (service, client, _, _) = makeService(transport: transport)

        await service.registerDeviceToken(Data([0x0A, 0x0B]))
        let countBeforeRenewal = await transport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(countBeforeRenewal, 1)

        // O bearer salvo (`stale-access`) nunca bate no que o transporte aceita — força o
        // caminho de renovação de `APIClient.send` (401 → `/auth/refresh` → retentativa).
        _ = try? await client.send(path: "api/v1/generic", method: "GET", body: nil, requiresAuth: true)

        let countAfterRenewal = await transport.requestCount(pathSuffix: "api/v1/devices")
        XCTAssertEqual(countAfterRenewal, 2, "uma renovação de sessão dispara um novo registro do token já conhecido")
    }

    func testFailureToRegisterForRemoteNotificationsDoesNotCrashOrBlockAnything() async throws {
        let transport = PushTestTransport()
        let (service, _, _, _) = makeService(transport: transport)

        // Nenhum caminho de push pode derrubar o app (T-12-02/D-14) — só não deve lançar nem
        // travar; nenhum estado observável muda.
        service.didFailToRegister(error: URLError(.notConnectedToInternet))

        XCTAssertFalse(service.hasShownPrimer, "uma falha do SO não marca o primer como mostrado nem altera nenhum outro estado")
    }

    // MARK: - Task 2: primer (D-13/D-14) não reaparece, decisão nunca toca o roteador

    func testPrimerDoesNotReappearAfterDecline() async throws {
        let transport = PushTestTransport()
        let (service, _, _, _) = makeService(transport: transport)

        XCTAssertFalse(service.hasShownPrimer)
        service.markPrimerShown()
        XCTAssertTrue(service.hasShownPrimer, "não reaparece depois de recusado")
    }

    func testPrimerDoesNotReappearAfterGrant() async throws {
        let transport = PushTestTransport()
        let (service, _, _, _) = makeService(transport: transport, authorizationResult: .success(true))

        XCTAssertFalse(service.hasShownPrimer)
        _ = await service.requestAuthorization()
        XCTAssertTrue(service.hasShownPrimer, "não reaparece depois de concedido")
    }

    func testRootViewStateRemainsInHouseholdAfterPrimerDecline() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"))
        let transport = PushTestTransport(acceptedAccessToken: "access", refreshedAccessToken: "access")
        let (service, client, _, _) = makeService(transport: transport)
        let sessionStore = SessionStore(apiClient: client)
        await sessionStore.hydrate()
        XCTAssertEqual(sessionStore.state, .inHousehold)

        // Recusa (botão "Agora não" ou prompt negado) — o único efeito colateral é marcar o
        // primer como mostrado; nada no fluxo de push toca `SessionStore`.
        service.markPrimerShown()

        XCTAssertEqual(sessionStore.state, .inHousehold, "recusar o primer nunca altera o estado do roteador")
    }
}

import XCTest
import FridgeMagnetShared
@testable import FridgeMagnet

/// `Transport` falso — nenhum servidor real é tocado. Simula o backend por comportamento
/// (aceita só o access token "correto" no momento, rejeita qualquer outro com 401) em vez de
/// por fila posicional de respostas: isso é o que torna o teste de concorrência determinístico
/// mesmo sem controlar a ordem exata de agendamento das 10 tasks concorrentes.
actor FakeTransport: APIClientTransport {
    private var acceptedAccessToken: String
    private let refreshedAccessToken: String
    private let refreshedRefreshToken: String
    private let refreshStatus: Int
    private let householdData: Data
    private let householdAlwaysFails: Bool

    private(set) var refreshCallCount = 0
    private(set) var recordedRequests: [URLRequest] = []

    init(
        acceptedAccessToken: String,
        refreshedAccessToken: String = "refreshed-access",
        refreshedRefreshToken: String = "refreshed-refresh",
        household: HouseholdDTO = HouseholdDTO(id: UUID(), name: "Casa Teste", memberCount: 3, myRole: .admin),
        refreshStatus: Int = 200,
        householdAlwaysFails: Bool = false
    ) {
        self.acceptedAccessToken = acceptedAccessToken
        self.refreshedAccessToken = refreshedAccessToken
        self.refreshedRefreshToken = refreshedRefreshToken
        self.refreshStatus = refreshStatus
        self.householdData = try! ServerWire.encoder.encode(household)
        self.householdAlwaysFails = householdAlwaysFails
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let url = request.url!
        let path = url.path

        if path.hasSuffix("/auth/refresh") {
            refreshCallCount += 1
            guard refreshStatus == 200 else {
                return (Data(), response(url, refreshStatus))
            }
            acceptedAccessToken = refreshedAccessToken
            let session = SessionResponse(
                accessToken: refreshedAccessToken,
                refreshToken: refreshedRefreshToken,
                expiresIn: 900,
                user: UserDTO(id: UUID())
            )
            return (try! ServerWire.encoder.encode(session), response(url, 200))
        }

        if path.hasSuffix("/auth/session") {
            // Simula credencial de provedor inválida — nunca deve disparar renovação.
            return (Data(), response(url, 401))
        }

        // Qualquer outra rota autenticada (ex.: /households/current) usada pelos testes.
        if householdAlwaysFails {
            return (Data(), response(url, 401))
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        if bearer == "Bearer \(acceptedAccessToken)" {
            return (householdData, response(url, 200))
        }
        return (Data(), response(url, 401))
    }

    func requests(pathSuffix: String) -> [URLRequest] {
        recordedRequests.filter { ($0.url?.path ?? "").hasSuffix(pathSuffix) }
    }

    private func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// Flag observável a partir de um `@Sendable` closure, sem `@unchecked Sendable` — usado para
/// afirmar que `onSessionExpiredHandler` foi chamado quando a renovação falha.
actor Flag {
    private(set) var value = false
    func set() { value = true }
}

final class APIClientRefreshTests: XCTestCase {
    override func tearDown() {
        KeychainTokenStore.delete()
        super.tearDown()
    }

    private func url() -> URL { URL(string: "http://test.local")! }

    func testRequestIsRetriedExactlyOnceAfter401WithIdenticalBody() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "stale-access", refreshToken: "old-refresh"))
        let transport = FakeTransport(acceptedAccessToken: "post-refresh-access", refreshedAccessToken: "post-refresh-access")
        let client = APIClient(transport: transport, baseURL: url())

        let body = try ServerWire.encoder.encode(["ping": "pong"])
        _ = try? await client.send(path: "api/v1/households/current", method: "POST", body: body, requiresAuth: true)

        let requests = await transport.requests(pathSuffix: "households/current")
        XCTAssertEqual(requests.count, 2, "exatamente uma retentativa, não mais")
        XCTAssertEqual(requests[0].httpBody, body)
        XCTAssertEqual(requests[1].httpBody, body, "o corpo repetido é idêntico ao original")

        let refreshCount = await transport.refreshCallCount
        XCTAssertEqual(refreshCount, 1)
    }

    func testSecond401AfterRefreshDoesNotTriggerAnotherRetry() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "stale-access", refreshToken: "old-refresh"))
        // household sempre falha mesmo com o token novo: simula um recurso que continua
        // rejeitando mesmo após a renovação ter sucesso.
        let transport = FakeTransport(acceptedAccessToken: "irrelevant", householdAlwaysFails: true)
        let client = APIClient(transport: transport, baseURL: url())

        do {
            _ = try await client.currentHousehold()
            XCTFail("esperava erro 401 persistente")
        } catch {
            // esperado
        }

        let refreshCount = await transport.refreshCallCount
        XCTAssertEqual(refreshCount, 1, "uma renovação, mesmo com 401 persistente depois dela")
        let requestCount = await transport.requests(pathSuffix: "households/current").count
        XCTAssertEqual(requestCount, 2, "original + uma única retentativa, nunca um laço")
    }

    func testTenConcurrentCallsTriggerExactlyOneRefreshCall() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "stale-access", refreshToken: "old-refresh"))
        let household = HouseholdDTO(id: UUID(), name: "Casa Concorrente", memberCount: 5, myRole: .adulto)
        let transport = FakeTransport(
            acceptedAccessToken: "post-refresh-access",
            refreshedAccessToken: "post-refresh-access",
            household: household
        )
        let client = APIClient(transport: transport, baseURL: url())

        try await withThrowingTaskGroup(of: HouseholdDTO?.self) { group in
            for _ in 0..<10 {
                group.addTask { try await client.currentHousehold() }
            }
            for try await result in group {
                XCTAssertEqual(result?.name, "Casa Concorrente")
            }
        }

        let refreshCount = await transport.refreshCallCount
        XCTAssertEqual(refreshCount, 1, "dez 401 simultâneos produzem uma única renovação, não dez")
    }

    func testRefreshFailureClearsKeychainAndSignalsSessionExpired() async throws {
        KeychainTokenStore.save(TokenPair(accessToken: "stale-access", refreshToken: "old-refresh"))
        let transport = FakeTransport(acceptedAccessToken: "never-matches", refreshStatus: 401)
        let client = APIClient(transport: transport, baseURL: url())

        let flag = Flag()
        await client.setSessionExpiredHandler {
            await flag.set()
        }

        do {
            _ = try await client.currentHousehold()
            XCTFail("esperava sessionExpired")
        } catch let error as APIClientError {
            XCTAssertEqual(error, .sessionExpired)
        }

        XCTAssertNil(KeychainTokenStore.read(), "Keychain apagado quando a renovação falha")
        let expired = await flag.value
        XCTAssertTrue(expired, "onSessionExpiredHandler chamado quando a renovação falha")
    }

    func testUnauthenticatedRouteDoesNotAttemptRefreshOn401() async throws {
        let transport = FakeTransport(acceptedAccessToken: "irrelevant")
        let client = APIClient(transport: transport, baseURL: url())

        do {
            _ = try await client.createSession(provider: .apple, identityToken: "tok", displayName: nil, gender: nil)
            XCTFail("esperava erro — /auth/session sempre 401 no fake")
        } catch {
            // esperado
        }

        let refreshCount = await transport.refreshCallCount
        XCTAssertEqual(refreshCount, 0, "rota não-autenticada nunca tenta renovar em 401")
    }
}

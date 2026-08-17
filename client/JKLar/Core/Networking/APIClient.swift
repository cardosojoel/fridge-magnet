import Foundation
import JKLarShared

/// Transporte HTTP injetável — é isso que permite testar a renovação em 401 sem servidor
/// nenhum (`APIClientRefreshTests` usa um `Transport` falso; produção usa
/// `URLSessionTransport`).
protocol APIClientTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: APIClientTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        return (data, http)
    }
}

enum APIClientError: Error, Equatable {
    /// A resposta não veio como HTTP (transporte quebrado) — nunca esperado em produção.
    case invalidResponse
    /// A sessão local não pôde ser renovada (refresh ausente, expirado ou revogado no
    /// servidor) — quem chamou deve tratar isso como "sessão encerrada", nunca repetir.
    case sessionExpired
    /// Resposta HTTP com status de erro que não é 401-tratável-por-renovação.
    case http(status: Int)
    /// O corpo da resposta não decodificou como o tipo esperado.
    case decoding
    /// Resposta de erro com corpo `APIErrorResponse` decodificado — quem chamou consome
    /// `APIErrorCode` tipado, nunca a `message` (que é só para exibição), e nunca um
    /// `switch` em string (plano 01-09, T-09-04).
    case apiError(APIErrorCode)
}

/// Cliente HTTP do JK Lar (D-09, D-10, D-12). `actor` para serializar renovações de 401
/// concorrentes: dez requests que recebem 401 ao mesmo tempo devem produzir uma única
/// chamada a `/auth/refresh`, nunca dez — sem isso, rotações concorrentes do mesmo refresh
/// token acionariam a detecção de reuso do plano 01-04 e derrubariam a sessão legítima do
/// membro (T-05-09, 01-RESEARCH.md).
///
/// Zero-trust do `.claude/CLAUDE.md`: este arquivo manda um token de provedor e recebe uma
/// sessão — nenhuma decisão de autorização é tomada aqui, e nenhum detalhe de arquitetura do
/// backend (nome de tabela, RLS, segredo) aparece em nenhuma linha abaixo.
actor APIClient {
    private let transport: APIClientTransport
    private let baseURL: URL
    private var refreshTask: Task<TokenPair, Error>?
    private var onSessionExpired: (@Sendable () async -> Void)?
    private var onSessionEstablished: (@Sendable () async -> Void)?

    init(transport: APIClientTransport = URLSessionTransport(), baseURL: URL = APIConfiguration.baseURL) {
        self.transport = transport
        self.baseURL = baseURL
    }

    /// `SessionStore` registra aqui o que fazer quando a sessão local é encerrada pelo
    /// próprio `APIClient` (renovação falhou) — nunca o inverso, `APIClient` nunca importa
    /// `SessionStore` diretamente, para não inverter a direção de dependência
    /// networking → estado de app.
    func setSessionExpiredHandler(_ handler: @escaping @Sendable () async -> Void) {
        onSessionExpired = handler
    }

    /// `PushRegistrationService` registra aqui (plano 01-12, D-15) — chamado sempre que este
    /// `APIClient` grava um novo par de tokens no Keychain, o que cobre exatamente os dois
    /// momentos que D-15 exige reregistro: um novo login bem-sucedido (`createSession`) e
    /// uma renovação de sessão bem-sucedida (`doRefresh`). Mesma direção de dependência do
    /// `onSessionExpired` acima: `APIClient` nunca importa `PushRegistrationService`.
    func setSessionEstablishedHandler(_ handler: @escaping @Sendable () async -> Void) {
        onSessionEstablished = handler
    }

    // MARK: - Rotas

    /// `POST /api/v1/auth/session` — já parametrizado por `AuthProvider`: Google e Microsoft
    /// (plano 01-08) reusam este mesmo método sem alterar `APIClient`.
    func createSession(
        provider: AuthProvider,
        identityToken: String,
        displayName: String?,
        gender: Gender?
    ) async throws -> SessionResponse {
        let body = try Self.encoder.encode(
            SessionRequest(provider: provider, identityToken: identityToken, displayName: displayName, gender: gender)
        )
        let (data, response) = try await send(path: "api/v1/auth/session", method: "POST", body: body, requiresAuth: false)
        guard response.statusCode == 200 else {
            throw APIClientError.http(status: response.statusCode)
        }
        let session = try Self.decode(SessionResponse.self, from: data)
        KeychainTokenStore.save(TokenPair(accessToken: session.accessToken, refreshToken: session.refreshToken))
        await onSessionEstablished?()
        return session
    }

    /// `GET /api/v1/households/current` — 403 significa "sessão válida, sem casa ainda"
    /// (`HouseholdContextMiddleware`, plano 01-02), nunca um erro: devolve `nil`, não lança.
    func currentHousehold() async throws -> HouseholdDTO? {
        let (data, response) = try await send(path: "api/v1/households/current", method: "GET", body: nil, requiresAuth: true)
        if response.statusCode == 403 {
            return nil
        }
        guard response.statusCode == 200 else {
            throw APIClientError.http(status: response.statusCode)
        }
        return try Self.decode(HouseholdDTO.self, from: data)
    }

    /// `POST /api/v1/households` (plano 01-02/01-07) — o papel do criador é sempre `.admin`,
    /// decidido no servidor; `CreateHouseholdRequest` nem carrega um campo de papel (D-02).
    /// Não listado no `<files>` do plano 01-07, mas necessário para o gate de criar-ou-entrar
    /// funcionar de verdade contra o backend — ver deviations do plano 01-07.
    func createHousehold(name: String) async throws -> HouseholdDTO {
        let body = try Self.encoder.encode(CreateHouseholdRequest(name: name))
        let (data, response) = try await send(path: "api/v1/households", method: "POST", body: body, requiresAuth: true)
        guard response.statusCode == 201 else {
            throw APIClientError.http(status: response.statusCode)
        }
        return try Self.decode(HouseholdDTO.self, from: data)
    }

    /// `GET /api/v1/households/current/members` (plano 01-02, exposto ao cliente pela
    /// primeira vez no plano 01-07) — a lista real de membros, nunca inferida no cliente a
    /// partir de `sessionStore.currentUser` (que pode estar vazio após um relançamento do
    /// app sem um novo `/auth/session`).
    func members() async throws -> [MemberDTO] {
        let (data, response) = try await send(
            path: "api/v1/households/current/members", method: "GET", body: nil, requiresAuth: true
        )
        guard response.statusCode == 200 else {
            throw APIClientError.http(status: response.statusCode)
        }
        return try Self.decode([MemberDTO].self, from: data)
    }

    /// `PATCH /api/v1/auth/profile` (plano 01-07, D-04) — atualização explícita do gênero
    /// coletado no formulário de criar casa. Nenhuma lógica de tema é derivada deste valor
    /// nesta fase (Fase 9).
    func updateProfile(gender: Gender) async throws {
        let body = try Self.encoder.encode(UpdateProfileRequest(gender: gender))
        let (_, response) = try await send(path: "api/v1/auth/profile", method: "PATCH", body: body, requiresAuth: true)
        guard response.statusCode == 204 else {
            throw APIClientError.http(status: response.statusCode)
        }
    }

    /// `POST /api/v1/households/current/invites` (plano 01-06, exposto ao cliente pela
    /// primeira vez aqui) — só admin recebe 201; um não-admin recebe 403 (T-09-02,
    /// `RequireRoleMiddleware` do servidor é a linha de defesa real, o botão escondido na
    /// UI é só conveniência).
    func createInvite() async throws -> InviteDTO {
        let (data, response) = try await send(
            path: "api/v1/households/current/invites", method: "POST", body: nil, requiresAuth: true
        )
        guard response.statusCode == 201 else {
            throw APIClientError.http(status: response.statusCode)
        }
        return try Self.decode(InviteDTO.self, from: data)
    }

    /// `GET /api/v1/households/current/invites` — roda sob RLS na rota escopada; um
    /// convite de outra casa não tem como chegar aqui (IDENT-05, T-09-03). Ordenado do mais
    /// recente para o mais antigo pelo servidor.
    func listInvites() async throws -> [InviteDTO] {
        let (data, response) = try await send(
            path: "api/v1/households/current/invites", method: "GET", body: nil, requiresAuth: true
        )
        guard response.statusCode == 200 else {
            throw APIClientError.http(status: response.statusCode)
        }
        return try Self.decode([InviteDTO].self, from: data)
    }

    /// `POST /api/v1/households/join` (plano 01-06) — mapeia `APIErrorResponse.code` para
    /// `APIClientError.apiError`, nunca deixa a UI ler a `message` do servidor: uma mudança
    /// de texto no backend não pode alterar comportamento no cliente (T-09-04).
    func joinHousehold(code: String) async throws -> HouseholdDTO {
        let body = try Self.encoder.encode(JoinHouseholdRequest(code: code))
        let (data, response) = try await send(path: "api/v1/households/join", method: "POST", body: body, requiresAuth: true)
        guard response.statusCode == 200 else {
            throw Self.typedError(from: data, fallbackStatus: response.statusCode)
        }
        return try Self.decode(HouseholdDTO.self, from: data)
    }

    /// `DELETE /api/v1/households/current/members/:memberID` (plano 01-10) — admin-only no
    /// servidor (RequireRoleMiddleware([.admin])); mapeia lastAdmin/cannotRemoveSelf para
    /// APIClientError.apiError, mesma tradução tipada de joinHousehold (T-09-04/T-10-07). Um
    /// não-admin recebe .http(status: 403) — nenhum código tipado esperado para esse caminho,
    /// já que a tela nunca deveria chamar isto sem `canRemove(_:)` ter sido verdadeiro.
    func removeMember(id: UUID) async throws {
        let (data, response) = try await send(
            path: "api/v1/households/current/members/\(id.uuidString)", method: "DELETE", body: nil, requiresAuth: true
        )
        guard response.statusCode == 204 else {
            throw Self.typedError(from: data, fallbackStatus: response.statusCode)
        }
    }

    /// `DELETE /api/v1/households/current/membership` (plano 01-10) — auto-serviço, qualquer
    /// papel pode sair; `lastAdmin` é o único código de erro tipado esperado aqui.
    func leaveHousehold() async throws {
        let (data, response) = try await send(
            path: "api/v1/households/current/membership", method: "DELETE", body: nil, requiresAuth: true
        )
        guard response.statusCode == 204 else {
            throw Self.typedError(from: data, fallbackStatus: response.statusCode)
        }
    }

    /// `POST /api/v1/devices` (plano 01-11, exposto ao cliente aqui) — um dispositivo novo
    /// devolve 201, um `apnsToken` já existente (upsert, ex.: reregistro de D-15) devolve
    /// 200; os dois são sucesso para `PushRegistrationService`. `userId`/`householdId`
    /// nunca fazem parte de `DeviceRegistrationRequest` — sempre resolvidos no servidor a
    /// partir do JWT/contexto (IDENT-06, `.claude/CLAUDE.md`).
    func registerDevice(_ request: DeviceRegistrationRequest) async throws {
        let body = try Self.encoder.encode(request)
        let (_, response) = try await send(path: "api/v1/devices", method: "POST", body: body, requiresAuth: true)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw APIClientError.http(status: response.statusCode)
        }
    }

    /// `POST /api/v1/auth/logout` — D-11: o logout do servidor é o que vale. Sempre apaga o
    /// Keychain local, mesmo que a chamada de rede falhe (o dispositivo não deve continuar
    /// achando que está logado só porque a rede caiu no momento do logout).
    func logout() async {
        guard let pair = KeychainTokenStore.read() else { return }
        let body = try? Self.encoder.encode(LogoutRequest(refreshToken: pair.refreshToken))
        _ = try? await send(path: "api/v1/auth/logout", method: "POST", body: body, requiresAuth: false)
        KeychainTokenStore.delete()
    }

    // MARK: - Núcleo: Bearer + renovação em 401 serializada

    /// Não-`private` de propósito: `APIClientRefreshTests` chama isto diretamente para provar
    /// o comportamento de 401/renovação/retentativa sem depender de uma rota de domínio
    /// específica ter corpo. Ainda assim não faz parte da API pública do módulo (sem
    /// `public`).
    func send(
        path: String,
        method: String,
        body: Data?,
        requiresAuth: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let accessToken = requiresAuth ? KeychainTokenStore.read()?.accessToken : nil
        let request = Self.buildRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: accessToken)
        let (data, response) = try await transport.send(request)

        // Rotas não-autenticadas (ex.: /auth/session) nunca tentam renovar em 401 — um 401
        // ali é "credencial de provedor inválida", não "sessão do JK Lar expirada".
        guard requiresAuth, response.statusCode == 401 else {
            return (data, response)
        }

        // Uma única retentativa (T-05-05): se a renovação falhar, o erro sobe e a sessão já
        // foi encerrada por `doRefresh`. Se a retentativa também vier 401, devolvemos essa
        // resposta sem tentar de novo — evita laço infinito.
        let newPair = try await performRefresh()
        let retryRequest = Self.buildRequest(baseURL: baseURL, path: path, method: method, body: body, accessToken: newPair.accessToken)
        return try await transport.send(retryRequest)
    }

    /// Serializa renovações concorrentes: a primeira chamada cria a `Task` de renovação e a
    /// guarda; chamadas concorrentes seguintes encontram a `Task` já em voo e só aguardam o
    /// mesmo resultado, em vez de disparar uma segunda chamada a `/auth/refresh`.
    private func performRefresh() async throws -> TokenPair {
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { try await self.doRefresh() }
        refreshTask = task
        do {
            let pair = try await task.value
            refreshTask = nil
            return pair
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func doRefresh() async throws -> TokenPair {
        guard let current = KeychainTokenStore.read() else {
            throw APIClientError.sessionExpired
        }
        let body = try Self.encoder.encode(RefreshRequest(refreshToken: current.refreshToken))
        let request = Self.buildRequest(baseURL: baseURL, path: "api/v1/auth/refresh", method: "POST", body: body, accessToken: nil)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            // SessionService (01-04) colapsa token inexistente/expirado/revogado no mesmo
            // 401 — não há motivo para diferenciar aqui. Qualquer resposta que não seja 200
            // significa "esta sessão acabou": apaga o Keychain e avisa quem está observando.
            KeychainTokenStore.delete()
            await onSessionExpired?()
            throw APIClientError.sessionExpired
        }
        let session = try Self.decode(SessionResponse.self, from: data)
        let pair = TokenPair(accessToken: session.accessToken, refreshToken: session.refreshToken)
        KeychainTokenStore.save(pair)
        await onSessionEstablished?()
        return pair
    }

    private static func buildRequest(
        baseURL: URL,
        path: String,
        method: String,
        body: Data?,
        accessToken: String?
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIClientError.decoding
        }
    }

    /// Traduz um corpo de erro em `APIClientError.apiError(APIErrorCode)` quando o servidor
    /// devolveu um `APIErrorResponse` reconhecível; cai para `.http(status:)` genérico só
    /// quando o corpo não decodifica (ex.: erro de infraestrutura antes do roteamento
    /// Vapor).
    private static func typedError(from data: Data, fallbackStatus: Int) -> APIClientError {
        guard let decoded = try? decoder.decode(APIErrorResponse.self, from: data) else {
            return .http(status: fallbackStatus)
        }
        return .apiError(decoded.code)
    }
}

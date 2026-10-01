@testable import App
import Crypto
import CryptoExtras
import Fluent
import FluentSQL
import Foundation
import FridgeMagnetShared
import JWT
import Vapor
import XCTVapor

/// Apoio de teste do backend inteiro.
///
/// Sobe o `Application` em `.testing` contra o banco `fridgemagnet_test` (papéis `fridgemagnet_app` e
/// `fridgemagnet_owner` já criados por `scripts/dev-db.sh`), roda as migrations com o DSN owner
/// (dentro de `configure(_:)`, chamado normalmente), limpa as tabelas de identidade entre
/// testes, e assina identity tokens de provedor falsos com um par de chaves RSA em
/// memória. O JWKS correspondente é servido por um `Client` falso registrado ANTES de
/// `configure(_:)` rodar — `AppleTokenVerifier` nunca toca a rede real da Apple durante os
/// testes.
/// `DatabaseID` só de teste — a segunda conexão `fridgemagnet_app` independente usada por
/// `TestSupport.withAppRoleConnection` (plano 01-02, `RLSIsolationTests`).
extension DatabaseID {
    static var appRoleTestConnection: DatabaseID { .init(string: "appRoleTestConnection") }
}

enum TestSupport {
    static let testAppleAudience = "com.fridgemagnet.app.test"
    static let testAppleKeyID = "test-apple-key-1"

    /// Plano 01-08 — mesma forma da Apple, uma chave/kid por provedor para que o caso
    /// "assinado pela chave errada" prove algo real (assinar com a chave da Apple e
    /// apresentar como Google, por exemplo, também deve falhar, já que os JWKS nunca se
    /// misturam).
    static let testGoogleAudience = "google-client-id.test.googleusercontent.com"
    static let testGoogleKeyID = "test-google-key-1"
    static let testMicrosoftAudience = "00000000-test-microsoft-client-id"
    static let testMicrosoftKeyID = "test-microsoft-key-1"

    /// Chave RSA "oficial" — a que o JWKS de teste publica. Gerada uma vez por processo de
    /// teste (2048 bits é rápido o bastante para não estourar o orçamento de latência de
    /// 60s da suíte completa).
    static let appleSigningKey: _RSA.Signing.PrivateKey = {
        // Geração de chave em teste, nunca em produção — força-desempacotado porque uma
        // falha aqui é um bug de ambiente de teste, não um caminho de erro de runtime.
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    static let googleSigningKey: _RSA.Signing.PrivateKey = {
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    static let microsoftSigningKey: _RSA.Signing.PrivateKey = {
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    /// Uma segunda chave, nunca publicada em nenhum dos três JWKS servidos pelos testes —
    /// usada pelo caso "chave errada" da matriz de rejeição (planos 01-01 Task 2 e 01-08
    /// Task 1): um token assinado por ela nunca deve verificar, porque nenhum JWK
    /// conhecido corresponde a ela, em nenhum dos três provedores.
    static let rogueSigningKey: _RSA.Signing.PrivateKey = {
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    /// Senha de um papel do Postgres local, lida do ambiente e nunca versionada. É a mesma
    /// que `scripts/dev-db.sh` usou ao criar os papéis `fridgemagnet_app` e `fridgemagnet_owner`.
    static func dbPassword(_ variable: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
            fatalError("\(variable) não definida — exporte a mesma senha usada em scripts/dev-db.sh")
        }
        return value
    }

    /// Sobe uma `Application` de teste completa: registra o `Client` falso de JWKS, roda
    /// `configure(_:)` (bancos, migrations, chave JWT efêmera, provedores, rotas) e limpa
    /// as tabelas de identidade para isolar este teste dos anteriores.
    static func makeApp() async throws -> Application {
        setenv(
            "DATABASE_URL",
            "postgres://fridgemagnet_app:\(dbPassword("FRIDGEMAGNET_APP_PASSWORD"))@127.0.0.1:5432/fridgemagnet_test?sslmode=disable",
            1
        )
        setenv(
            "DATABASE_OWNER_URL",
            "postgres://fridgemagnet_owner:\(dbPassword("FRIDGEMAGNET_OWNER_PASSWORD"))@127.0.0.1:5432/fridgemagnet_test?sslmode=disable",
            1
        )
        setenv("APPLE_AUDIENCE", testAppleAudience, 1)
        setenv("GOOGLE_CLIENT_ID", testGoogleAudience, 1)
        setenv("MICROSOFT_CLIENT_ID", testMicrosoftAudience, 1)

        let app = try await Application.make(.testing)

        // Registrado ANTES de configure(_:) — é lido em configure() ao construir os três
        // verificadores, então precisa existir antes dessa leitura. Um único `Client` falso
        // roteia por URL entre os três JWKS/documento de descoberta (plano 01-08).
        app.clients.use { appInstance in
            ProviderJWKSStubClient(eventLoop: appInstance.eventLoopGroup.any())
        }

        try await configure(app)
        try await cleanIdentityTables(app)
        return app
    }

    /// Sobe uma `Application` de teste, roda `body` e garante o shutdown mesmo se `body`
    /// lançar — evita vazar conexões de Postgres entre testes quando uma asserção falha.
    static func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await makeApp()
        do {
            try await body(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// `TRUNCATE` via conexão owner — chamado dentro de `makeApp()`. Cada teste começa com
    /// as quatro tabelas de identidade e de tenant vazias, mesmo rodando contra o mesmo
    /// banco `fridgemagnet_test` persistente entre execuções da suíte.
    ///
    /// A conexão owner ignora a policy RLS de `households`/`household_members` só porque
    /// `TRUNCATE` (ao contrário de `SELECT`/`DELETE`) não é filtrado por Row-Level Security
    /// no PostgreSQL — é uma operação de nível de tabela inteira, não de linha.
    static func cleanIdentityTables(_ app: Application) async throws {
        guard let sql = app.db(.owner) as? SQLDatabase else {
            fatalError("Banco owner não é um SQLDatabase — não é possível truncar as tabelas de teste")
        }
        try await sql.raw("""
            TRUNCATE TABLE refresh_tokens, household_invites, device_tokens,
                recado_mentions, recado_comments, recado_reactions, recado_photos, recados,
                household_members, households, linked_identities, users
            RESTART IDENTITY CASCADE
            """).run()
    }

    // MARK: Plano 02-01 — mural de recados

    /// Cria uma casa com `count` membros (1 admin + `count - 1` adultos), todos entrando por
    /// convite real (mesma rota que a produção usa, nunca um atalho que grava linhas direto
    /// no banco). Único helper novo em `TestSupport` desta fase — os planos 02-02, 02-03 e
    /// 02-04 põem os próprios auxiliares como métodos privados da própria classe de teste
    /// (convenção já usada por `DeviceTokenTests`).
    static func makeHouseholdWithMembers(
        app: Application,
        count: Int
    ) async throws -> (household: HouseholdDTO, members: [(userID: UUID, token: String)]) {
        precondition(count >= 1, "makeHouseholdWithMembers exige pelo menos 1 membro (o admin)")

        let adminUser = try await createTestUser(app: app, displayName: "Admin")
        let adminID = try adminUser.requireID()
        let adminToken = try await makeAccessToken(app: app, userID: adminID)

        var capturedHousehold: HouseholdDTO?
        try await app.testable().test(
            .POST, "/api/v1/households",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateHouseholdRequest(name: "Casa de Teste"), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                capturedHousehold = try res.content.decode(HouseholdDTO.self)
            }
        )
        let household = try XCTUnwrap(capturedHousehold)

        var members: [(userID: UUID, token: String)] = [(adminID, adminToken)]

        for index in 1..<count {
            var capturedInvite: InviteDTO?
            try await app.testable().test(
                .POST, "/api/v1/households/current/invites",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .created)
                    capturedInvite = try res.content.decode(InviteDTO.self)
                }
            )
            let invite = try XCTUnwrap(capturedInvite)

            let memberUser = try await createTestUser(app: app, displayName: "Membro \(index)")
            let memberID = try memberUser.requireID()
            let memberToken = try await makeAccessToken(app: app, userID: memberID)

            try await app.testable().test(
                .POST, "/api/v1/households/join",
                beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                    req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                    try req.content.encode(JoinHouseholdRequest(code: invite.code), as: .json)
                },
                afterResponse: { (res: XCTHTTPResponse) async throws in
                    XCTAssertEqual(res.status, .ok)
                }
            )

            members.append((memberID, memberToken))
        }

        return (household, members)
    }

    // MARK: Plano 01-02 — plano de tenant

    /// Cria um `User` mínimo direto no banco (sem passar por `/auth/session`) — usado pelos
    /// testes do plano de tenant, que não precisam re-testar o fluxo de login em si.
    static func createTestUser(app: Application, displayName: String? = nil) async throws -> User {
        let user = User(displayName: displayName)
        try await user.save(on: app.db)
        return user
    }

    /// Assina um access token do FridgeMagnet (não um identity token de provedor) para `userID` —
    /// o mesmo `AccessTokenPayload` que `AuthController` emite, usado pelos testes do plano
    /// de tenant para autenticar chamadas a `POST /api/v1/households` e
    /// `GET /api/v1/households/current` sem depender de `/auth/session`.
    static func makeAccessToken(app: Application, userID: UUID) async throws -> String {
        let payload = AccessTokenPayload(
            subject: SubjectClaim(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(900))
        )
        return try await app.jwt.keys.sign(payload)
    }

    /// Uma conexão Postgres separada, autenticada como `fridgemagnet_app` (não `fridgemagnet_owner`) —
    /// usada só por `RLSIsolationTests` para provar isolamento entre casas com um papel de
    /// banco sujeito de verdade às policies (o app inteiro já roda como `fridgemagnet_app` via
    /// `DATABASE_URL`; este helper abre uma segunda conexão independente da `Application`
    /// para poder controlar exatamente qual contexto de tenant está ativo em cada asserção,
    /// sem interferir na conexão de runtime do app de teste).
    ///
    /// `householdID`, se não `nil`, aplica `app.current_household_id` via
    /// `set_config(..., true)` (equivalente a `SET LOCAL`) dentro de uma transação aberta
    /// para toda a duração de `body` — nunca fora de transação, pelo mesmo motivo do
    /// `HouseholdContextMiddleware` de produção. `nil` deixa a conexão sem nenhum contexto
    /// de casa aplicado, para o caso "fail-closed sem contexto" do `<behavior>`.
    static func withAppRoleConnection<T: Sendable>(
        app: Application,
        householdID: UUID? = nil,
        userID: UUID? = nil,
        _ body: @escaping @Sendable (any SQLDatabase) async throws -> T
    ) async throws -> T {
        let appPassword = dbPassword("FRIDGEMAGNET_APP_PASSWORD")
        let dsn = "postgres://fridgemagnet_app:\(appPassword)@127.0.0.1:5432/fridgemagnet_test?sslmode=disable"
        app.databases.use(try .postgres(url: dsn), as: .appRoleTestConnection)

        return try await app.db(.appRoleTestConnection).transaction { transactionDB in
            guard let sql = transactionDB as? SQLDatabase else {
                fatalError("Conexão de teste não é um SQLDatabase")
            }
            if let userID {
                try await sql.raw("SELECT set_config('app.current_user_id', \(bind: userID.uuidString), true)").run()
            }
            if let householdID {
                try await sql.raw(
                    "SELECT set_config('app.current_household_id', \(bind: householdID.uuidString), true)"
                ).run()
            }
            return try await body(sql)
        }
    }

    /// JWK público correspondente a `appleSigningKey`, no formato servido por
    /// `https://appleid.apple.com/auth/keys`.
    static func jwks() throws -> JWKS {
        let publicKey = try Insecure.RSA.PublicKey(backing: appleSigningKey.publicKey)
        let primitives = try publicKey.getKeyPrimitives()
        let jwk = JWK.rsa(
            .rs256,
            identifier: JWKIdentifier(string: testAppleKeyID),
            modulus: primitives.modulus.base64URLEncodedString(),
            exponent: primitives.publicExponent.base64URLEncodedString()
        )
        return JWKS(keys: [jwk])
    }

    /// Assina um identity token Apple falso, com todas as claims parametrizáveis — usado
    /// pelo caminho feliz e por toda a matriz de rejeição da Task 2.
    ///
    /// - Parameters:
    ///   - emailVerified: `nil` omite a claim inteira do JSON assinado (caso "ausente");
    ///     `true`/`false` grava o valor explicitamente.
    ///   - signingKey: `nil` usa `appleSigningKey` (a chave publicada no JWKS de teste).
    ///     Passar `rogueSigningKey` produz o caso "chave errada".
    static func makeAppleIdentityToken(
        subject: String = UUID().uuidString,
        email: String? = "member@example.com",
        emailVerified: Bool? = true,
        issuer: String = "https://appleid.apple.com",
        audience: String = TestSupport.testAppleAudience,
        expiration: Date = Date().addingTimeInterval(300),
        signingKey: _RSA.Signing.PrivateKey? = nil,
        kid: String = TestSupport.testAppleKeyID
    ) async throws -> String {
        let keys = JWTKeyCollection()
        let rsaPrivateKey = try Insecure.RSA.PrivateKey(backing: signingKey ?? appleSigningKey)
        await keys.add(rsa: rsaPrivateKey, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))

        let payload = AppleIdentityToken(
            issuer: IssuerClaim(value: issuer),
            audience: AudienceClaim(value: audience),
            expires: ExpirationClaim(value: expiration),
            issuedAt: IssuedAtClaim(value: Date()),
            subject: SubjectClaim(value: subject),
            email: email,
            emailVerified: emailVerified.map(BoolClaim.init(value:))
        )
        return try await keys.sign(payload, kid: JWKIdentifier(string: kid))
    }

    // MARK: Plano 01-08 — Google e Microsoft

    /// JWK público correspondente a `googleSigningKey`, no formato servido por
    /// `https://www.googleapis.com/oauth2/v3/certs`.
    static func googleJWKS() throws -> JWKS {
        let publicKey = try Insecure.RSA.PublicKey(backing: googleSigningKey.publicKey)
        let primitives = try publicKey.getKeyPrimitives()
        let jwk = JWK.rsa(
            .rs256,
            identifier: JWKIdentifier(string: testGoogleKeyID),
            modulus: primitives.modulus.base64URLEncodedString(),
            exponent: primitives.publicExponent.base64URLEncodedString()
        )
        return JWKS(keys: [jwk])
    }

    /// JWK público correspondente a `microsoftSigningKey`, no formato servido pelo
    /// `jwks_uri` do documento de descoberta da autoridade `common`.
    static func microsoftJWKS() throws -> JWKS {
        let publicKey = try Insecure.RSA.PublicKey(backing: microsoftSigningKey.publicKey)
        let primitives = try publicKey.getKeyPrimitives()
        let jwk = JWK.rsa(
            .rs256,
            identifier: JWKIdentifier(string: testMicrosoftKeyID),
            modulus: primitives.modulus.base64URLEncodedString(),
            exponent: primitives.publicExponent.base64URLEncodedString()
        )
        return JWKS(keys: [jwk])
    }

    /// URL de JWKS que o documento de descoberta falso de teste anuncia — a mesma URL real
    /// que `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`
    /// devolve em produção (confirmado por request real em 2026-08-16), servida aqui só
    /// para o roteador de `ProviderJWKSStubClient` distinguir a chamada de JWKS da chamada
    /// de descoberta.
    static let microsoftTestJWKSURI = "https://login.microsoftonline.com/common/discovery/v2.0/keys"

    private struct DiscoveryDocumentPayload: Encodable {
        var jwksURI: String
        var issuer: String
        enum CodingKeys: String, CodingKey {
            case jwksURI = "jwks_uri"
            case issuer
        }
    }

    /// Documento de descoberta OIDC falso — mesmo formato e mesmos valores reais de
    /// `jwks_uri`/`issuer` que a autoridade `common` da Microsoft devolve hoje, para que
    /// `MicrosoftTokenVerifier` exercite seu caminho de leitura dinâmica sem tocar a rede.
    static func microsoftDiscoveryDocument() -> some Encodable {
        DiscoveryDocumentPayload(
            jwksURI: microsoftTestJWKSURI,
            issuer: "https://login.microsoftonline.com/{tenantid}/v2.0"
        )
    }

    /// Assina um id_token do Google falso, com todas as claims parametrizáveis — mesma
    /// forma de `makeAppleIdentityToken`.
    static func makeGoogleIdentityToken(
        subject: String = UUID().uuidString,
        email: String? = "member@example.com",
        emailVerified: Bool? = true,
        issuer: String = "https://accounts.google.com",
        audience: String = TestSupport.testGoogleAudience,
        expiration: Date = Date().addingTimeInterval(300),
        signingKey: _RSA.Signing.PrivateKey? = nil,
        kid: String = TestSupport.testGoogleKeyID
    ) async throws -> String {
        let keys = JWTKeyCollection()
        let rsaPrivateKey = try Insecure.RSA.PrivateKey(backing: signingKey ?? googleSigningKey)
        await keys.add(rsa: rsaPrivateKey, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))

        let payload = GoogleIdentityToken(
            issuer: IssuerClaim(value: issuer),
            subject: SubjectClaim(value: subject),
            audience: AudienceClaim(value: audience),
            authorizedPresenter: audience,
            issuedAt: IssuedAtClaim(value: Date()),
            expires: ExpirationClaim(value: expiration),
            email: email,
            emailVerified: emailVerified.map(BoolClaim.init(value:))
        )
        return try await keys.sign(payload, kid: JWKIdentifier(string: kid))
    }

    /// Assina um id_token da Microsoft falso. `tenantID` é sempre um GUID (a Microsoft
    /// sempre inclui `tid`, inclusive para contas pessoais — o GUID fixo
    /// `9188040d-6c67-4c5b-b112-36a304b66dad`); `issuer`, quando `nil`, é derivado
    /// corretamente de `tenantID` — passar um `issuer` explícito é o que produz o caso
    /// "token de outro tenant" da matriz de rejeição (Task 1).
    static func makeMicrosoftIdentityToken(
        subject: String = UUID().uuidString,
        email: String? = "member@example.com",
        preferredUsername: String? = nil,
        emailVerified: Bool? = true,
        tenantID: String = "9188040d-6c67-4c5b-b112-36a304b66dad",
        issuer: String? = nil,
        audience: String = TestSupport.testMicrosoftAudience,
        expiration: Date = Date().addingTimeInterval(300),
        signingKey: _RSA.Signing.PrivateKey? = nil,
        kid: String = TestSupport.testMicrosoftKeyID
    ) async throws -> String {
        let keys = JWTKeyCollection()
        let rsaPrivateKey = try Insecure.RSA.PrivateKey(backing: signingKey ?? microsoftSigningKey)
        await keys.add(rsa: rsaPrivateKey, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))

        let effectiveIssuer = issuer ?? "https://login.microsoftonline.com/\(tenantID)/v2.0"

        let payload = MicrosoftIdentityToken(
            subject: SubjectClaim(value: subject),
            issuer: IssuerClaim(value: effectiveIssuer),
            audience: AudienceClaim(value: audience),
            expiration: ExpirationClaim(value: expiration),
            tenantID: tenantID,
            email: email,
            preferredUsername: preferredUsername,
            emailVerified: emailVerified
        )
        return try await keys.sign(payload, kid: JWKIdentifier(string: kid))
    }
}

/// `Client` falso que roteia por URL entre os três JWKS/documento de descoberta de teste —
/// para que nenhum dos três verificadores (Apple, Google, Microsoft) jamais toque a rede
/// real durante os testes. Registrado via `app.clients.use(...)` em
/// `TestSupport.makeApp()`, antes de `configure(_:)` construir os verificadores.
struct ProviderJWKSStubClient: Client {
    let eventLoop: EventLoop

    func delegating(to eventLoop: EventLoop) -> Client {
        ProviderJWKSStubClient(eventLoop: eventLoop)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        eventLoop.makeFutureWithTask {
            let url = request.url.string
            if url.contains("appleid.apple.com") {
                return try Self.jsonResponse(TestSupport.jwks())
            }
            if url.contains("googleapis.com") {
                return try Self.jsonResponse(TestSupport.googleJWKS())
            }
            if url.contains("well-known/openid-configuration") {
                return try Self.jsonResponse(TestSupport.microsoftDiscoveryDocument())
            }
            if url == TestSupport.microsoftTestJWKSURI || url.contains("login.microsoftonline.com") {
                return try Self.jsonResponse(TestSupport.microsoftJWKS())
            }
            return ClientResponse(status: .notFound)
        }
    }

    private static func jsonResponse(_ value: some Encodable) throws -> ClientResponse {
        let data = try JSONEncoder().encode(value)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return ClientResponse(status: .ok, headers: headers, body: buffer)
    }
}

extension Data {
    /// Base64url sem padding (RFC 4648 §5) — formato exigido pelos campos `n`/`e` de um JWK.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

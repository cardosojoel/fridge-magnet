@testable import App
import Crypto
import CryptoExtras
import Fluent
import FluentSQL
import Foundation
import JWT
import Vapor
import XCTVapor

/// Apoio de teste do backend inteiro.
///
/// Sobe o `Application` em `.testing` contra o banco `jklar_test` (papéis `jklar_app` e
/// `jklar_owner` já criados por `scripts/dev-db.sh`), roda as migrations com o DSN owner
/// (dentro de `configure(_:)`, chamado normalmente), limpa as tabelas de identidade entre
/// testes, e assina identity tokens de provedor falsos com um par de chaves RSA em
/// memória. O JWKS correspondente é servido por um `Client` falso registrado ANTES de
/// `configure(_:)` rodar — `AppleTokenVerifier` nunca toca a rede real da Apple durante os
/// testes.
/// `DatabaseID` só de teste — a segunda conexão `jklar_app` independente usada por
/// `TestSupport.withAppRoleConnection` (plano 01-02, `RLSIsolationTests`).
extension DatabaseID {
    static var appRoleTestConnection: DatabaseID { .init(string: "appRoleTestConnection") }
}

enum TestSupport {
    static let testAppleAudience = "com.jklar.app.test"
    static let testAppleKeyID = "test-apple-key-1"

    /// Chave RSA "oficial" — a que o JWKS de teste publica. Gerada uma vez por processo de
    /// teste (2048 bits é rápido o bastante para não estourar o orçamento de latência de
    /// 60s da suíte completa).
    static let appleSigningKey: _RSA.Signing.PrivateKey = {
        // Geração de chave em teste, nunca em produção — força-desempacotado porque uma
        // falha aqui é um bug de ambiente de teste, não um caminho de erro de runtime.
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    /// Uma segunda chave, nunca publicada no JWKS servido pelos testes — usada só pelo
    /// caso "chave errada" da matriz de rejeição (Task 2): um token assinado por ela nunca
    /// deve verificar, porque nenhum JWK conhecido corresponde a ela.
    static let rogueSigningKey: _RSA.Signing.PrivateKey = {
        try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    }()

    /// Sobe uma `Application` de teste completa: registra o `Client` falso de JWKS, roda
    /// `configure(_:)` (bancos, migrations, chave JWT efêmera, provedores, rotas) e limpa
    /// as tabelas de identidade para isolar este teste dos anteriores.
    static func makeApp() async throws -> Application {
        setenv(
            "DATABASE_URL",
            "postgres://jklar_app:REMOVIDO@127.0.0.1:5432/jklar_test?sslmode=disable",
            1
        )
        setenv(
            "DATABASE_OWNER_URL",
            "postgres://jklar_owner:REMOVIDO@127.0.0.1:5432/jklar_test?sslmode=disable",
            1
        )
        setenv("APPLE_AUDIENCE", testAppleAudience, 1)

        let app = try await Application.make(.testing)

        // Registrado ANTES de configure(_:) — é lido em configure() ao construir o
        // AppleTokenVerifier, então precisa existir antes dessa leitura.
        app.clients.use { appInstance in
            AppleJWKSStubClient(eventLoop: appInstance.eventLoopGroup.any())
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
    /// banco `jklar_test` persistente entre execuções da suíte.
    ///
    /// A conexão owner ignora a policy RLS de `households`/`household_members` só porque
    /// `TRUNCATE` (ao contrário de `SELECT`/`DELETE`) não é filtrado por Row-Level Security
    /// no PostgreSQL — é uma operação de nível de tabela inteira, não de linha.
    static func cleanIdentityTables(_ app: Application) async throws {
        guard let sql = app.db(.owner) as? SQLDatabase else {
            fatalError("Banco owner não é um SQLDatabase — não é possível truncar as tabelas de teste")
        }
        try await sql.raw("""
            TRUNCATE TABLE refresh_tokens, household_invites, device_tokens, household_members,
                households, linked_identities, users
            RESTART IDENTITY CASCADE
            """).run()
    }

    // MARK: Plano 01-02 — plano de tenant

    /// Cria um `User` mínimo direto no banco (sem passar por `/auth/session`) — usado pelos
    /// testes do plano de tenant, que não precisam re-testar o fluxo de login em si.
    static func createTestUser(app: Application, displayName: String? = nil) async throws -> User {
        let user = User(displayName: displayName)
        try await user.save(on: app.db)
        return user
    }

    /// Assina um access token do JK Lar (não um identity token de provedor) para `userID` —
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

    /// Uma conexão Postgres separada, autenticada como `jklar_app` (não `jklar_owner`) —
    /// usada só por `RLSIsolationTests` para provar isolamento entre casas com um papel de
    /// banco sujeito de verdade às policies (o app inteiro já roda como `jklar_app` via
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
        let appPassword = ProcessInfo.processInfo.environment["JKLAR_APP_PASSWORD"] ?? "REMOVIDO"
        let dsn = "postgres://jklar_app:\(appPassword)@127.0.0.1:5432/jklar_test?sslmode=disable"
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
}

/// `Client` falso que sempre serve o JWKS de teste (`TestSupport.jwks()`) — para que
/// `AppleTokenVerifier` nunca faça uma chamada de rede real durante os testes. Registrado
/// via `app.clients.use(...)` em `TestSupport.makeApp()`.
struct AppleJWKSStubClient: Client {
    let eventLoop: EventLoop

    func delegating(to eventLoop: EventLoop) -> Client {
        AppleJWKSStubClient(eventLoop: eventLoop)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        eventLoop.makeFutureWithTask {
            let jwks = try TestSupport.jwks()
            let data = try JSONEncoder().encode(jwks)
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return ClientResponse(status: .ok, headers: headers, body: buffer)
        }
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

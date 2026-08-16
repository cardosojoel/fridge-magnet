import Fluent
import FluentPostgresDriver
import FluentSQL
import JWT
import Vapor

/// `@main` do executável `App` — o único ponto de composição do processo (Fase 1
/// estabelece esta convenção; planos seguintes acrescentam suas migrations, seus
/// `RouteCollection` e seus clientes aqui, não em arquivos de cinco linhas espalhados).
@main
struct Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

/// `DatabaseID` do papel dono do schema (`jklar_owner`) — só as migrations rodam aqui. O
/// default `.psql` (`DATABASE_URL`) usa o papel de runtime `jklar_app`, sem DDL.
extension DatabaseID {
    static var owner: DatabaseID { .init(string: "owner") }
}

/// Configuração por provedor de identidade, lida do ambiente — nunca hardcoded, nunca
/// versionada. Os três provedores já ficam previstos (D-01: Apple, Google, Microsoft);
/// só a Apple tem verificador implementado nesta fatia (plano 01-01). Google e Microsoft
/// chegam no plano 01-08.
struct ProviderConfig: Sendable {
    struct Provider: Sendable {
        var audience: String
        var issuer: String
        var jwksURL: URI
    }

    var apple: Provider?
    var google: Provider?
    var microsoft: Provider?

    static func fromEnvironment() -> ProviderConfig {
        var config = ProviderConfig()
        if let appleAudience = Environment.get("APPLE_AUDIENCE") {
            config.apple = Provider(
                audience: appleAudience,
                issuer: "https://appleid.apple.com",
                jwksURL: "https://appleid.apple.com/auth/keys"
            )
        }
        if let googleClientID = Environment.get("GOOGLE_CLIENT_ID") {
            config.google = Provider(
                audience: googleClientID,
                issuer: "https://accounts.google.com",
                jwksURL: "https://www.googleapis.com/oauth2/v3/certs"
            )
        }
        if let microsoftClientID = Environment.get("MICROSOFT_CLIENT_ID") {
            config.microsoft = Provider(
                audience: microsoftClientID,
                issuer: "https://login.microsoftonline.com/common/v2.0",
                jwksURL: "https://login.microsoftonline.com/common/discovery/v2.0/keys"
            )
        }
        return config
    }
}

private struct ProviderConfigKey: StorageKey {
    typealias Value = ProviderConfig
}

private struct AppleTokenVerifierKey: StorageKey {
    typealias Value = AppleTokenVerifier
}

extension Application {
    var providerConfig: ProviderConfig {
        get { self.storage[ProviderConfigKey.self] ?? .init() }
        set { self.storage[ProviderConfigKey.self] = newValue }
    }

    /// `nil` até `APPLE_AUDIENCE` existir no ambiente — só então o login com Apple fica
    /// disponível. Guardado na `Application` (não recriado por request) porque o cache
    /// interno do JWKS de `AppleTokenVerifier` precisa sobreviver entre requests.
    var appleTokenVerifier: AppleTokenVerifier? {
        get { self.storage[AppleTokenVerifierKey.self] }
        set { self.storage[AppleTokenVerifierKey.self] = newValue }
    }
}

func configure(_ app: Application) async throws {
    // MARK: Bancos — dois DatabaseID, dois papéis de banco (scripts/dev-db.sh cria ambos).
    guard let databaseURL = Environment.get("DATABASE_URL") else {
        fatalError("DATABASE_URL não definida — DSN do papel de runtime jklar_app (ver scripts/dev-db.sh)")
    }
    guard let databaseOwnerURL = Environment.get("DATABASE_OWNER_URL") else {
        fatalError("DATABASE_OWNER_URL não definida — DSN do papel dono jklar_owner (ver scripts/dev-db.sh)")
    }
    app.databases.use(try .postgres(url: databaseURL), as: .psql)
    app.databases.use(try .postgres(url: databaseOwnerURL), as: .owner)

    // A migration do plano de identidade roda no database owner — jklar_app nunca tem
    // DDL, só o DML explicitamente concedido no fim da migration.
    app.migrations.add(CreateIdentitySchema(), to: .owner)
    try await app.autoMigrate().get()

    // MARK: Assinatura JWT — ES256, chave carregada do ambiente.
    // Nunca gerar chave efêmera fora de `.testing`: todo restart invalidaria as sessões
    // existentes (refresh tokens de 30 dias, plano 01-04, ficariam órfãos).
    if app.environment == .testing {
        await app.jwt.keys.add(ecdsa: ES256PrivateKey())
    } else {
        guard let privateKeyPEM = Environment.get("JWT_PRIVATE_KEY_PEM") else {
            fatalError("JWT_PRIVATE_KEY_PEM não definida — obrigatória fora de .testing")
        }
        let key = try ES256PrivateKey(pem: privateKeyPEM)
        await app.jwt.keys.add(ecdsa: key)
    }

    // MARK: Provedores de identidade.
    let providerConfig = ProviderConfig.fromEnvironment()
    app.providerConfig = providerConfig
    if let appleConfig = providerConfig.apple {
        app.appleTokenVerifier = AppleTokenVerifier(
            client: app.client,
            jwksURL: appleConfig.jwksURL,
            audience: appleConfig.audience
        )
    }

    // MARK: Asserção de papel de banco no boot.
    // Fora de `.testing`, servir com `jklar_owner` desativaria a Row-Level Security que o
    // plano 01-02 instala nas tabelas de tenant — e o sintoma seria silêncio: tudo
    // funcionaria e nada estaria isolado. Abortar o processo é a única resposta segura.
    if app.environment != .testing {
        try await assertRuntimeDatabaseRole(app)
    }

    // MARK: Rotas.
    app.get("health", use: healthCheck)
    try app.register(collection: AuthController())
}

/// `SELECT current_user` real contra o banco de runtime (`.psql`, papel `jklar_app`
/// esperado). Aborta o processo se o resultado for `jklar_owner` — ver comentário acima.
private func assertRuntimeDatabaseRole(_ app: Application) async throws {
    guard let sql = app.db(.psql) as? SQLDatabase else {
        fatalError("Banco de runtime (.psql) não é um SQLDatabase — impossível checar current_user")
    }
    guard let row = try await sql.raw("SELECT current_user").first() else {
        fatalError("SELECT current_user não devolveu nenhuma linha")
    }
    let currentUser = try row.decode(column: "current_user", as: String.self)
    guard currentUser != "jklar_owner" else {
        fatalError("Backend conectado como jklar_owner — recusando subir (desativaria a RLS do plano 01-02)")
    }
}

/// `GET /health` — 200 só quando um `SELECT 1` real no Postgres funciona.
private struct HealthResponse: Content {
    var status: String
    var database: String
}

@Sendable
private func healthCheck(req: Request) async throws -> Response {
    guard let sql = req.db(.psql) as? SQLDatabase else {
        throw Abort(.internalServerError)
    }
    do {
        _ = try await sql.raw("SELECT 1").first()
    } catch {
        let response = Response(status: .internalServerError)
        try response.content.encode(HealthResponse(status: "error", database: "error"), as: .json)
        return response
    }
    let response = Response(status: .ok)
    try response.content.encode(HealthResponse(status: "ok", database: "ok"), as: .json)
    return response
}

import APNS
import APNSCore
import Crypto
import Fluent
import FluentPostgresDriver
import FluentSQL
import FridgeMagnetShared
import JWT
import SotoS3
import Vapor
import VaporAPNS

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

/// `DatabaseID` do papel dono do schema (`fridgemagnet_owner`) — só as migrations rodam aqui. O
/// default `.psql` (`DATABASE_URL`) usa o papel de runtime `fridgemagnet_app`, sem DDL.
extension DatabaseID {
    static var owner: DatabaseID { .init(string: "owner") }
}

/// Configuração por provedor de identidade, lida do ambiente — nunca hardcoded, nunca
/// versionada. Os três provedores (D-01: Apple, Google, Microsoft) têm verificador
/// implementado desde o plano 01-08. `jwksURL` para Apple/Google aponta direto ao endpoint
/// JWKS do provedor; para Microsoft, aponta ao documento de descoberta OIDC da autoridade
/// `common` — `MicrosoftTokenVerifier` lê `jwks_uri`/`issuer` dali em tempo de execução, sem
/// nenhuma URL de JWKS adivinhada (T-08-04).
struct ProviderConfig: Sendable {
    struct Provider: Sendable {
        var audience: String
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
                jwksURL: "https://appleid.apple.com/auth/keys"
            )
        }
        if let googleClientID = Environment.get("GOOGLE_CLIENT_ID") {
            config.google = Provider(
                audience: googleClientID,
                jwksURL: "https://www.googleapis.com/oauth2/v3/certs"
            )
        }
        if let microsoftClientID = Environment.get("MICROSOFT_CLIENT_ID") {
            config.microsoft = Provider(
                audience: microsoftClientID,
                jwksURL: "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration"
            )
        }
        return config
    }
}

private struct ProviderConfigKey: StorageKey {
    typealias Value = ProviderConfig
}

extension Application {
    var providerConfig: ProviderConfig {
        get { self.storage[ProviderConfigKey.self] ?? .init() }
        set { self.storage[ProviderConfigKey.self] = newValue }
    }
}

func configure(_ app: Application) async throws {
    // MARK: Bancos — dois DatabaseID, dois papéis de banco (scripts/dev-db.sh cria ambos).
    guard let databaseURL = Environment.get("DATABASE_URL") else {
        fatalError("DATABASE_URL não definida — DSN do papel de runtime fridgemagnet_app (ver scripts/dev-db.sh)")
    }
    guard let databaseOwnerURL = Environment.get("DATABASE_OWNER_URL") else {
        fatalError("DATABASE_OWNER_URL não definida — DSN do papel dono fridgemagnet_owner (ver scripts/dev-db.sh)")
    }
    app.databases.use(try .postgres(url: databaseURL), as: .psql)
    app.databases.use(try .postgres(url: databaseOwnerURL), as: .owner)

    // As migrations dos planos de identidade e de tenant rodam no database owner —
    // fridgemagnet_app nunca tem DDL, só o DML explicitamente concedido no fim de cada migration.
    app.migrations.add(CreateIdentitySchema(), to: .owner)
    app.migrations.add(CreateHouseholdSchema(), to: .owner)
    app.migrations.add(CreateRefreshTokens(), to: .owner)
    app.migrations.add(CreateHouseholdInvites(), to: .owner)
    app.migrations.add(CreateDeviceTokens(), to: .owner)
    app.migrations.add(CreateRecadoSchema(), to: .owner)
    app.migrations.add(AddRecadoPinAndArchive(), to: .owner)
    app.migrations.add(AddPhotoCapturedAtAndRecadoLocation(), to: .owner)
    app.migrations.add(AddRecadoEventReminder(), to: .owner)
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
    // Registro `[AuthProvider: any IdentityTokenVerifier]` montado a partir de
    // `ProviderConfig` — só contém entradas para provedores com credenciais presentes no
    // ambiente. `AuthController` resolve o verificador do `provider` do request por aqui,
    // sem ramificar por provedor (plano 01-08).
    let providerConfig = ProviderConfig.fromEnvironment()
    app.providerConfig = providerConfig
    var identityTokenVerifiers: [AuthProvider: any IdentityTokenVerifier] = [:]
    if let appleConfig = providerConfig.apple {
        identityTokenVerifiers[.apple] = AppleTokenVerifier(
            client: app.client,
            jwksURL: appleConfig.jwksURL,
            audience: appleConfig.audience
        )
    }
    if let googleConfig = providerConfig.google {
        identityTokenVerifiers[.google] = GoogleTokenVerifier(
            client: app.client,
            jwksURL: googleConfig.jwksURL,
            audience: googleConfig.audience
        )
    }
    if let microsoftConfig = providerConfig.microsoft {
        identityTokenVerifiers[.microsoft] = MicrosoftTokenVerifier(
            client: app.client,
            discoveryURL: microsoftConfig.jwksURL,
            audience: microsoftConfig.audience
        )
    }
    app.identityTokenVerifiers = identityTokenVerifiers

    // MARK: Push notifications (APNs) — plano 01-11, D-16 opção c ("híbrido: cliente
    // informa, backend corrige") aprovada no checkpoint da Task 1.
    // Fora de `.testing`, a ausência de qualquer uma das quatro variáveis aborta o boot com
    // mensagem explícita — mesma disciplina de `assertRuntimeDatabaseRole` logo abaixo:
    // silêncio aqui significa "sobe e só falha no primeiro envio", o pior modo de falha
    // possível para push (T-11-07).
    if app.environment == .testing {
        app.pushService = PushService(client: NoopPushClient())
    } else {
        let apnsConfig: APNSConfig
        do {
            apnsConfig = try APNSConfig.fromEnvironment()
        } catch let error as APNSConfig.LoadError {
            fatalError("Backend recusando subir: \(error.description)")
        }
        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: apnsConfig.privateKeyPEM) else {
            fatalError("APNS_PRIVATE_KEY_P8 não é uma chave P-256 válida")
        }
        await app.apns.configure(.jwt(
            privateKey: privateKey,
            keyIdentifier: apnsConfig.keyID,
            teamIdentifier: apnsConfig.teamID
        ))
        app.pushService = PushService(client: VaporAPNSPushClient(application: app, topic: apnsConfig.topic))
    }

    // MARK: Armazenamento de objeto (Cloudflare R2) — plano 02-04.
    // Mesma disciplina de `app.pushService` acima: fora de `.testing`, a ausência de
    // qualquer uma das quatro variáveis aborta o boot com mensagem explícita — subir sem
    // armazenamento configurado significa "funciona até a primeira foto", o pior modo de
    // falha possível. Em `.testing`, o getter de `app.objectStorageClient` já devolve
    // `NoopObjectStorageClient()` por padrão; os testes injetam `FakeObjectStorageClient`
    // explicitamente quando precisam exercitar a lógica de fotos.
    if app.environment != .testing {
        let r2Config: R2Config
        do {
            r2Config = try R2Config.fromEnvironment()
        } catch let error as R2Config.LoadError {
            fatalError("Backend recusando subir: \(error.description)")
        }
        let awsClient = AWSClient(
            credentialProvider: .static(
                accessKeyId: r2Config.accessKeyID,
                secretAccessKey: r2Config.secretAccessKey
            )
        )
        app.lifecycle.use(ObjectStorageLifecycleHandler(awsClient: awsClient))
        app.objectStorageClient = SotoS3ObjectStorageClient(config: r2Config, awsClient: awsClient)
    }

    // MARK: Asserção de papel de banco no boot.
    // Fora de `.testing`, servir com `fridgemagnet_owner` desativaria a Row-Level Security que o
    // plano 01-02 instala nas tabelas de tenant — e o sintoma seria silêncio: tudo
    // funcionaria e nada estaria isolado. Abortar o processo é a única resposta segura.
    if app.environment != .testing {
        try await assertRuntimeDatabaseRole(app)
    }

    // MARK: Rotas.
    app.get("health", use: healthCheck)
    try app.register(collection: AuthController())
    try app.register(collection: HouseholdController())
    try app.register(collection: DeviceController())
    try app.register(collection: RecadoController())
    try app.register(collection: RecadoPhotoController())
    // `POST /api/v1/dev/push-test` só existe em desenvolvimento — ausência de rota, não
    // checagem em runtime (T-11-04, ver `DeviceController.registerDevRoutes`).
    if app.environment == .development {
        try DeviceController.registerDevRoutes(app)
    }
}

/// `SELECT current_user` real contra o banco de runtime (`.psql`, papel `fridgemagnet_app`
/// esperado). Aborta o processo se o resultado for `fridgemagnet_owner` — ver comentário acima.
private func assertRuntimeDatabaseRole(_ app: Application) async throws {
    guard let sql = app.db(.psql) as? SQLDatabase else {
        fatalError("Banco de runtime (.psql) não é um SQLDatabase — impossível checar current_user")
    }
    guard let row = try await sql.raw("SELECT current_user").first() else {
        fatalError("SELECT current_user não devolveu nenhuma linha")
    }
    let currentUser = try row.decode(column: "current_user", as: String.self)
    guard currentUser != "fridgemagnet_owner" else {
        fatalError("Backend conectado como fridgemagnet_owner — recusando subir (desativaria a RLS do plano 01-02)")
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

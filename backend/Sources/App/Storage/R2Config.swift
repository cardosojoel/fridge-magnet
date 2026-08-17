import Vapor

/// Configuração do Cloudflare R2, lida do ambiente — nunca hardcoded, nunca versionada.
///
/// Mesmo molde de `APNSConfig` (`backend/Sources/App/Push/APNSConfig.swift`): struct de
/// valores puro + `LoadError` que nomeia exatamente a variável ausente + `fromEnvironment()`
/// testável isoladamente, sem precisar subir a `Application` inteira nem falar com a rede —
/// `RecadoPhotoTests` chama esta função direto para provar que a ausência de qualquer uma das
/// quatro variáveis falha de forma clara (must_have do plano 02-04, mesmo raciocínio do
/// must_have equivalente do plano 01-11 para o APNs).
struct R2Config: Sendable {
    var accountID: String
    var accessKeyID: String
    var secretAccessKey: String
    var bucketName: String

    /// Endpoint S3-compatível do R2, derivado do `accountID` — nunca outra forma de montar
    /// esta URL (ex.: um endpoint customizado vindo de variável de ambiente separada, que
    /// abriria a possibilidade de apontar acidentalmente para um bucket alheio).
    var endpoint: String {
        "https://\(accountID).r2.cloudflarestorage.com"
    }

    enum LoadError: Error, CustomStringConvertible, Equatable {
        case missingEnvironmentVariable(String)

        var description: String {
            switch self {
            case .missingEnvironmentVariable(let name):
                return "\(name) não definida — obrigatória para o armazenamento de fotos em " +
                    "R2 (ver user_setup do plano 02-04)"
            }
        }
    }

    /// Lê as quatro variáveis obrigatórias do ambiente. Lança `LoadError` (nunca devolve um
    /// valor parcial) na primeira que faltar — quem chama decide se isso vira um
    /// `fatalError` de boot (`configure.swift`, fora de `.testing`) ou uma asserção de teste.
    static func fromEnvironment() throws -> R2Config {
        guard let accountID = Environment.get("R2_ACCOUNT_ID") else {
            throw LoadError.missingEnvironmentVariable("R2_ACCOUNT_ID")
        }
        guard let accessKeyID = Environment.get("R2_ACCESS_KEY_ID") else {
            throw LoadError.missingEnvironmentVariable("R2_ACCESS_KEY_ID")
        }
        guard let secretAccessKey = Environment.get("R2_SECRET_ACCESS_KEY") else {
            throw LoadError.missingEnvironmentVariable("R2_SECRET_ACCESS_KEY")
        }
        guard let bucketName = Environment.get("R2_BUCKET_NAME") else {
            throw LoadError.missingEnvironmentVariable("R2_BUCKET_NAME")
        }
        return R2Config(
            accountID: accountID,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            bucketName: bucketName
        )
    }
}

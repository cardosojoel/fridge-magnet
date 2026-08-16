import Vapor

/// Configuração do cliente APNs, lida do ambiente — nunca hardcoded, nunca versionada
/// (T-11-03).
///
/// `fromEnvironment()` é uma função pura, testável isoladamente sem precisar subir a
/// `Application` inteira: `DeviceTokenTests` chama esta função direto para provar que a
/// ausência de qualquer uma das quatro variáveis falha de forma clara (must_have do plano
/// 01-11 — "o backend falha o boot com mensagem clara quando alguma das quatro variáveis do
/// APNs está ausente"), sem depender de um boot real fora de `.testing` nem de credenciais
/// reais da Apple.
struct APNSConfig: Sendable {
    var keyID: String
    var teamID: String
    var privateKeyPEM: String
    var topic: String

    enum LoadError: Error, CustomStringConvertible, Equatable {
        case missingEnvironmentVariable(String)

        var description: String {
            switch self {
            case .missingEnvironmentVariable(let name):
                return "\(name) não definida — obrigatória para o cliente APNs (ver user_setup do plano 01-11)"
            }
        }
    }

    /// Lê as quatro variáveis obrigatórias do ambiente. Lança `LoadError` (nunca devolve um
    /// valor parcial) na primeira que faltar — quem chama decide se isso vira um
    /// `fatalError` de boot (`configure.swift`, fora de `.testing`) ou uma asserção de
    /// teste.
    static func fromEnvironment() throws -> APNSConfig {
        guard let keyID = Environment.get("APNS_KEY_ID") else {
            throw LoadError.missingEnvironmentVariable("APNS_KEY_ID")
        }
        guard let teamID = Environment.get("APNS_TEAM_ID") else {
            throw LoadError.missingEnvironmentVariable("APNS_TEAM_ID")
        }
        guard let privateKeyPEM = Environment.get("APNS_PRIVATE_KEY_P8") else {
            throw LoadError.missingEnvironmentVariable("APNS_PRIVATE_KEY_P8")
        }
        guard let topic = Environment.get("APNS_TOPIC") else {
            throw LoadError.missingEnvironmentVariable("APNS_TOPIC")
        }
        return APNSConfig(keyID: keyID, teamID: teamID, privateKeyPEM: privateKeyPEM, topic: topic)
    }
}

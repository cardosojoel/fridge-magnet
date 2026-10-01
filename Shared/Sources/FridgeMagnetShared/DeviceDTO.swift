import Foundation

/// Plataforma do dispositivo que registrou o token — "ios" | "macos" (o app roda em ambos,
/// `.claude/CLAUDE.md`).
public enum DevicePlatform: String, Codable, Sendable {
    case ios
    case macos
}

/// Ambiente do APNs ao qual um device token pertence — "sandbox" | "production".
///
/// Preenchido pelo cliente no registro (`#if DEBUG` → sandbox, senão produção) e corrigido
/// pelo backend no primeiro `BadDeviceToken` (D-16, opção c aprovada no `checkpoint:decision`
/// da Task 1 do plano 01-11 — "híbrido: cliente informa, backend corrige"). Nunca inferido
/// dos bytes do próprio token (01-RESEARCH.md Pitfall 1: `vapor/apns` exige o ambiente
/// explicitamente, não o infere).
public enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// Corpo de `POST /api/v1/devices`.
///
/// Deliberadamente não carrega `userId` nem `householdId`: ambos são resolvidos no servidor a
/// partir do JWT verificado e do contexto de sessão (IDENT-06) — um campo que não existe no
/// tipo não pode ser lido por engano, mesmo que o corpo JSON bruto do request contenha essas
/// chaves (zero-trust do front-end, `.claude/CLAUDE.md`).
public struct DeviceRegistrationRequest: Codable, Sendable {
    public var apnsToken: String
    public var platform: DevicePlatform
    public var environment: APNSEnvironment

    public init(apnsToken: String, platform: DevicePlatform, environment: APNSEnvironment) {
        self.apnsToken = apnsToken
        self.platform = platform
        self.environment = environment
    }
}

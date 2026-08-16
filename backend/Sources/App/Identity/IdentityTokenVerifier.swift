import Foundation
import JKLarShared
import Vapor

/// Identidade resultante de uma verificação bem-sucedida — só o que sobrevive além do
/// escopo do handler que a produziu. O identity token bruto do provedor nunca chega até
/// aqui (D-12): `VerifiedIdentity` não guarda o token, só o que dele foi extraído.
struct VerifiedIdentity: Sendable {
    var subject: String
    var email: String?
    var emailVerified: Bool
}

/// Erro genérico de token de identidade inválido.
///
/// Nunca carrega o motivo específico (chave errada, `aud` errado, `iss` errado, token
/// expirado, corpo malformado) — `AuthController` traduz qualquer erro deste tipo para o
/// mesmo `APIErrorCode.invalidToken` (plano 01-01, Task 2), para não entregar a um
/// atacante um oráculo sobre o estado do JWKS ou sobre quais tokens já existiram (T-01-10).
struct InvalidIdentityTokenError: Error {}

/// Protocolo comum dos três verificadores de identity token (Apple, Google, Microsoft).
/// `AuthController` seleciona o verificador certo pelo registro de `identityTokenVerifiers`
/// abaixo em vez de ramificar por provedor — o 501 dos provedores sem verificador some
/// porque o registro, uma vez completo, cobre os três (plano 01-08).
protocol IdentityTokenVerifier: Sendable {
    func verify(_ token: String) async throws -> VerifiedIdentity
}

private struct IdentityTokenVerifiersKey: StorageKey {
    typealias Value = [AuthProvider: any IdentityTokenVerifier]
}

extension Application {
    /// Registro por `AuthProvider`, montado em `configure(_:)` a partir de
    /// `ProviderConfig` — só contém entradas para provedores com credenciais configuradas
    /// no ambiente (ex.: sem `GOOGLE_CLIENT_ID`, não existe entrada `.google`). Guardado na
    /// `Application` (não recriado por request) porque cada verificador cacheia seu próprio
    /// JWKS entre requests.
    var identityTokenVerifiers: [AuthProvider: any IdentityTokenVerifier] {
        get { self.storage[IdentityTokenVerifiersKey.self] ?? [:] }
        set { self.storage[IdentityTokenVerifiersKey.self] = newValue }
    }
}

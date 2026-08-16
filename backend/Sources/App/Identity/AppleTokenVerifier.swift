import Foundation
import JWT
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
/// mesmo `APIErrorCode.invalidToken` (Task 2), para não entregar a um atacante um oráculo
/// sobre o estado do JWKS ou sobre quais tokens já existiram (T-01-10).
struct InvalidIdentityTokenError: Error {}

/// Verifica um identity token da Apple contra o JWKS publicado em
/// `https://appleid.apple.com/auth/keys`, cacheado por TTL (a Apple rotaciona chaves
/// periodicamente). O `Client` HTTP e a URL do JWKS são injetáveis — os testes de
/// `AuthControllerTests` apontam para um `Client` falso que serve um JWKS estático em
/// memória, sem nunca tocar a rede real da Apple.
///
/// Reaproveita `AppleIdentityToken` do próprio `vapor/jwt` (que já valida `iss` e `exp` em
/// `verify(using:)`) em vez de redeclarar essas claims — "Don't Hand-Roll" (01-RESEARCH.md).
/// A checagem de `aud` fica aqui porque a audience é lida do `ProviderConfig` desta app,
/// não hardcoded.
actor AppleTokenVerifier {
    private let client: any Client
    private let jwksURL: URI
    private let audience: String
    private let cacheTTL: TimeInterval

    private var cachedKeys: JWTKeyCollection?
    private var cachedAt: Date?

    init(
        client: any Client,
        jwksURL: URI = "https://appleid.apple.com/auth/keys",
        audience: String,
        cacheTTL: TimeInterval = 3600
    ) {
        self.client = client
        self.jwksURL = jwksURL
        self.audience = audience
        self.cacheTTL = cacheTTL
    }

    /// Verifica assinatura (contra o JWKS cacheado) e claims `iss`/`aud`/`exp`. Qualquer
    /// falha vira `InvalidIdentityTokenError`, sem distinguir o motivo.
    func verify(_ token: String) async throws -> VerifiedIdentity {
        do {
            let keys = try await currentKeys()
            let payload = try await keys.verify(token, as: AppleIdentityToken.self)
            try payload.audience.verifyIntendedAudience(includes: audience)

            return VerifiedIdentity(
                subject: payload.subject.value,
                email: payload.email,
                emailVerified: payload.emailVerified?.value ?? false
            )
        } catch {
            throw InvalidIdentityTokenError()
        }
    }

    /// Descarta o cache — usado pelos testes para trocar o JWKS servido entre casos.
    func invalidateCache() {
        cachedKeys = nil
        cachedAt = nil
    }

    private func currentKeys() async throws -> JWTKeyCollection {
        if let cachedKeys, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cachedKeys
        }
        let response = try await client.get(jwksURL)
        guard response.status == .ok, let body = response.body else {
            throw InvalidIdentityTokenError()
        }
        let jwksJSON = String(buffer: body)
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: jwksJSON)
        cachedKeys = keys
        cachedAt = Date()
        return keys
    }
}

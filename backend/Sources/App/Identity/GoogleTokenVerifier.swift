import Foundation
import JWT
import Vapor

/// Verifica um id_token do Google contra o JWKS publicado em
/// `https://www.googleapis.com/oauth2/v3/certs`, cacheado por TTL. `Client` HTTP e URL do
/// JWKS injetáveis — mesma forma de `AppleTokenVerifier`, para os testes de
/// `ProviderVerifierTests` nunca tocarem a rede real do Google.
///
/// Reaproveita `GoogleIdentityToken` do próprio `jwt-kit` (que já valida `iss` — nas duas
/// formas que o Google emite, `https://accounts.google.com` e `accounts.google.com` — e
/// `exp` em `verify(using:)`) em vez de redeclarar essas claims — "Don't Hand-Roll"
/// (01-RESEARCH.md), mesmo padrão de `AppleTokenVerifier` reaproveitando
/// `AppleIdentityToken`. A checagem de `aud` fica aqui porque a audience é lida do
/// `ProviderConfig` desta app, não hardcoded.
actor GoogleTokenVerifier {
    private let client: any Client
    private let jwksURL: URI
    private let audience: String
    private let cacheTTL: TimeInterval

    private var cachedKeys: JWTKeyCollection?
    private var cachedAt: Date?

    init(
        client: any Client,
        jwksURL: URI = "https://www.googleapis.com/oauth2/v3/certs",
        audience: String,
        cacheTTL: TimeInterval = 3600
    ) {
        self.client = client
        self.jwksURL = jwksURL
        self.audience = audience
        self.cacheTTL = cacheTTL
    }

    /// `email_verified` ausente é tratado como falso (T-08-06) — nunca verdadeiro por
    /// omissão; é essa omissão que alimentaria a unificação indevida de conta da Task 2.
    func verify(_ token: String) async throws -> VerifiedIdentity {
        do {
            let keys = try await currentKeys()
            let payload = try await keys.verify(token, as: GoogleIdentityToken.self)
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

extension GoogleTokenVerifier: IdentityTokenVerifier {}

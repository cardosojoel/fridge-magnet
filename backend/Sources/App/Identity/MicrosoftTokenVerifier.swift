import Foundation
import JWT
import Vapor

/// Payload decodificado de um id_token da Microsoft. `verify(using:)` só confere `exp` —
/// `aud` e `iss` são validados fora, em `MicrosoftTokenVerifier.verify(_:)`, porque a
/// audience vem do `ProviderConfig` e o `iss` esperado depende do `tid` do próprio token
/// combinado com o template `issuer` lido do documento de descoberta (nenhum dos dois é
/// conhecido dentro deste tipo).
struct MicrosoftIdentityToken: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case issuer = "iss"
        case audience = "aud"
        case expiration = "exp"
        case tenantID = "tid"
        case email
        case preferredUsername = "preferred_username"
        case emailVerified = "email_verified"
    }

    var subject: SubjectClaim
    var issuer: IssuerClaim
    var audience: AudienceClaim
    var expiration: ExpirationClaim
    /// GUID do tenant que emitiu o token — sempre presente, inclusive para contas pessoais
    /// (que usam um GUID fixo de "tenant consumidor"). É contra ele que o template `issuer`
    /// do documento de descoberta é substituído para produzir o `iss` esperado.
    var tenantID: String
    var email: String?
    /// Contas pessoais frequentemente não trazem `email` — o e-mail chega em
    /// `preferred_username` nesse caso.
    var preferredUsername: String?
    var emailVerified: Bool?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }
}

/// Documento de descoberta OIDC da autoridade `common` — buscado em tempo de execução,
/// nunca uma URL de JWKS fixa (T-08-04, gate do plano 01-08 Task 1 proíbe a URL adivinhada
/// que a pesquisa marcou como não confirmada). `issuer` chega como um template contendo o
/// marcador `{tenantid}`; substituí-lo pelo `tid` do próprio token é o que impede um token
/// de outro tenant passar (T-08-03) sem rejeitar contas pessoais legítimas.
private struct MicrosoftDiscoveryDocument: Decodable {
    var jwksURI: String
    var issuer: String

    enum CodingKeys: String, CodingKey {
        case jwksURI = "jwks_uri"
        case issuer
    }
}

/// Verifica um id_token da Microsoft contra o JWKS da autoridade `common`, descoberto em
/// tempo de execução a partir de
/// `https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration`
/// (cacheado por TTL junto com o JWKS). `Client` HTTP e a URL de descoberta são injetáveis —
/// os testes de `ProviderVerifierTests` nunca tocam a rede real da Microsoft.
actor MicrosoftTokenVerifier {
    private let client: any Client
    private let discoveryURL: URI
    private let audience: String
    private let cacheTTL: TimeInterval

    private var cachedKeys: JWTKeyCollection?
    private var cachedIssuerTemplate: String?
    private var cachedAt: Date?

    init(
        client: any Client,
        discoveryURL: URI = "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration",
        audience: String,
        cacheTTL: TimeInterval = 3600
    ) {
        self.client = client
        self.discoveryURL = discoveryURL
        self.audience = audience
        self.cacheTTL = cacheTTL
    }

    /// Verifica assinatura (contra o JWKS descoberto e cacheado), `aud` contra o
    /// `ProviderConfig` desta app, e `iss` contra o template `issuer` do documento de
    /// descoberta com o `tid` do próprio token substituído — aceitar cegamente qualquer
    /// `iss` sob `login.microsoftonline.com` permitiria um token de outro tenant passar;
    /// fixar um `iss` literal rejeitaria contas pessoais legítimas (T-08-03). `email` pode
    /// chegar em `preferred_username` em contas pessoais — lidos nessa ordem de preferência.
    /// `email_verified` ausente é tratado como falso (T-08-06), mesma regra da Apple/Google.
    func verify(_ token: String) async throws -> VerifiedIdentity {
        do {
            let (keys, issuerTemplate) = try await currentKeysAndIssuerTemplate()
            let payload = try await keys.verify(token, as: MicrosoftIdentityToken.self)
            try payload.audience.verifyIntendedAudience(includes: audience)

            let expectedIssuer = issuerTemplate.replacingOccurrences(of: "{tenantid}", with: payload.tenantID)
            guard payload.issuer.value == expectedIssuer else {
                throw InvalidIdentityTokenError()
            }

            return VerifiedIdentity(
                subject: payload.subject.value,
                email: payload.email ?? payload.preferredUsername,
                emailVerified: payload.emailVerified ?? false
            )
        } catch {
            throw InvalidIdentityTokenError()
        }
    }

    /// Descarta o cache — usado pelos testes para trocar o documento de descoberta/JWKS
    /// servido entre casos.
    func invalidateCache() {
        cachedKeys = nil
        cachedIssuerTemplate = nil
        cachedAt = nil
    }

    private func currentKeysAndIssuerTemplate() async throws -> (JWTKeyCollection, String) {
        if let cachedKeys, let cachedIssuerTemplate, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return (cachedKeys, cachedIssuerTemplate)
        }

        let discoveryResponse = try await client.get(discoveryURL)
        guard discoveryResponse.status == .ok, let discoveryBody = discoveryResponse.body else {
            throw InvalidIdentityTokenError()
        }
        let discovery = try JSONDecoder().decode(MicrosoftDiscoveryDocument.self, from: Data(buffer: discoveryBody))

        let jwksResponse = try await client.get(URI(string: discovery.jwksURI))
        guard jwksResponse.status == .ok, let jwksBody = jwksResponse.body else {
            throw InvalidIdentityTokenError()
        }
        let jwksJSON = String(buffer: jwksBody)
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: jwksJSON)

        cachedKeys = keys
        cachedIssuerTemplate = discovery.issuer
        cachedAt = Date()
        return (keys, discovery.issuer)
    }
}

extension MicrosoftTokenVerifier: IdentityTokenVerifier {}

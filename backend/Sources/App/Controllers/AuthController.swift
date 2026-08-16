import Fluent
import Foundation
import JKLarShared
import JWT
import Vapor

/// `POST /api/v1/auth/session` — verifica um identity token de provedor, resolve a
/// identidade interna e emite um JWT próprio do JK Lar.
///
/// Só `.apple` tem verificador implementado nesta fatia; `.google` e `.microsoft`
/// respondem 501 até o plano 01-08 (D-01: a ordem de botões no cliente já prevê os três).
/// O identity token do provedor (`body.identityToken`) é usado e descartado no escopo
/// deste handler: nunca persistido, nunca logado, nunca devolvido (D-12) — é por isso que
/// `identityToken` não aparece em nenhum outro arquivo de `backend/Sources/App`.
struct AuthController: RouteCollection {
    /// Duração do access token — 900s (15 min), D-09.
    static let accessTokenLifetime: TimeInterval = 900

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("session", use: session)
    }

    @Sendable
    func session(req: Request) async throws -> Response {
        let body = try req.content.decode(SessionRequest.self)

        let verified: VerifiedIdentity
        switch body.provider {
        case .apple:
            guard let verifier = req.application.appleTokenVerifier else {
                req.logger.error("APPLE_AUDIENCE não configurada — login com Apple indisponível")
                throw Abort(.internalServerError)
            }
            do {
                verified = try await verifier.verify(body.identityToken)
            } catch {
                return try Self.errorResponse(
                    code: .invalidToken,
                    message: "Token de identidade inválido.",
                    status: .unauthorized
                )
            }
        case .google, .microsoft:
            return try Self.errorResponse(
                code: .validation,
                message: "Provedor ainda não suportado.",
                status: .notImplemented
            )
        }

        let resolver = IdentityResolver(database: req.db)
        let user = try await resolver.resolve(
            provider: body.provider,
            subject: verified.subject,
            email: verified.email,
            emailVerified: verified.emailVerified
        )

        // Preenche displayName/gender só quando vierem no request E o perfil ainda
        // estiver nulo — nunca sobrescreve um perfil já preenchido num login recorrente.
        var didChangeProfile = false
        if user.displayName == nil, let displayName = body.displayName {
            user.displayName = displayName
            didChangeProfile = true
        }
        if user.gender == nil, let gender = body.gender {
            user.gender = gender.rawValue
            didChangeProfile = true
        }
        if didChangeProfile {
            try await user.save(on: req.db)
        }

        let userID = try user.requireID()
        let accessPayload = AccessTokenPayload(
            subject: SubjectClaim(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(Self.accessTokenLifetime))
        )
        let accessToken = try await req.jwt.sign(accessPayload)

        // Refresh token desta fatia: string opaca de 32 bytes aleatórios, devolvida ao
        // cliente. Persistência com hash, rotação e revogação chegam no plano 01-04 — o
        // campo do contrato existe desde agora (01-RESEARCH.md Pattern 3).
        let refreshToken = [UInt8].random(count: 32).base64URLEncodedString()

        let userDTO = UserDTO(
            id: userID,
            displayName: user.displayName,
            email: verified.email,
            gender: user.gender.flatMap(Gender.init(rawValue:))
        )
        let response = SessionResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: Int(Self.accessTokenLifetime),
            user: userDTO,
            household: nil
        )
        return try Self.jsonResponse(response, status: .ok)
    }

    private static func errorResponse(
        code: APIErrorCode,
        message: String,
        status: HTTPStatus
    ) throws -> Response {
        try Self.jsonResponse(APIErrorResponse(code: code, message: message), status: status)
    }

    private static func jsonResponse(_ body: some Encodable, status: HTTPStatus) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(body, as: .json)
        return response
    }
}

/// Payload do access token próprio do JK Lar — ES256, 15 min (D-09). `sub` é `users.id`,
/// nunca o `sub` do provedor externo.
struct AccessTokenPayload: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.expiration.verifyNotExpired()
    }
}

extension [UInt8] {
    /// Base64url sem padding (RFC 4648 §5) — usado só para o refresh token opaco desta
    /// fatia (a persistência com hash chega no plano 01-04).
    func base64URLEncodedString() -> String {
        Data(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Fluent
import Foundation
import JKLarShared
import JWT
import Vapor

/// `POST /api/v1/auth/session` — verifica um identity token de provedor, resolve a
/// identidade interna e emite um JWT próprio do JK Lar.
///
/// Os três provedores (Apple, Google, Microsoft — D-01) passam pelo mesmo caminho desde o
/// plano 01-08: `AuthController` seleciona o verificador pelo registro
/// `Application.identityTokenVerifiers`, montado em `configure.swift` a partir de
/// `ProviderConfig`, sem ramificar por provedor. O identity token do provedor
/// (`body.identityToken`) é usado e descartado no escopo deste handler: nunca persistido,
/// nunca logado, nunca devolvido (D-12) — é por isso que `identityToken` não aparece em
/// nenhum outro arquivo de `backend/Sources/App`.
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("api", "v1", "auth")
        auth.post("session", use: session)
        // `/refresh` e `/logout` ficam deliberadamente fora do `SessionAuthenticator`: o
        // cliente chama `/refresh` justamente quando o access token já expirou, então
        // exigir Bearer válido ali criaria um impasse (plano 01-04). O refresh token
        // apresentado no corpo é a única credencial dessas duas rotas.
        auth.post("refresh", use: refresh)
        auth.post("logout", use: logout)

        // PATCH /profile roda atrás de SessionAuthenticator: D-04 coleta gênero no
        // formulário de criar casa (plano 01-07), depois da sessão já existir — uma rota
        // própria evita reabrir `/auth/session` só para atualizar um campo de perfil.
        let authenticated = auth.grouped(SessionAuthenticator(), User.guardMiddleware())
        authenticated.patch("profile", use: updateProfile)
    }

    @Sendable
    func session(req: Request) async throws -> Response {
        let body = try req.content.decode(SessionRequest.self)

        guard let verifier = req.application.identityTokenVerifiers[body.provider] else {
            req.logger.error("Nenhuma credencial configurada para o provedor \(body.provider.rawValue) — verifique o ambiente")
            throw Abort(.internalServerError)
        }

        let verified: VerifiedIdentity
        do {
            verified = try await verifier.verify(body.identityToken)
        } catch {
            return try Self.errorResponse(
                code: .invalidToken,
                message: "Token de identidade inválido.",
                status: .unauthorized
            )
        }

        let resolver = IdentityResolver(database: req.db, logger: req.logger)
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

        // Plano 01-04: SessionService é o único lugar que emite, rotaciona ou revoga
        // sessão — o login não monta mais o access/refresh token inline.
        let sessionService = SessionService(app: req.application)
        let response = try await sessionService.issueSession(
            for: user,
            email: verified.email,
            on: req.db
        )
        return try Self.jsonResponse(response, status: .ok)
    }

    /// `POST /api/v1/auth/refresh` — rotaciona um refresh token válido. `SessionService`
    /// nunca diferencia token inexistente, expirado ou já revogado na resposta HTTP
    /// (T-04-04): todos colapsam no mesmo 401 `.unauthorized`.
    @Sendable
    func refresh(req: Request) async throws -> Response {
        let body = try req.content.decode(RefreshRequest.self)
        let sessionService = SessionService(app: req.application)
        do {
            let response = try await sessionService.rotate(presentedToken: body.refreshToken, on: req.db)
            return try Self.jsonResponse(response, status: .ok)
        } catch is SessionService.SessionError {
            return try Self.errorResponse(
                code: .unauthorized,
                message: "Sessão inválida ou expirada.",
                status: .unauthorized
            )
        }
    }

    /// `POST /api/v1/auth/logout` — revoga o refresh token no servidor (D-11). Sempre 204,
    /// exista o token ou não (idempotente, sem oráculo de existência).
    @Sendable
    func logout(req: Request) async throws -> Response {
        let body = try req.content.decode(LogoutRequest.self)
        let sessionService = SessionService(app: req.application)
        try await sessionService.revoke(presentedToken: body.refreshToken, on: req.db)
        return Response(status: .noContent)
    }

    /// `PATCH /api/v1/auth/profile` — só gênero é atualizável aqui (D-04). Sobrescreve
    /// deliberadamente qualquer valor já salvo: diferente do preenchimento silencioso em
    /// `session(req:)` (que só entra se `user.gender == nil`), esta rota é uma escolha
    /// explícita do usuário no formulário de criar casa, então a intenção mais recente
    /// vence.
    @Sendable
    func updateProfile(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(UpdateProfileRequest.self)
        user.gender = body.gender.rawValue
        try await user.save(on: req.db)
        return Response(status: .noContent)
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

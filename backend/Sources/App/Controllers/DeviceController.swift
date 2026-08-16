import Fluent
import FluentSQL
import Foundation
import JKLarShared
import Vapor

/// `POST /api/v1/devices` — registro de device token de push (IDENT-05, IDENT-06).
///
/// A rota de push de teste (`POST /api/v1/dev/push-test`) **não** é registrada por
/// `boot(routes:)`: ela só existe quando `configure.swift` chama `registerDevRoutes(_:)`, e
/// só fora de `.testing`/produção — ausência de rota, não checagem em runtime (T-11-04).
struct DeviceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let devices = routes.grouped("api", "v1", "devices")
        let authenticated = devices.grouped(SessionAuthenticator(), User.guardMiddleware())
        let scoped = authenticated.grouped(HouseholdContextMiddleware())
        scoped.post(use: register)
    }

    // MARK: POST /api/v1/devices

    @Sendable
    func register(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let body = try req.content.decode(DeviceRegistrationRequest.self)
        let trimmedToken = body.apnsToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return try Self.errorResponse(code: .validation, message: "apnsToken inválido.", status: .badRequest)
        }

        // A cláusula extra da policy de `device_tokens` (`user_id = app.current_user_id`,
        // ver `CreateDeviceTokens`) é o que faz esta busca enxergar a própria linha do
        // dispositivo mesmo quando ela ainda pertence à casa anterior — sem essa cláusula,
        // "o mesmo dispositivo trocando de casa" bateria no índice único de `apns_token` em
        // vez de mover a linha.
        if let existing = try await DeviceToken.query(on: req.scopedDB)
            .filter(\.$apnsToken == trimmedToken)
            .first()
        {
            // user_id/household_id vêm sempre do JWT/contexto do servidor, nunca do corpo
            // do request — `DeviceRegistrationRequest` nem carrega esses campos (IDENT-06).
            existing.$user.id = userID
            existing.$household.id = context.householdID
            existing.platform = body.platform.rawValue
            existing.environment = body.environment.rawValue
            try await existing.save(on: req.scopedDB)
            return Response(status: .ok)
        }

        let deviceToken = DeviceToken(
            userID: userID,
            householdID: context.householdID,
            apnsToken: trimmedToken,
            platform: body.platform.rawValue,
            environment: body.environment.rawValue
        )
        do {
            try await deviceToken.save(on: req.scopedDB)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Colisão em `apns_token` de uma linha que a policy desta sessão não enxerga
            // (ex.: o mesmo aparelho físico reatribuído a um usuário totalmente diferente,
            // em outra casa, sem nenhum vínculo prévio) — fora do escopo dos casos deste
            // plano; falha de forma explícita em vez de um 500 opaco.
            return try Self.errorResponse(
                code: .validation,
                message: "Este dispositivo já está registrado.",
                status: .conflict
            )
        }
        return Response(status: .created)
    }

    // MARK: POST /api/v1/dev/push-test (só development, ver `registerDevRoutes`)

    /// Registrada só por `configure.swift`, e só quando `app.environment == .development` —
    /// ausência de rota, não checagem em runtime (T-11-04). `DeviceTokenTests` chama esta
    /// função diretamente sobre uma `Application` de teste (`.testing`) para exercitar o
    /// comportamento admin-only da rota sem precisar de credenciais reais de APNs; o próprio
    /// gate de ambiente (chamar isto só em `.development`) é verificado por inspeção de
    /// código em `configure.swift`, não repetido aqui via boot real em `.production`.
    static func registerDevRoutes(_ app: Application) throws {
        let devRoutes = app.routes.grouped("api", "v1", "dev")
        let authenticated = devRoutes.grouped(SessionAuthenticator(), User.guardMiddleware())
        let scoped = authenticated.grouped(HouseholdContextMiddleware())
        let adminScoped = scoped.grouped(RequireRoleMiddleware([.admin]))
        adminScoped.post("push-test", use: pushTest)
    }

    @Sendable
    static func pushTest(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let tokens = try await DeviceToken.query(on: req.scopedDB)
            .filter(\.$user.$id == userID)
            .filter(\.$household.$id == context.householdID)
            .all()

        for token in tokens {
            try await req.application.pushService.send(
                to: token,
                title: "JK Lar",
                body: "Notificação de teste.",
                on: req.scopedDB
            )
        }

        return Response(status: .ok)
    }

    private static func errorResponse(code: APIErrorCode, message: String, status: HTTPStatus) throws -> Response {
        try Self.jsonResponse(APIErrorResponse(code: code, message: message), status: status)
    }

    private static func jsonResponse(_ body: some Encodable, status: HTTPStatus) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(body, as: .json)
        return response
    }
}

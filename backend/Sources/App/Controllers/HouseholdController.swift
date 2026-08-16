import Fluent
import Foundation
import JKLarShared
import Vapor

/// `POST /api/v1/households` e `GET /api/v1/households/current` — o plano de tenant.
///
/// `POST` **não** roda atrás de `HouseholdContextMiddleware`: ele existe exatamente para o
/// caso em que o usuário ainda não tem casa (o próprio ponto da rota), então gerencia sua
/// própria transação/contexto RLS em vez de depender de um contexto que, por definição,
/// ainda não existe. `GET /current` é uma rota escopada de verdade e roda atrás de
/// `HouseholdContextMiddleware`.
struct HouseholdController: RouteCollection {
    /// Hard cap do nome da casa — 01-UI-SPEC.md, vale independentemente do que o cliente
    /// permita digitar.
    static let maxHouseholdNameLength = 40

    func boot(routes: any RoutesBuilder) throws {
        let households = routes.grouped("api", "v1", "households")
        let authenticated = households.grouped(SessionAuthenticator(), User.guardMiddleware())

        authenticated.post(use: create)

        let scoped = authenticated.grouped(HouseholdContextMiddleware())
        scoped.get("current", use: current)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let body = try req.content.decode(CreateHouseholdRequest.self)
        let trimmedName = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= Self.maxHouseholdNameLength else {
            return try Self.errorResponse(
                code: .validation,
                message: "O nome da casa deve ter entre 1 e \(Self.maxHouseholdNameLength) caracteres.",
                status: .badRequest
            )
        }

        return try await req.db.transaction { transactionDB in
            // Bootstrap: sem isso, a policy de household_members não encontraria a própria
            // linha do usuário para o 409 abaixo — ver comentário em CreateHouseholdSchema.
            try await HouseholdContextMiddleware.applyCurrentUserContext(userID: userID, on: transactionDB)

            let existingMembership = try await HouseholdMember.query(on: transactionDB)
                .filter(\.$user.$id == userID)
                .first()
            guard existingMembership == nil else {
                return try Self.errorResponse(
                    code: .alreadyMember,
                    message: "Você já pertence a uma casa.",
                    status: .conflict
                )
            }

            // Gerado no servidor, aplicado como contexto ANTES do insert — é o que satisfaz
            // a policy `household_isolation` (`id = app.current_household_id`) para a
            // própria linha que estamos criando.
            let householdID = UUID()
            try await HouseholdContextMiddleware.applyCurrentHouseholdContext(
                householdID: householdID,
                on: transactionDB
            )

            let household = Household(id: householdID, name: trimmedName)
            try await household.save(on: transactionDB)

            // Papel do criador: sempre .admin, decidido aqui — nunca lido de
            // CreateHouseholdRequest, que nem carrega esse campo (T-02-03).
            let member = HouseholdMember(
                householdID: householdID,
                userID: userID,
                role: MemberRole.admin.rawValue
            )
            try await member.save(on: transactionDB)

            let dto = HouseholdDTO(id: householdID, name: trimmedName, memberCount: 1, myRole: .admin)
            return try Self.jsonResponse(dto, status: .created)
        }
    }

    @Sendable
    func current(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            // HouseholdContextMiddleware já responde 403 quando não há contexto — este
            // guard é só defesa contra o caso impossível de a rota rodar sem o middleware.
            throw Abort(.forbidden)
        }

        guard let household = try await Household.find(context.householdID, on: req.scopedDB) else {
            throw Abort(.internalServerError)
        }

        let memberCount = try await HouseholdMember.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
            .count()

        let dto = HouseholdDTO(
            id: context.householdID,
            name: household.name,
            memberCount: memberCount,
            myRole: context.role
        )
        return try Self.jsonResponse(dto, status: .ok)
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

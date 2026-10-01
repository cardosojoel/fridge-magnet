import FridgeMagnetShared
import Vapor

/// Autorização por papel (IDENT-06), resolvida sempre do banco — nunca de cabeçalho, query
/// string, corpo do request ou claim customizada do JWT. Roda **depois** de
/// `HouseholdContextMiddleware`: o papel já está em `req.householdContext?.role`, lido da
/// linha real de `household_members` do usuário autenticado dentro da mesma transação. Um
/// JWT emitido antes de um rebaixamento não pode continuar valendo como admin até expirar —
/// o papel é sempre relido a cada request, nunca cacheado no token.
///
/// Registrada por `HouseholdController` nas rotas admin-only (criar/listar convite, trocar
/// papel de membro): `RequireRoleMiddleware([.admin])`.
struct RequireRoleMiddleware: AsyncMiddleware {
    let allowedRoles: Set<MemberRole>

    init(_ allowedRoles: [MemberRole]) {
        self.allowedRoles = Set(allowedRoles)
    }

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let context = req.householdContext else {
            // Sempre roda atrás de HouseholdContextMiddleware, que já responde 403 sem
            // contexto — este guard é só defesa contra o caso impossível de rodar sem ele.
            throw Abort(.forbidden)
        }

        guard allowedRoles.contains(context.role) else {
            let response = Response(status: .forbidden)
            try response.content.encode(
                APIErrorResponse(code: .forbidden, message: "Você não tem permissão para esta ação."),
                as: .json
            )
            return response
        }

        return try await next.respond(to: req)
    }
}

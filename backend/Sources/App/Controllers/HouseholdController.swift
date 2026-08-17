import Fluent
import FluentSQL
import Foundation
import JKLarShared
import Vapor

/// `POST /api/v1/households`, `GET /api/v1/households/current` (plano 01-02) e as rotas de
/// convite/papel do plano 01-06.
///
/// `POST /households` e `POST /households/join` **não** rodam atrás de
/// `HouseholdContextMiddleware`: ambas existem exatamente para o momento em que o usuário
/// ainda não tem casa (ou está prestes a ganhar uma), então gerenciam sua própria
/// transação/contexto RLS em vez de depender de um contexto que, por definição, ainda não
/// existe. Toda outra rota deste controller já pressupõe uma casa e roda atrás de
/// `HouseholdContextMiddleware`; as quatro rotas admin-only (criar/listar convite, trocar
/// papel de membro) rodam também atrás de `RequireRoleMiddleware([.admin])`.
struct HouseholdController: RouteCollection {
    /// Hard cap do nome da casa — 01-UI-SPEC.md, vale independentemente do que o cliente
    /// permita digitar.
    static let maxHouseholdNameLength = 40

    /// Limite de membros por casa (D-08, IDENT-04).
    static let maxHouseholdMembers = 10

    /// Validade de um convite recém-criado (D-06).
    static let inviteLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Tentativas de gerar um código único antes de desistir — uma colisão real com um
    /// alfabeto de 31^6 possibilidades é astronomicamente improvável; o limite existe só
    /// para nunca travar o request num laço infinito se algo estiver errado.
    static let maxInviteCodeAttempts = 5

    func boot(routes: any RoutesBuilder) throws {
        let households = routes.grouped("api", "v1", "households")
        let authenticated = households.grouped(SessionAuthenticator(), User.guardMiddleware())

        authenticated.post(use: create)
        authenticated.post("join", use: join)

        let scoped = authenticated.grouped(HouseholdContextMiddleware())
        scoped.get("current", use: current)
        scoped.get("current", "members", use: members)
        // Auto-serviço (plano 01-10): qualquer papel pode sair, sem `RequireRoleMiddleware`.
        // Caminho deliberadamente separado da rota admin-only abaixo — nunca um ramo
        // "a menos que seja você mesmo" dentro dela (T-10-04/T-10-06).
        scoped.delete("current", "membership", use: leaveHousehold)

        let adminScoped = scoped.grouped(RequireRoleMiddleware([.admin]))
        adminScoped.post("current", "invites", use: createInvite)
        adminScoped.get("current", "invites", use: listInvites)
        adminScoped.patch("current", "members", ":memberID", "role", use: updateMemberRole)
        adminScoped.delete("current", "members", ":memberID", use: removeMember)
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

    // MARK: POST /api/v1/households/current/invites

    @Sendable
    func createInvite(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let expiresAt = Date().addingTimeInterval(Self.inviteLifetime)

        for attempt in 1...Self.maxInviteCodeAttempts {
            let code = InviteCodeGenerator.generate()
            let invite = HouseholdInvite(
                householdID: context.householdID,
                code: code,
                createdByUserID: userID,
                expiresAt: expiresAt
            )
            do {
                try await invite.save(on: req.scopedDB)
                let dto = InviteDTO(code: code, url: "jklar://join/\(code)", expiresAt: expiresAt)
                return try Self.jsonResponse(dto, status: .created)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                // Colisão de código (índice único em `code`) — nunca sobrescreve a linha
                // existente; gera de novo (T-06-01).
                req.logger.warning("Colisão de código de convite na tentativa \(attempt) de \(Self.maxInviteCodeAttempts)")
                continue
            }
        }
        req.logger.error("InviteCodeGenerator não produziu um código único após \(Self.maxInviteCodeAttempts) tentativas")
        throw Abort(.internalServerError)
    }

    // MARK: GET /api/v1/households/current/invites

    @Sendable
    func listInvites(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }

        let invites = try await HouseholdInvite.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
            .filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()

        let dtos = invites.map { invite in
            InviteDTO(code: invite.code, url: "jklar://join/\(invite.code)", expiresAt: invite.expiresAt)
        }
        return try Self.jsonResponse(dtos, status: .ok)
    }

    // MARK: POST /api/v1/households/join

    @Sendable
    func join(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let body = try req.content.decode(JoinHouseholdRequest.self)
        let normalizedCode = body.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedCode.isEmpty else {
            return try Self.errorResponse(code: .inviteInvalid, message: "Código de convite inválido.", status: .notFound)
        }

        return try await req.db.transaction { transactionDB in
            guard let sql = transactionDB as? SQLDatabase else {
                fatalError("HouseholdController.join exige um SQLDatabase (FluentSQL escape hatch)")
            }

            // Bootstrap: sem isso, a policy de household_members não encontraria a própria
            // linha do usuário para o caso "já é membro" abaixo — mesmo raciocínio do 409 de
            // `create`.
            try await HouseholdContextMiddleware.applyCurrentUserContext(userID: userID, on: transactionDB)

            // `resolve_invite` roda como o dono da tabela (SECURITY DEFINER) — funciona
            // mesmo sem nenhum contexto de casa aplicado ainda. Devolve `nil` tanto para
            // código inexistente quanto expirado/revogado.
            guard let householdID = try await Self.resolveInviteHouseholdID(code: normalizedCode, on: sql) else {
                // Segundo caminho, igualmente confinado (`invite_exists`), só para decidir
                // entre "nunca existiu" e "existiu mas venceu/foi revogado" — sem conceder
                // um SELECT direto na tabela (T-06-06).
                let codeExisted = try await Self.inviteCodeExists(code: normalizedCode, on: sql)
                if codeExisted {
                    return try Self.errorResponse(
                        code: .inviteExpired,
                        message: "Este convite expirou.",
                        status: .gone
                    )
                }
                return try Self.errorResponse(
                    code: .inviteInvalid,
                    message: "Código de convite inválido.",
                    status: .notFound
                )
            }

            try await HouseholdContextMiddleware.applyCurrentHouseholdContext(
                householdID: householdID,
                on: transactionDB
            )

            guard let household = try await Household.find(householdID, on: transactionDB) else {
                throw Abort(.internalServerError)
            }

            // Já é membro? 200 idempotente, nunca uma segunda linha (unique(household_id,
            // user_id) do schema também garante isso a nível de banco).
            if let existing = try await HouseholdMember.query(on: transactionDB)
                .filter(\.$household.$id == householdID)
                .filter(\.$user.$id == userID)
                .first()
            {
                let memberCount = try await HouseholdMember.query(on: transactionDB)
                    .filter(\.$household.$id == householdID)
                    .count()
                let dto = HouseholdDTO(
                    id: householdID,
                    name: household.name,
                    memberCount: memberCount,
                    myRole: MemberRole(rawValue: existing.role) ?? .adulto
                )
                return try Self.jsonResponse(dto, status: .ok)
            }

            // Trava a linha da casa — é este lock que fecha a corrida do cap de 10 (T-06-02,
            // 01-RESEARCH.md Pitfall 3). Contagem e INSERT acontecem dentro da mesma
            // transação que segura este lock.
            guard try await Self.lockHouseholdRow(householdID: householdID, on: sql) != nil else {
                throw Abort(.internalServerError)
            }

            let memberCount = try await HouseholdMember.query(on: transactionDB)
                .filter(\.$household.$id == householdID)
                .count()
            guard memberCount < Self.maxHouseholdMembers else {
                return try Self.errorResponse(
                    code: .householdFull,
                    message: "Esta casa já atingiu o limite de \(Self.maxHouseholdMembers) membros.",
                    status: .conflict
                )
            }

            // Papel de quem entra por convite: sempre .adulto, decidido aqui — nunca lido de
            // JoinHouseholdRequest, que nem carrega esse campo (D-07).
            let member = HouseholdMember(
                householdID: householdID,
                userID: userID,
                role: MemberRole.adulto.rawValue
            )
            try await member.save(on: transactionDB)

            let dto = HouseholdDTO(
                id: householdID,
                name: household.name,
                memberCount: memberCount + 1,
                myRole: .adulto
            )
            return try Self.jsonResponse(dto, status: .ok)
        }
    }

    // MARK: GET /api/v1/households/current/members

    @Sendable
    func members(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let memberships = try await HouseholdMember.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
            .with(\.$user)
            .sort(\.$createdAt, .ascending)
            .all()

        let dtos = try memberships.map { membership -> MemberDTO in
            MemberDTO(
                id: try membership.requireID(),
                // Plano 02-06: distinto de `id` acima (linha de `household_members`) — este é
                // o `user.id` real que o seletor de menção estruturado precisa enviar em
                // `mentionedUserIDs` (D-06).
                userID: membership.$user.id,
                displayName: membership.user.displayName,
                role: MemberRole(rawValue: membership.role) ?? .adulto,
                joinedAt: membership.createdAt ?? Date(),
                // Computado no servidor, nunca inferido no cliente (plano 01-10) —
                // `HouseholdViewModel.canRemove(_:)` usa isto para esconder a ação de
                // remover na própria linha.
                isSelf: membership.$user.id == userID
            )
        }
        return try Self.jsonResponse(dtos, status: .ok)
    }

    // MARK: PATCH /api/v1/households/current/members/:memberID/role

    @Sendable
    func updateMemberRole(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()
        guard
            let memberIDRaw = req.parameters.get("memberID"),
            let memberID = UUID(uuidString: memberIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "memberID inválido.", status: .badRequest)
        }
        guard let sql = req.scopedDB as? SQLDatabase else {
            fatalError("HouseholdController.updateMemberRole exige um SQLDatabase (FluentSQL escape hatch)")
        }

        let body = try req.content.decode(UpdateMemberRoleRequest.self)

        // Sob RLS, um memberID de outra casa simplesmente não existe nesta consulta — 404,
        // nunca 403 (a rota já provou "você não é admin desta casa" antes de chegar aqui; um
        // memberID estrangeiro não é um problema de permissão, é um recurso que não existe
        // do ponto de vista deste requisitante).
        guard let member = try await HouseholdMember.query(on: req.scopedDB)
            .filter(\.$id == memberID)
            .filter(\.$household.$id == context.householdID)
            .with(\.$user)
            .first()
        else {
            throw Abort(.notFound)
        }

        // Trava a linha da casa — mesmo lock/mecanismo usado pelo cap de 10 membros em
        // `join` — para a checagem de invariante de último admin ficar serializada com
        // qualquer outra escrita concorrente nesta casa.
        guard try await Self.lockHouseholdRow(householdID: context.householdID, on: sql) != nil else {
            throw Abort(.internalServerError)
        }

        let isDemotingTheOnlyAdmin = member.role == MemberRole.admin.rawValue && body.role != .admin
        if isDemotingTheOnlyAdmin {
            let wouldOrphanHousehold = try await Self.wouldLeaveHouseholdWithoutAdmin(
                householdID: context.householdID,
                excludingMemberID: memberID,
                on: req.scopedDB
            )
            guard !wouldOrphanHousehold else {
                return try Self.errorResponse(
                    code: .lastAdmin,
                    message: "A casa precisa de pelo menos um admin.",
                    status: .conflict
                )
            }
        }

        member.role = body.role.rawValue
        try await member.save(on: req.scopedDB)

        let dto = MemberDTO(
            id: try member.requireID(),
            userID: member.$user.id,
            displayName: member.user.displayName,
            role: body.role,
            joinedAt: member.createdAt ?? Date(),
            isSelf: member.$user.id == requesterID
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: DELETE /api/v1/households/current/members/:memberID

    /// Admin-only (`RequireRoleMiddleware([.admin])`, boot()) — remove outro membro da casa.
    /// IDENT-06 aplicado a uma segunda ação (a primeira foi gerar convite, plano 01-06), sem
    /// caminho paralelo de autorização.
    @Sendable
    func removeMember(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()
        guard
            let memberIDRaw = req.parameters.get("memberID"),
            let memberID = UUID(uuidString: memberIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "memberID inválido.", status: .badRequest)
        }
        guard let sql = req.scopedDB as? SQLDatabase else {
            fatalError("HouseholdController.removeMember exige um SQLDatabase (FluentSQL escape hatch)")
        }

        // Sob RLS, um memberID de outra casa simplesmente não existe nesta consulta — 404,
        // nunca 403 (mesmo raciocínio de updateMemberRole, T-06-05/T-10-05): o handler não
        // pode confirmar a existência de um membro alheio.
        guard let member = try await HouseholdMember.query(on: req.scopedDB)
            .filter(\.$id == memberID)
            .filter(\.$household.$id == context.householdID)
            .first()
        else {
            throw Abort(.notFound)
        }

        // Remover a si mesmo por esta rota admin-only é sempre recusado — sair tem rota
        // própria (`DELETE .../membership`), que aplica a invariante de último admin em vez
        // de escapar dela (T-10-06).
        guard member.$user.id != requesterID else {
            return try Self.errorResponse(
                code: .cannotRemoveSelf,
                message: "Use a opção Sair da casa para deixar a casa.",
                status: .conflict
            )
        }

        // `SELECT ... FOR UPDATE` na linha da casa — mesmo lock reaproveitado pelo cap de 10
        // (join) e pelo rebaixamento de papel (updateMemberRole), agora também contra a
        // corrida simétrica de duas remoções/saídas concorrentes (T-10-01).
        guard try await Self.lockHouseholdRow(householdID: context.householdID, on: sql) != nil else {
            throw Abort(.internalServerError)
        }

        let wouldOrphanHousehold = try await Self.wouldLeaveHouseholdWithoutAdmin(
            householdID: context.householdID,
            excludingMemberID: memberID,
            on: req.scopedDB
        )
        guard !wouldOrphanHousehold else {
            return try Self.errorResponse(
                code: .lastAdmin,
                message: "A casa precisa de pelo menos um admin.",
                status: .conflict
            )
        }

        try await member.delete(on: req.scopedDB)
        return Response(status: .noContent)
    }

    // MARK: DELETE /api/v1/households/current/membership

    /// Auto-serviço (boot() não coloca `RequireRoleMiddleware` nesta rota) — qualquer papel
    /// pode sair da própria casa. Nunca aceita um alvo: opera só sobre a linha do próprio
    /// requisitante (T-10-04), o que também é o que mantém esta rota fora do alcance de
    /// `RequireRoleMiddleware([.admin])` sem abrir um segundo caminho de remoção de terceiros.
    @Sendable
    func leaveHousehold(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let sql = req.scopedDB as? SQLDatabase else {
            fatalError("HouseholdController.leaveHousehold exige um SQLDatabase (FluentSQL escape hatch)")
        }

        guard let membership = try await HouseholdMember.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            // Impossível na prática — HouseholdContextMiddleware já exige esta linha para
            // resolver o próprio contexto da rota — mas fail-closed em vez de assumir.
            throw Abort(.notFound)
        }

        // `SELECT ... FOR UPDATE` na linha da casa — mesmo lock de `removeMember`/
        // `updateMemberRole`/`join`. É o que serializa dois admins tocando "Sair" no mesmo
        // segundo: sem ele, os dois passariam pela contagem antes de qualquer um deletar sua
        // própria linha, e a casa ficaria órfã (T-10-01).
        guard try await Self.lockHouseholdRow(householdID: context.householdID, on: sql) != nil else {
            throw Abort(.internalServerError)
        }

        let wouldOrphanHousehold = try await Self.wouldLeaveHouseholdWithoutAdmin(
            householdID: context.householdID,
            excludingMemberID: try membership.requireID(),
            on: req.scopedDB
        )
        guard !wouldOrphanHousehold else {
            return try Self.errorResponse(
                code: .lastAdmin,
                message: "Você é o único admin da casa. Promova outra pessoa a admin antes de sair.",
                status: .conflict
            )
        }

        try await membership.delete(on: req.scopedDB)
        return Response(status: .noContent)
    }

    /// Verdadeiro se remover, rebaixar **ou** deixar sair `excludingMemberID` deixaria a casa
    /// sem nenhum admin restante. Chamada sempre depois de `lockHouseholdRow` travar a linha
    /// da casa — nasceu no plano 01-06 com um único consumidor (`updateMemberRole`) e o plano
    /// 01-10 reusa exatamente esta função em `removeMember`/`leaveHousehold`, nunca uma cópia
    /// adaptada: três implementações divergentes desta checagem é exatamente como uma casa
    /// acaba órfã de admin.
    static func wouldLeaveHouseholdWithoutAdmin(
        householdID: UUID,
        excludingMemberID: UUID,
        on database: any Database
    ) async throws -> Bool {
        let remainingAdmins = try await HouseholdMember.query(on: database)
            .filter(\.$household.$id == householdID)
            .filter(\.$role == MemberRole.admin.rawValue)
            .filter(\.$id != excludingMemberID)
            .count()
        return remainingAdmins == 0
    }

    /// `SELECT ... FOR UPDATE` na linha da casa — mesmo lock reaproveitado pelo cap de 10
    /// membros (`join`) e pela invariante de último admin (`updateMemberRole`). Serializa
    /// qualquer escrita concorrente que dependa de contar membros/admins da mesma casa.
    private static func lockHouseholdRow(householdID: UUID, on sql: any SQLDatabase) async throws -> UUID? {
        guard let row = try await sql.raw("""
            SELECT id FROM households WHERE id = \(bind: householdID) FOR UPDATE
            """).first()
        else {
            return nil
        }
        return try row.decode(column: "id", as: UUID.self)
    }

    /// `resolve_invite(p_code)` — ver `CreateHouseholdInvites`. `nil` cobre código
    /// inexistente, expirado e revogado, sem distinguir os três nesta chamada.
    private static func resolveInviteHouseholdID(code: String, on sql: any SQLDatabase) async throws -> UUID? {
        guard let row = try await sql.raw("SELECT resolve_invite(\(bind: code)) AS household_id").first() else {
            return nil
        }
        return try row.decode(column: "household_id", as: UUID?.self)
    }

    /// `invite_exists(p_code)` — ver `CreateHouseholdInvites`. Só chamada quando
    /// `resolveInviteHouseholdID` já devolveu `nil`, para decidir entre `inviteInvalid` e
    /// `inviteExpired` sem um SELECT direto na tabela.
    private static func inviteCodeExists(code: String, on sql: any SQLDatabase) async throws -> Bool {
        guard let row = try await sql.raw("SELECT invite_exists(\(bind: code)) AS exists_flag").first() else {
            return false
        }
        return try row.decode(column: "exists_flag", as: Bool.self)
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

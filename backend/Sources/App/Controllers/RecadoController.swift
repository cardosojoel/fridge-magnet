import Fluent
import FluentSQL
import Foundation
import JKLarShared
import Vapor

/// Sinaliza que algum id em `mentionedUserIDs` não pertence à casa do requisitante — o
/// handler converte isto em 422 `notHouseholdMember` (plano 02-02, T-02-09). Nunca vazado
/// como mensagem específica (qual id falhou, se existe em outra casa): isso seria um oráculo
/// de existência de conta.
private struct MentionValidationError: Error {}

/// `POST /api/v1/recados`, `GET /api/v1/recados`, `PATCH /api/v1/recados/:recadoID`,
/// `DELETE /api/v1/recados/:recadoID` — plano 02-01 (MURAL-01 parte texto, MURAL-05),
/// menções estruturadas + fan-out de push por menção plano 02-02 (MURAL-02, MURAL-03).
///
/// Toda rota deste controller roda atrás de `HouseholdContextMiddleware`: não existe aqui o
/// caso de bootstrap sem casa que `HouseholdController.create`/`join` têm — um recado só
/// nasce depois que o autor já pertence a uma casa.
struct RecadoController: RouteCollection {
    /// Guarda de tamanho de request (não um limite de UX — D-02 fixa que o usuário não tem
    /// limite de caracteres). 20000 é ordens de magnitude acima de qualquer recado de
    /// família e existe só para uma requisição patológica não virar um INSERT de
    /// megabytes.
    static let maxTextLength = 20000

    /// Guarda de tamanho de request para o texto de comentário — comentário não tem limite de
    /// UX fixado em nenhuma decisão, e 5000 é ordens de magnitude acima do uso real (mesmo
    /// espírito de `maxTextLength`, teto menor por ser um campo obrigatório e mais curto por
    /// natureza).
    static let maxCommentTextLength = 5000

    /// Quantos comentários mais recentes o card do feed mostra (02-UI-SPEC.md).
    static let latestCommentsLimit = 2

    /// Guarda de tamanho de resposta da listagem de arquivados (plano 02-11) — NÃO um
    /// recurso de navegação: o 02-UI-SPEC.md não define paginação para a tela de
    /// arquivados (painel de curadoria do admin, não um fluxo infinito). Mesmo raciocínio
    /// do teto de 200 já registrado em `comments`.
    static let maxArchivedListSize = 200

    /// Guarda de tamanho de resposta do bloco de fixados (plano 02-11) — NÃO um teto de
    /// produto: o 02-UI-SPEC.md recusa explicitamente definir um limite de quantos recados
    /// podem estar fixados (linha `overflow | pinned-block`, backstop a reavaliar com uso
    /// real da família). Existe só para o bloco nunca virar uma resposta patológica.
    static let maxPinnedBlockSize = 50

    func boot(routes: any RoutesBuilder) throws {
        let recados = routes.grouped("api", "v1", "recados")
        let authenticated = recados.grouped(SessionAuthenticator(), User.guardMiddleware())
        // MentionPushDispatchMiddleware precisa envolver HouseholdContextMiddleware por
        // FORA (nesta ordem no .grouped) — é a única posição do encadeamento que roda
        // depois que a transação de HouseholdContextMiddleware fecha. Inverter esta ordem
        // reintroduz o push-antes-do-commit (plano 02-02, T-02-13).
        let scoped = authenticated.grouped(MentionPushDispatchMiddleware(), HouseholdContextMiddleware())

        scoped.post(use: create)
        scoped.get(use: feed)
        scoped.patch(":recadoID", use: update)
        scoped.delete(":recadoID", use: destroy)
        // PUT, não POST (a 02-RESEARCH.md diagramou POST): a operação é a substituição
        // idempotente da única reação do requisitante (D-07b) — idempotência importa porque
        // o cliente aplica um toggle otimista que pode reenviar.
        scoped.put(":recadoID", "reactions", use: setReaction)
        scoped.delete(":recadoID", "reactions", use: clearReaction)
        scoped.get(":recadoID", "comments", use: comments)
        scoped.post(":recadoID", "comments", use: createComment)
        // D-14: fixar/desafixar — autor-ou-admin, decidido no handler (`authorOrAdminGuard`
        // contra o papel de `req.householdContext`). As duas rotas não leem corpo nenhum:
        // não existe campo que o cliente possa mandar que altere a decisão.
        scoped.put(":recadoID", "pin", use: pin)
        scoped.delete(":recadoID", "pin", use: unpin)
        // D-15: arquivar — mesma linha de defesa autor-ou-admin das rotas de fixação.
        scoped.put(":recadoID", "archive", use: archive)
        // Grupo admin derivado de `scoped` (que já carrega MentionPushDispatchMiddleware e
        // HouseholdContextMiddleware) — derivado de `authenticated`, `req.householdContext`
        // ainda seria nulo na hora da checagem de papel e o middleware negaria tudo com 403.
        // A rota de listagem tem componente de caminho constante ("archived"), então não
        // disputa com nenhuma rota de parâmetro existente.
        let adminScoped = scoped.grouped(RequireRoleMiddleware([.admin]))
        adminScoped.get("archived", use: archivedList)
        adminScoped.delete(":recadoID", "archive", use: unarchive)
    }

    // MARK: POST /api/v1/recados

    @Sendable
    func create(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let body = try req.content.decode(CreateRecadoRequest.self)
        let normalizedText = Self.normalizeText(body.text)
        if let normalizedText, normalizedText.count > Self.maxTextLength {
            return try Self.errorResponse(
                code: .validation,
                message: "O texto do recado excede o tamanho máximo permitido.",
                status: .badRequest
            )
        }

        // Validação de menção ANTES de qualquer gravação (recado ou linha de menção) — um
        // id fora da casa recusa a request inteira, nada é persistido (T-02-09).
        let mentionedUserIDs: [UUID]
        do {
            mentionedUserIDs = try await Self.resolveHouseholdMemberUserIDs(body.mentionedUserIDs, on: req.scopedDB)
        } catch is MentionValidationError {
            return try Self.errorResponse(
                code: .notHouseholdMember,
                message: "Um ou mais pessoas marcadas não pertencem a esta casa.",
                status: .unprocessableEntity
            )
        }

        guard let sql = req.scopedDB as? SQLDatabase else {
            fatalError("RecadoController.create exige um SQLDatabase (FluentSQL escape hatch)")
        }
        guard let row = try await sql.raw("SELECT nextval('recados_sequence_seq') AS next").first() else {
            throw Abort(.internalServerError)
        }
        let sequence = try row.decode(column: "next", as: Int64.self)

        let recado = Recado(
            householdID: context.householdID,
            authorID: userID,
            text: normalizedText,
            sequence: sequence
        )
        try await recado.save(on: req.scopedDB)

        let recadoID = try recado.requireID()
        for mentionedUserID in mentionedUserIDs {
            let mention = RecadoMention(
                householdID: context.householdID,
                recadoID: recadoID,
                mentionedUserID: mentionedUserID
            )
            try await mention.save(on: req.scopedDB)
        }

        try await Self.enqueueMentionPushes(
            for: req,
            recipients: mentionedUserIDs,
            authorID: userID,
            authorName: user.displayName ?? "Alguém",
            text: normalizedText,
            hasPhotos: false,
            isComment: false
        )

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .created)
    }

    // MARK: GET /api/v1/recados

    @Sendable
    func feed(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        // Paginação sempre por chave (`sequence`), nunca por deslocamento numérico: numa
        // lista que cresce por cima enquanto a pessoa rola, deslocamento duplica ou pula
        // linha (02-RESEARCH.md Pitfall 2).
        let cursor: Int64? = try? req.query.get(Int64.self, at: "cursor")

        // Dois filtros além do de casa (plano 02-11): arquivamento ausente tira o recado
        // arquivado do mural de TODOS (D-15); fixação ausente impede um recado fixado de
        // aparecer no bloco E no fluxo ("nunca renderizado duas vezes", 02-UI-SPEC.md).
        // O esquema de cursor fica intacto: o cursor compara valor de `sequence`, nunca
        // posição — excluir linhas por filtro não abre buraco nele.
        var query = Recado.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
            .filter(\.$archivedAt == nil)
            .filter(\.$pinnedAt == nil)
        if let cursor {
            query = query.filter(\.$sequence < cursor)
        }

        // Busca uma linha extra além do tamanho de página (20, 02-RESEARCH.md A5) para
        // saber se há próxima página sem uma segunda consulta de contagem.
        let page = try await query
            .sort(\.$sequence, .descending)
            .limit(21)
            .all()

        let hasMore = page.count > 20
        let items = Array(page.prefix(20))

        var dtos: [RecadoDTO] = []
        dtos.reserveCapacity(items.count)
        for recado in items {
            dtos.append(try await Self.buildDTO(
                recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
            ))
        }

        // Bloco de fixados FORA da paginação por cursor: só na primeira página (requisição
        // sem cursor); com cursor, coleção vazia sem nenhuma consulta. Consequência aceita:
        // desafixar um recado no meio de uma rolagem pode fazê-lo reaparecer numa página
        // seguinte — mesma classe de evento de "um recado novo chega enquanto a pessoa
        // rola", e o cliente já descarta id repetido em `loadNextPage`.
        var pinnedDTOs: [RecadoDTO] = []
        if cursor == nil {
            let pinnedRows = try await Recado.query(on: req.scopedDB)
                .filter(\.$household.$id == context.householdID)
                .filter(\.$pinnedAt != nil)
                .filter(\.$archivedAt == nil)
                .sort(\.$pinnedAt, .descending)
                .limit(Self.maxPinnedBlockSize)
                .all()
            pinnedDTOs.reserveCapacity(pinnedRows.count)
            for recado in pinnedRows {
                pinnedDTOs.append(try await Self.buildDTO(
                    recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
                ))
            }
        }

        let nextCursor = hasMore ? items.last?.sequence : nil
        let feedPage = RecadoFeedPage(items: dtos, nextCursor: nextCursor, pinned: pinnedDTOs)
        return try Self.jsonResponse(feedPage, status: .ok)
    }

    // MARK: PATCH /api/v1/recados/:recadoID

    @Sendable
    func update(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        // RLS já escopou a consulta na casa do requisitante — um recado de outra casa cai
        // aqui como inexistente, não como proibido (404, nunca 403; a rota não pode
        // confirmar a existência de uma linha alheia).
        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        // D-03: só o autor edita, sem exceção de moderação para admin.
        guard recado.$author.id == userID else {
            return try Self.errorResponse(
                code: .notAuthor,
                message: "Só o autor pode editar este recado.",
                status: .forbidden
            )
        }

        let body = try req.content.decode(UpdateRecadoRequest.self)
        let normalizedText = Self.normalizeText(body.text)
        if let normalizedText, normalizedText.count > Self.maxTextLength {
            return try Self.errorResponse(
                code: .validation,
                message: "O texto do recado excede o tamanho máximo permitido.",
                status: .badRequest
            )
        }

        let requestedMentionIDs: [UUID]
        do {
            requestedMentionIDs = try await Self.resolveHouseholdMemberUserIDs(body.mentionedUserIDs, on: req.scopedDB)
        } catch is MentionValidationError {
            return try Self.errorResponse(
                code: .notHouseholdMember,
                message: "Um ou mais pessoas marcadas não pertencem a esta casa.",
                status: .unprocessableEntity
            )
        }

        // Substitui o conjunto de menções: as retiradas somem, as acrescentadas entram, as
        // que permanecem mantêm o created_at original (nunca apagadas+recriadas). Só o
        // conjunto ACRESCENTADO nesta edição dispara push (Task 2) — evita re-notificar quem
        // já estava marcado a cada novo PATCH.
        let existingMentions = try await RecadoMention.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .all()
        let existingMentionedUserIDs = Set(existingMentions.map(\.$mentionedUser.id))
        let requestedSet = Set(requestedMentionIDs)

        let removedMentions = existingMentions.filter { !requestedSet.contains($0.$mentionedUser.id) }
        for mention in removedMentions {
            try await mention.delete(on: req.scopedDB)
        }

        let addedUserIDs = requestedMentionIDs.filter { !existingMentionedUserIDs.contains($0) }
        for mentionedUserID in addedUserIDs {
            let mention = RecadoMention(
                householdID: recado.$household.id,
                recadoID: recadoID,
                mentionedUserID: mentionedUserID
            )
            try await mention.save(on: req.scopedDB)
        }

        recado.text = normalizedText
        try await recado.save(on: req.scopedDB)

        try await Self.enqueueMentionPushes(
            for: req,
            recipients: addedUserIDs,
            authorID: recado.$author.id,
            authorName: user.displayName ?? "Alguém",
            text: normalizedText,
            hasPhotos: false,
            isComment: false
        )

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: DELETE /api/v1/recados/:recadoID

    @Sendable
    func destroy(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        guard recado.$author.id == userID else {
            return try Self.errorResponse(
                code: .notAuthor,
                message: "Só o autor pode apagar este recado.",
                status: .forbidden
            )
        }

        // Coleta as chaves de objeto ANTES de apagar qualquer linha — é a única chance de
        // saber o que existia no armazenamento para este recado. Com zero fotos (estado
        // real enquanto nenhuma rota escreve em recado_photos nesta fase), a lista é vazia
        // e a chamada à costura, mais abaixo, não faz nada.
        let objectKeys = try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .all()
            .map(\.objectKey)

        let commentIDs = try await RecadoComment.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .all()
            .map { try $0.requireID() }

        // Linhas filhas apagadas explicitamente sob req.scopedDB — as FKs já são cascade no
        // banco, mas fazer isso aqui mantém a operação inteira dentro da mesma transação
        // escopada por RLS desta request.
        try await RecadoMention.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .delete()
        if !commentIDs.isEmpty {
            try await RecadoMention.query(on: req.scopedDB)
                .filter(\.$comment.$id ~~ commentIDs)
                .delete()
        }
        try await RecadoReaction.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .delete()
        try await RecadoComment.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .delete()
        try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .delete()
        try await recado.delete(on: req.scopedDB)

        // Melhor esforço: as linhas já foram apagadas; um objeto órfão no bucket é um custo
        // de armazenamento, não uma falha de correção — mas sem esta chamada uma foto
        // apagada continuaria alcançável por qualquer URL assinada ainda válida.
        do {
            try await req.application.objectStorageClient.deleteObjects(keys: objectKeys)
        } catch {
            req.logger.error("falha ao apagar objetos de armazenamento do recado \(recadoID): \(error)")
        }

        return Response(status: .noContent)
    }

    // MARK: PUT /api/v1/recados/:recadoID/reactions

    @Sendable
    func setReaction(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        // A decodificação é a validação — um `kind` fora do enum fechado nunca chega aqui,
        // já falhou em `req.content.decode` com 400 (D-07, 02-RESEARCH.md Pitfall 4). Nunca
        // ler o campo como texto solto.
        let body = try req.content.decode(SetReactionRequest.self)

        // Consulta, então atualiza ou insere (padrão de `DeviceController.register`, não
        // "insere e captura colisão de constraint" — aqui não há valor gerado aleatoriamente
        // que justifique retentativa). O filtro por `user_id` do JWT é o que impede alguém
        // tocar a linha de outra pessoa; encontrar a própria linha e trocar `kind` é a
        // substituição de D-07b, nunca uma segunda linha acumulada.
        if let existing = try await RecadoReaction.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .filter(\.$user.$id == userID)
            .first()
        {
            existing.kind = body.kind.rawValue
            try await existing.save(on: req.scopedDB)
        } else {
            let reaction = RecadoReaction(
                householdID: recado.$household.id,
                recadoID: recadoID,
                userID: userID,
                kind: body.kind.rawValue
            )
            try await reaction.save(on: req.scopedDB)
        }

        let summary = try await Self.reactionSummary(
            for: recadoID, requesterID: userID, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(summary, status: .ok)
    }

    // MARK: DELETE /api/v1/recados/:recadoID/reactions

    @Sendable
    func clearReaction(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        _ = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        // Idempotente por construção: filtrar por (recadoID, userID) e apagar o que existir
        // — nenhuma linha encontrada não é um erro, é o estado final desejado (204 igual).
        try await RecadoReaction.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .filter(\.$user.$id == userID)
            .delete()

        return Response(status: .noContent)
    }

    // MARK: GET /api/v1/recados/:recadoID/comments

    @Sendable
    func comments(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        _ = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        // Lista inteira, sem paginação (D-08, 02-UI-SPEC.md §UI Considerations não tem linha
        // de "carregar mais" para comment-list): `.limit(200)` existe só como guarda de
        // tamanho de resposta, não como recurso de navegação.
        let rows = try await RecadoComment.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .with(\.$author)
            .sort(\.$createdAt, .ascending)
            .limit(200)
            .all()

        var dtos: [CommentDTO] = []
        dtos.reserveCapacity(rows.count)
        for comment in rows {
            dtos.append(try await Self.buildCommentDTO(comment: comment, requesterID: userID, on: req.scopedDB))
        }

        return try Self.jsonResponse(dtos, status: .ok)
    }

    // MARK: POST /api/v1/recados/:recadoID/comments

    @Sendable
    func createComment(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        _ = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        let body = try req.content.decode(CreateCommentRequest.self)
        let trimmedText = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return try Self.errorResponse(
                code: .validation, message: "O texto do comentário não pode ser vazio.", status: .badRequest
            )
        }
        guard trimmedText.count <= Self.maxCommentTextLength else {
            return try Self.errorResponse(
                code: .validation,
                message: "O texto do comentário excede o tamanho máximo permitido.",
                status: .badRequest
            )
        }

        // Validação de menção ANTES de qualquer gravação — mesmo contrato de
        // create(recado): um id fora da casa recusa o comentário inteiro, nada é persistido.
        let mentionedUserIDs: [UUID]
        do {
            mentionedUserIDs = try await Self.resolveHouseholdMemberUserIDs(body.mentionedUserIDs, on: req.scopedDB)
        } catch is MentionValidationError {
            return try Self.errorResponse(
                code: .notHouseholdMember,
                message: "Um ou mais pessoas marcadas não pertencem a esta casa.",
                status: .unprocessableEntity
            )
        }

        let comment = RecadoComment(
            householdID: context.householdID,
            recadoID: recadoID,
            authorID: userID,
            text: trimmedText
        )
        try await comment.save(on: req.scopedDB)
        let commentID = try comment.requireID()

        for mentionedUserID in mentionedUserIDs {
            let mention = RecadoMention(
                householdID: context.householdID,
                commentID: commentID,
                mentionedUserID: mentionedUserID
            )
            try await mention.save(on: req.scopedDB)
        }

        // D-09: marcar dentro de um comentário dispara push pelo mesmo mecanismo do recado —
        // `isComment: true` faz `enqueueMentionPushes` montar o corpo com
        // `MuralPushCopy.commentMentionBody` em vez de `recadoMentionBody`. Nenhum segundo
        // mecanismo de notificação: mesmo `MentionPushDispatchMiddleware`/`PushService` do
        // plano 02-02, só um novo chamador.
        try await Self.enqueueMentionPushes(
            for: req,
            recipients: mentionedUserIDs,
            authorID: userID,
            authorName: user.displayName ?? "Alguém",
            text: trimmedText,
            hasPhotos: false,
            isComment: true
        )

        let dto = try await Self.buildCommentDTO(comment: comment, requesterID: userID, on: req.scopedDB)
        return try Self.jsonResponse(dto, status: .created)
    }

    // MARK: PUT /api/v1/recados/:recadoID/pin

    /// D-14: fixa o recado no topo do mural — autor OU admin, decidido por
    /// `authorOrAdminGuard`. A rota não decodifica corpo nenhum: não há nada que o cliente
    /// possa mandar que altere a decisão.
    @Sendable
    func pin(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        // Recado arquivado cai aqui como 404 (filtro padrão de `loadRecadoOrNotFound`) —
        // um recado fora do mural não pode ser fixado.
        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        if let forbidden = try Self.authorOrAdminGuard(recado: recado, userID: userID, role: context.role) {
            return forbidden
        }

        // Idempotência que preserva a ordem do bloco: fixar de novo NÃO sobrescreve o
        // instante original — uma retentativa de rede nunca reordena o bloco de fixados.
        if recado.pinnedAt == nil {
            recado.pinnedAt = Date()
            try await recado.save(on: req.scopedDB)
        }

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: DELETE /api/v1/recados/:recadoID/pin

    /// D-14: desafixa o recado — mesma matriz autor-ou-admin de `pin`. Idempotente quando a
    /// fixação já está ausente (200 igual). Sem corpo, mesmo motivo de `pin`.
    @Sendable
    func unpin(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        if let forbidden = try Self.authorOrAdminGuard(recado: recado, userID: userID, role: context.role) {
            return forbidden
        }

        recado.pinnedAt = nil
        try await recado.save(on: req.scopedDB)

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: PUT /api/v1/recados/:recadoID/archive

    /// D-15: arquiva o recado — autor OU admin (`authorOrAdminGuard`), mesma linha de
    /// defesa de `pin`. Um recado já arquivado cai como 404 no `loadRecadoOrNotFound` (ele
    /// já saiu do mural — e é isso mesmo). Nenhum corpo é decodificado.
    @Sendable
    func archive(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB)

        if let forbidden = try Self.authorOrAdminGuard(recado: recado, userID: userID, role: context.role) {
            return forbidden
        }

        // Arquivar limpa a fixação NO MESMO save: um recado que saiu do mural não pode
        // continuar preso ao topo do mural — é o que torna literalmente verdadeira a
        // promessa de D-15 de que desarquivar devolve o recado à posição cronológica
        // natural (sem isto, ele voltaria ao bloco de fixados no dia do desarquivamento).
        recado.archivedAt = Date()
        recado.pinnedAt = nil
        try await recado.save(on: req.scopedDB)

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: context.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: DELETE /api/v1/recados/:recadoID/archive (admin-only)

    /// D-15: desarquiva — estritamente admin, negado pelo middleware de papel (grupo
    /// `adminScoped` do `boot`) ANTES de este handler rodar. O handler deliberadamente NÃO repete a checagem de
    /// papel: o middleware já negou quem não é admin, e uma segunda checagem aqui seria uma
    /// segunda fonte de verdade a divergir. Única rota que enxerga recado arquivado
    /// (`includeArchived: true`) — é o caminho de volta. Não toca a fixação: desarquivar
    /// devolve o recado à ordenação cronológica (`sequence`), nunca ao bloco de fixados.
    @Sendable
    func unarchive(req: Request) async throws -> Response {
        guard let householdContext = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoIDRaw = req.parameters.get("recadoID"),
            let recadoID = UUID(uuidString: recadoIDRaw)
        else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        let recado = try await Self.loadRecadoOrNotFound(recadoID, on: req.scopedDB, includeArchived: true)

        // Idempotente quando o arquivamento já está ausente (200 igual).
        recado.archivedAt = nil
        try await recado.save(on: req.scopedDB)

        let dto = try await Self.buildDTO(
            recado: recado, requesterID: userID, viewerRole: householdContext.role, on: req.scopedDB, logger: req.logger
        )
        return try Self.jsonResponse(dto, status: .ok)
    }

    // MARK: GET /api/v1/recados/archived (admin-only)

    /// D-15: painel de arquivados do admin — também negado pelo middleware de papel antes
    /// do handler. Escopado na casa do contexto (a RLS já garante; o filtro explícito
    /// documenta), ordenado do mais recentemente arquivado para o mais antigo. Resposta é
    /// uma coleção simples, não uma página com cursor: a tela é um painel de curadoria,
    /// não um fluxo infinito.
    @Sendable
    func archivedList(req: Request) async throws -> Response {
        guard let householdContext = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        let rows = try await Recado.query(on: req.scopedDB)
            .filter(\.$household.$id == householdContext.householdID)
            .filter(\.$archivedAt != nil)
            .sort(\.$archivedAt, .descending)
            .limit(Self.maxArchivedListSize)
            .all()

        var dtos: [RecadoDTO] = []
        dtos.reserveCapacity(rows.count)
        for recado in rows {
            dtos.append(try await Self.buildDTO(
                recado: recado, requesterID: userID, viewerRole: householdContext.role, on: req.scopedDB, logger: req.logger
            ))
        }
        return try Self.jsonResponse(dtos, status: .ok)
    }

    // MARK: Mapeamento Recado → RecadoDTO

    /// Preenche todos os campos consultando de verdade `recado_photos`, `recado_mentions`,
    /// `recado_reactions` e `recado_comments` daquele recado (mais `commentCount` e os 2
    /// comentários mais recentes). Enquanto nenhuma rota escrever nessas quatro tabelas,
    /// essas consultas devolvem coleção vazia e contagem zero — o estado verdadeiro do
    /// banco nesta fase, não um valor fixo no código.
    ///
    /// `viewerRole` (plano 02-11) é a ÚNICA fonte dos três sinais de permissão
    /// (`canPin`/`canArchive`/`canUnarchive`), calculados aqui no mesmo ponto que `isMine` —
    /// derivá-los no cliente reintroduziria a regra de autorização no front-end, contra a
    /// diretriz de zero-trust do `.claude/CLAUDE.md`.
    private static func buildDTO(
        recado: Recado,
        requesterID: UUID,
        viewerRole: MemberRole,
        on database: any Database,
        logger: Logger
    ) async throws -> RecadoDTO {
        let recadoID = try recado.requireID()

        guard let author = try await User.find(recado.$author.id, on: database) else {
            throw Abort(.internalServerError)
        }

        let photos = try await RecadoPhoto.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .sort(\.$position, .ascending)
            .all()
            .map { RecadoPhotoRefDTO(id: try $0.requireID(), position: $0.position) }

        let mentionRows = try await RecadoMention.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .with(\.$mentionedUser)
            .all()
        let mentions = mentionRows.map {
            MentionDTO(userID: $0.$mentionedUser.id, displayName: $0.mentionedUser.displayName)
        }

        // Mesmo helper que `setReaction`/`clearReaction` usam para a própria resposta — feed
        // e resposta de reação nunca podem divergir sobre a contagem ou a reação do próprio
        // requisitante.
        let reactionSummary = try await Self.reactionSummary(
            for: recadoID, requesterID: requesterID, on: database, logger: logger
        )

        let commentCount = try await RecadoComment.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .count()

        let latestCommentRows = try await RecadoComment.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .with(\.$author)
            .sort(\.$createdAt, .descending)
            .limit(Self.latestCommentsLimit)
            .all()

        var latestComments: [CommentDTO] = []
        for comment in latestCommentRows.reversed() {
            latestComments.append(try await Self.buildCommentDTO(comment: comment, requesterID: requesterID, on: database))
        }

        let isMine = recado.$author.id == requesterID
        let isAdmin = viewerRole == .admin

        return RecadoDTO(
            id: recadoID,
            authorID: recado.$author.id,
            authorDisplayName: author.displayName,
            isMine: isMine,
            text: recado.text,
            sequence: recado.sequence,
            createdAt: recado.createdAt ?? Date(),
            updatedAt: recado.updatedAt ?? Date(),
            photos: photos,
            mentions: mentions,
            reactions: reactionSummary.reactions,
            myReaction: reactionSummary.myReaction,
            commentCount: commentCount,
            latestComments: latestComments,
            pinnedAt: recado.pinnedAt,
            archivedAt: recado.archivedAt,
            canPin: isMine || isAdmin,
            canArchive: isMine || isAdmin,
            canUnarchive: isAdmin
        )
    }

    // MARK: Mapeamento RecadoComment → CommentDTO

    /// Carrega as menções do comentário e monta o `CommentDTO` — reusado por `comments`,
    /// `createComment` e `buildDTO` (prévia de `latestComments`) para os três caminhos nunca
    /// divergirem sobre a forma de um comentário.
    private static func buildCommentDTO(
        comment: RecadoComment,
        requesterID: UUID,
        on database: any Database
    ) async throws -> CommentDTO {
        let commentID = try comment.requireID()

        let authorDisplayName: String?
        if comment.$author.value != nil {
            authorDisplayName = comment.author.displayName
        } else {
            authorDisplayName = try await User.find(comment.$author.id, on: database)?.displayName
        }

        let mentionRows = try await RecadoMention.query(on: database)
            .filter(\.$comment.$id == commentID)
            .with(\.$mentionedUser)
            .all()
        let mentions = mentionRows.map {
            MentionDTO(userID: $0.$mentionedUser.id, displayName: $0.mentionedUser.displayName)
        }

        return CommentDTO(
            id: commentID,
            authorID: comment.$author.id,
            authorDisplayName: authorDisplayName,
            text: comment.text,
            mentions: mentions,
            createdAt: comment.createdAt ?? Date(),
            isMine: comment.$author.id == requesterID
        )
    }

    // MARK: Reações (D-07, D-07b)

    /// Carrega as linhas de `recado_reactions` daquele recado, agrupa por `kind` na ordem de
    /// declaração de `ReactionKind.allCases` (para a barra de reações do cliente não mudar de
    /// ordem entre requisições) e resolve `myReaction` pela linha do requisitante. Usado por
    /// `setReaction`/`clearReaction` (resposta direta) e por `buildDTO` (feed) — os dois
    /// caminhos nunca podem divergir sobre a contagem.
    private static func reactionSummary(
        for recadoID: UUID,
        requesterID: UUID,
        on database: any Database,
        logger: Logger
    ) async throws -> RecadoReactionSummaryDTO {
        let reactionRows = try await RecadoReaction.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .all()

        var countsByKind: [ReactionKind: Int] = [:]
        var myReactionKind: ReactionKind?
        for reaction in reactionRows {
            guard let kind = ReactionKind(rawValue: reaction.kind) else {
                // Só alcançável por escrita direta no banco (a decodificação HTTP sempre
                // valida contra o enum fechado) — a linha é ignorada na agregação, nunca
                // derruba o feed inteiro.
                logger.error("recado_reactions.kind fora do conjunto fechado: \(reaction.kind)")
                continue
            }
            countsByKind[kind, default: 0] += 1
            if reaction.$user.id == requesterID {
                myReactionKind = kind
            }
        }

        let reactions = ReactionKind.allCases.compactMap { kind -> ReactionCountDTO? in
            guard let count = countsByKind[kind] else { return nil }
            return ReactionCountDTO(kind: kind, count: count)
        }

        return RecadoReactionSummaryDTO(reactions: reactions, myReaction: myReactionKind)
    }

    // MARK: Recado por id (404, nunca 403, para casa alheia)

    /// RLS já escopou a consulta na casa do requisitante — um recado de outra casa cai aqui
    /// como inexistente, não como proibido (404, nunca 403; a rota não pode confirmar a
    /// existência de uma linha alheia). Extraído de `update`/`destroy` (plano 02-01) para as
    /// rotas de reação e comentário deste plano compartilharem exatamente o mesmo
    /// comportamento.
    ///
    /// `includeArchived` com padrão `false` (D-15, plano 02-11): este é o ponto ÚNICO que
    /// torna um recado arquivado invisível — 404 para TODO papel, inclusive admin (um 404
    /// que dependesse do papel seria, ele próprio, um oráculo de existência da linha). O
    /// padrão falso é deliberado: toda rota existente herda a invisibilidade sem ser editada
    /// uma por uma, e só a rota de desarquivar passa `includeArchived: true`.
    private static func loadRecadoOrNotFound(
        _ recadoID: UUID,
        on db: any Database,
        includeArchived: Bool = false
    ) async throws -> Recado {
        var query = Recado.query(on: db)
            .filter(\.$id == recadoID)
        if !includeArchived {
            query = query.filter(\.$archivedAt == nil)
        }
        guard let recado = try await query.first() else {
            throw Abort(.notFound)
        }
        return recado
    }

    // MARK: Fixar/arquivar — autorização autor-ou-admin (D-14/D-15, plano 02-11)

    /// Devolve `nil` quando o requisitante é o autor OU tem papel de admin; caso contrário,
    /// a resposta 403. Reusa `APIErrorCode.forbidden` (não `.notAuthor`, que diria "só o
    /// autor" — falso aqui: a regra de D-14/D-15 é autor-ou-admin) com a mesma mensagem do
    /// `RequireRoleMiddleware`. O papel vem de `req.householdContext`, lido da linha real de
    /// `household_members` dentro da transação da request — nunca de claim do token, nunca
    /// de cabeçalho, nunca de campo do corpo.
    private static func authorOrAdminGuard(recado: Recado, userID: UUID, role: MemberRole) throws -> Response? {
        if recado.$author.id == userID || role == .admin {
            return nil
        }
        return try Self.errorResponse(
            code: .forbidden,
            message: "Você não tem permissão para esta ação.",
            status: .forbidden
        )
    }

    // MARK: Menções (plano 02-02, D-05/D-06)

    /// Deduplica preservando a ordem de chegada e valida cada id contra `household_members`
    /// SOB a conexão escopada — a própria RLS já limita o universo à casa do requisitante, e
    /// comparar a contagem de ids encontrados com a de ids pedidos é o que transforma
    /// "invisível" em "recusado" em vez de "silenciosamente ignorado" (T-02-09). Lança
    /// `MentionValidationError` sem revelar qual id falhou nem se o usuário existe em outra
    /// casa — isso seria um oráculo de existência de conta.
    private static func resolveHouseholdMemberUserIDs(
        _ requested: [UUID],
        on database: any Database
    ) async throws -> [UUID] {
        var seen = Set<UUID>()
        var deduplicated: [UUID] = []
        for id in requested where seen.insert(id).inserted {
            deduplicated.append(id)
        }
        guard !deduplicated.isEmpty else {
            return []
        }

        let foundUserIDs = try await HouseholdMember.query(on: database)
            .filter(\.$user.$id ~~ deduplicated)
            .all()
            .map(\.$user.id)
        guard Set(foundUserIDs).count == deduplicated.count else {
            throw MentionValidationError()
        }
        return deduplicated
    }

    /// Enfileira um `PendingMentionPush` por device token de cada destinatário em
    /// `req.pendingMentionPushes` — nunca envia daqui diretamente.
    /// `MentionPushDispatchMiddleware` consome a fila depois que a transação de
    /// `HouseholdContextMiddleware` fecha com sucesso (T-02-13). Marcar a si mesmo grava a
    /// linha de menção (marcação social legítima), mas nunca gera push para o próprio autor.
    /// Um destinatário sem token registrado simplesmente não gera entrada — ausência de push
    /// não é erro. `isComment` seleciona o corpo de cópia certo (D-09, reusado pelo plano
    /// 02-03 a partir da criação de comentário).
    private static func enqueueMentionPushes(
        for req: Request,
        recipients: [UUID],
        authorID: UUID,
        authorName: String,
        text: String?,
        hasPhotos: Bool,
        isComment: Bool
    ) async throws {
        let notifiableRecipients = recipients.filter { $0 != authorID }
        guard !notifiableRecipients.isEmpty else { return }

        let preview = MuralPushCopy.preview(fromText: text, hasPhotos: hasPhotos)
        let body = isComment
            ? MuralPushCopy.commentMentionBody(author: authorName, preview: preview)
            : MuralPushCopy.recadoMentionBody(author: authorName, preview: preview)

        // Ainda dentro da transação escopada da request — a RLS de device_tokens está ativa
        // e vê os tokens da casa.
        let tokens = try await DeviceToken.query(on: req.scopedDB)
            .filter(\.$user.$id ~~ notifiableRecipients)
            .all()

        var pending = req.pendingMentionPushes
        for token in tokens {
            guard let tokenID = token.id else { continue }
            pending.append(PendingMentionPush(deviceTokenID: tokenID, title: MuralPushCopy.mentionTitle, body: body))
        }
        req.pendingMentionPushes = pending
    }

    /// Trim + normaliza string vazia para `nil` (D-01: um recado sem texto tem `text ==
    /// nil`, nunca uma string vazia gravada).
    private static func normalizeText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

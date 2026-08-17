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

    /// Quantos comentários mais recentes o card do feed mostra (02-UI-SPEC.md).
    static let latestCommentsLimit = 2

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

        let dto = try await Self.buildDTO(recado: recado, requesterID: userID, on: req.scopedDB)
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

        var query = Recado.query(on: req.scopedDB)
            .filter(\.$household.$id == context.householdID)
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
            dtos.append(try await Self.buildDTO(recado: recado, requesterID: userID, on: req.scopedDB))
        }

        let nextCursor = hasMore ? items.last?.sequence : nil
        let feedPage = RecadoFeedPage(items: dtos, nextCursor: nextCursor)
        return try Self.jsonResponse(feedPage, status: .ok)
    }

    // MARK: PATCH /api/v1/recados/:recadoID

    @Sendable
    func update(req: Request) async throws -> Response {
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

        // RLS já escopou a consulta na casa do requisitante — um recado de outra casa cai
        // aqui como inexistente, não como proibido (404, nunca 403; a rota não pode
        // confirmar a existência de uma linha alheia).
        guard let recado = try await Recado.query(on: req.scopedDB)
            .filter(\.$id == recadoID)
            .first()
        else {
            throw Abort(.notFound)
        }

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

        let dto = try await Self.buildDTO(recado: recado, requesterID: userID, on: req.scopedDB)
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

        guard let recado = try await Recado.query(on: req.scopedDB)
            .filter(\.$id == recadoID)
            .first()
        else {
            throw Abort(.notFound)
        }

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

    // MARK: Mapeamento Recado → RecadoDTO

    /// Preenche todos os campos consultando de verdade `recado_photos`, `recado_mentions`,
    /// `recado_reactions` e `recado_comments` daquele recado (mais `commentCount` e os 2
    /// comentários mais recentes). Enquanto nenhuma rota escrever nessas quatro tabelas,
    /// essas consultas devolvem coleção vazia e contagem zero — o estado verdadeiro do
    /// banco nesta fase, não um valor fixo no código.
    private static func buildDTO(
        recado: Recado,
        requesterID: UUID,
        on database: any Database
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

        let reactionRows = try await RecadoReaction.query(on: database)
            .filter(\.$recado.$id == recadoID)
            .all()
        var reactionCounts: [String: Int] = [:]
        var myReactionKind: ReactionKind?
        for reaction in reactionRows {
            reactionCounts[reaction.kind, default: 0] += 1
            if reaction.$user.id == requesterID {
                myReactionKind = ReactionKind(rawValue: reaction.kind)
            }
        }
        let reactions = reactionCounts
            .compactMap { key, count -> ReactionCountDTO? in
                guard let kind = ReactionKind(rawValue: key) else { return nil }
                return ReactionCountDTO(kind: kind, count: count)
            }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }

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
            let commentID = try comment.requireID()
            let commentMentionRows = try await RecadoMention.query(on: database)
                .filter(\.$comment.$id == commentID)
                .with(\.$mentionedUser)
                .all()
            let commentMentions = commentMentionRows.map {
                MentionDTO(userID: $0.$mentionedUser.id, displayName: $0.mentionedUser.displayName)
            }
            latestComments.append(CommentDTO(
                id: commentID,
                authorID: comment.$author.id,
                authorDisplayName: comment.author.displayName,
                text: comment.text,
                mentions: commentMentions,
                createdAt: comment.createdAt ?? Date(),
                isMine: comment.$author.id == requesterID
            ))
        }

        return RecadoDTO(
            id: recadoID,
            authorID: recado.$author.id,
            authorDisplayName: author.displayName,
            isMine: recado.$author.id == requesterID,
            text: recado.text,
            sequence: recado.sequence,
            createdAt: recado.createdAt ?? Date(),
            updatedAt: recado.updatedAt ?? Date(),
            photos: photos,
            mentions: mentions,
            reactions: reactions,
            myReaction: myReactionKind,
            commentCount: commentCount,
            latestComments: latestComments
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

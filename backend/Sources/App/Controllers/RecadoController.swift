import Fluent
import FluentSQL
import Foundation
import JKLarShared
import Vapor

/// `POST /api/v1/recados`, `GET /api/v1/recados`, `PATCH /api/v1/recados/:recadoID`,
/// `DELETE /api/v1/recados/:recadoID` — plano 02-01 (MURAL-01 parte texto, MURAL-05).
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
        let scoped = authenticated.grouped(HouseholdContextMiddleware())

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

        recado.text = normalizedText
        try await recado.save(on: req.scopedDB)

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

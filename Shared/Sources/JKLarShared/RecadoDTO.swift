import Foundation

/// Conjunto fechado de reações do mural (D-07) — enum fechado, nunca string livre.
/// `glyph` mora aqui, no pacote compartilhado, para as duas pontas (cliente/servidor) nunca
/// divergirem sobre qual emoji cada `rawValue` representa. O valor gravado na coluna
/// (`RecadoReaction.kind`) é sempre o `rawValue`, nunca o glifo.
public enum ReactionKind: String, Codable, Sendable, CaseIterable {
    case love
    case laugh
    case wow
    case sad
    case like
    case thanks

    public var glyph: String {
        switch self {
        case .love: "❤️"
        case .laugh: "😂"
        case .wow: "😮"
        case .sad: "😢"
        case .like: "👍"
        case .thanks: "🙏"
        }
    }
}

/// Referência a uma foto do carrossel, sem URL — quem assina URL de download é o
/// `RecadoPhotoController` do plano 02-04, em chamada própria, para uma URL assinada de
/// curta duração nunca ficar embutida num JSON de feed que o cliente pode cachear.
public struct RecadoPhotoRefDTO: Codable, Sendable {
    public var id: UUID
    public var position: Int

    public init(id: UUID, position: Int) {
        self.id = id
        self.position = position
    }
}

/// Uma @menção resolvida para exibição — sempre um `userID` real (D-06: seletor
/// estruturado, nunca texto livre), nunca um nome cru sem id por trás.
public struct MentionDTO: Codable, Sendable {
    public var userID: UUID
    public var displayName: String?

    public init(userID: UUID, displayName: String?) {
        self.userID = userID
        self.displayName = displayName
    }
}

/// Contagem de uma reação específica no recado — a barra de reações do feed soma por
/// `kind`, nunca lista cada reação individualmente.
public struct ReactionCountDTO: Codable, Sendable {
    public var kind: ReactionKind
    public var count: Int

    public init(kind: ReactionKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Um comentário em lista plana cronológica (D-08).
public struct CommentDTO: Codable, Sendable {
    public var id: UUID
    public var authorID: UUID
    public var authorDisplayName: String?
    public var text: String
    public var mentions: [MentionDTO]
    public var createdAt: Date
    /// Verdadeiro só na linha do próprio requisitante — sempre computado no servidor
    /// (comparação de `author_id` com o `sub` do JWT), nunca inferido no cliente por nome
    /// ou posição na lista, mesmo padrão de `MemberDTO.isSelf`.
    public var isMine: Bool

    public init(
        id: UUID,
        authorID: UUID,
        authorDisplayName: String?,
        text: String,
        mentions: [MentionDTO],
        createdAt: Date,
        isMine: Bool
    ) {
        self.id = id
        self.authorID = authorID
        self.authorDisplayName = authorDisplayName
        self.text = text
        self.mentions = mentions
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

/// Um recado do mural, do ponto de vista do membro autenticado que fez o request.
public struct RecadoDTO: Codable, Sendable {
    public var id: UUID
    public var authorID: UUID
    public var authorDisplayName: String?
    /// Verdadeiro só quando `authorID` é o próprio requisitante — sempre calculado no
    /// servidor comparando `author_id` com o `sub` do JWT, mesmo papel de
    /// `MemberDTO.isSelf`. É o que habilita o menu de editar/apagar só no recado do próprio
    /// autor (D-03) — nunca inferido no cliente.
    public var isMine: Bool
    public var text: String?
    public var sequence: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var photos: [RecadoPhotoRefDTO]
    public var mentions: [MentionDTO]
    public var reactions: [ReactionCountDTO]
    public var myReaction: ReactionKind?
    public var commentCount: Int
    public var latestComments: [CommentDTO]

    public init(
        id: UUID,
        authorID: UUID,
        authorDisplayName: String?,
        isMine: Bool,
        text: String?,
        sequence: Int64,
        createdAt: Date,
        updatedAt: Date,
        photos: [RecadoPhotoRefDTO],
        mentions: [MentionDTO],
        reactions: [ReactionCountDTO],
        myReaction: ReactionKind?,
        commentCount: Int,
        latestComments: [CommentDTO]
    ) {
        self.id = id
        self.authorID = authorID
        self.authorDisplayName = authorDisplayName
        self.isMine = isMine
        self.text = text
        self.sequence = sequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.photos = photos
        self.mentions = mentions
        self.reactions = reactions
        self.myReaction = myReaction
        self.commentCount = commentCount
        self.latestComments = latestComments
    }
}

/// Página do feed do mural (MURAL-05) — paginação por cursor (`sequence`, nunca
/// deslocamento numérico, 02-RESEARCH.md Pitfall 2). `nextCursor` é `nil` quando não há
/// mais páginas.
public struct RecadoFeedPage: Codable, Sendable {
    public var items: [RecadoDTO]
    public var nextCursor: Int64?

    public init(items: [RecadoDTO], nextCursor: Int64?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Corpo de `POST /api/v1/recados`.
///
/// Deliberadamente não carrega `authorId` nem `householdId`: ambos são resolvidos no
/// servidor a partir do JWT verificado e do contexto de sessão — um campo que não existe no
/// tipo não pode ser lido por engano, mesmo que o corpo JSON bruto do request contenha essas
/// chaves (zero-trust do front-end, `.claude/CLAUDE.md`).
public struct CreateRecadoRequest: Codable, Sendable {
    public var text: String?

    public init(text: String?) {
        self.text = text
    }
}

/// Corpo de `PATCH /api/v1/recados/:recadoID`.
public struct UpdateRecadoRequest: Codable, Sendable {
    public var text: String?

    public init(text: String?) {
        self.text = text
    }
}

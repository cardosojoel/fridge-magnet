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
    /// Data de exibição da foto (D-11, plano 02-08) — **já resolvida pelo servidor** em
    /// `RecadoController.resolvedCapturedAt`: a data de captura do arquivo quando havia
    /// metadado plausível, senão a data de criação da linha. Não opcional de propósito:
    /// a ausência de metadado já foi resolvida na borda da DTO, então nenhuma view precisa
    /// de um `??` de fallback (02-ADDENDUM-RESEARCH.md Pitfall 6). O valor padrão no `init`
    /// existe só para os pontos de construção anteriores a este campo (fixtures de teste
    /// das ondas 1-4) — o servidor sempre passa explicitamente.
    public var capturedAt: Date

    public init(id: UUID, position: Int, capturedAt: Date = Date()) {
        self.id = id
        self.position = position
        self.capturedAt = capturedAt
    }
}

/// Localização opcional de um recado (D-12, plano 02-08) — um rótulo e uma coordenada,
/// nada além disso.
///
/// Duas propriedades a definem:
/// - É um **instantâneo**: a coordenada é capturada no momento de compor (busca MapKit no
///   aparelho) e nunca mais reconsultada — nada de re-geocodificar a cada render
///   (02-ADDENDUM-RESEARCH.md, Anti-Patterns).
/// - `text` é o rótulo que a pessoa escolheu, que pode ter sido editado à mão depois de
///   escolher o pino (Open Question 2) — nunca é derivado de volta da coordenada.
public struct RecadoLocationDTO: Codable, Sendable {
    public var text: String
    public var lat: Double
    public var lng: Double

    public init(text: String, lat: Double, lng: Double) {
        self.text = text
        self.lat = lat
        self.lng = lng
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
/// `kind`, nunca lista cada reação individualmente. `Equatable` (aditivo, plano 02-07) — a
/// alternância otimista do cliente precisa comparar resumos completos (reversão exata em
/// falha, prova de teste).
public struct ReactionCountDTO: Codable, Sendable, Equatable {
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
    /// Instante da fixação (D-14, plano 02-11) — nulo é "não fixado". Um único campo
    /// carrega o booleano ("está fixado?") E a chave de ordenação do bloco de fixados
    /// (mais recente primeiro): o cliente nunca precisa de um segundo campo derivado.
    public var pinnedAt: Date?
    /// Instante do arquivamento (D-15, plano 02-11) — nulo é "não arquivado". No feed é
    /// sempre nulo por construção (recado arquivado não aparece); só a listagem de
    /// arquivados do admin devolve valor preenchido.
    public var archivedAt: Date?
    /// D-14: o requisitante pode fixar/desafixar ESTE recado — verdadeiro para o autor ou
    /// para quem tem papel de admin, calculado no servidor no mesmo ponto que `isMine`.
    /// Três sinais e não um (`canPin`/`canArchive`/`canUnarchive`): D-14 e D-15 declaram
    /// regras diferentes, e colapsá-las gravaria no cliente a suposição de que andam
    /// juntas. Esconder um item de menu com base nele é conveniência de interface — a
    /// linha de defesa é a checagem do handler no servidor.
    public var canPin: Bool
    /// D-15: o requisitante pode arquivar ESTE recado — autor ou admin, calculado no
    /// servidor. Mesma nota de `canPin`: sinal de interface, nunca a linha de defesa.
    public var canArchive: Bool
    /// D-15: o requisitante pode desarquivar — estritamente admin (o autor não-admin que
    /// arquivou o próprio recado NÃO o recupera sozinho, decisão explícita do usuário).
    /// Calculado no servidor; sinal de interface, nunca a linha de defesa.
    public var canUnarchive: Bool
    /// Localização opcional do recado (D-12, plano 02-08) — ausente é ausente: o servidor
    /// só devolve o objeto quando as três colunas estão preenchidas, nunca um objeto vazio
    /// ou com coordenada zero.
    public var location: RecadoLocationDTO?

    // Os cinco parâmetros novos entram com valor padrão de propósito: `RecadoDTO` é
    // construído em dezenas de pontos de teste (backend e cliente, ondas 1 a 4) e um
    // parâmetro obrigatório novo quebraria a compilação de todos eles — mesmo precedente
    // dos campos aditivos anteriores. O servidor sempre passa os cinco explicitamente; o
    // padrão existe só para os pontos de construção antigos.
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
        latestComments: [CommentDTO],
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil,
        canPin: Bool = false,
        canArchive: Bool = false,
        canUnarchive: Bool = false,
        location: RecadoLocationDTO? = nil
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
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.canPin = canPin
        self.canArchive = canArchive
        self.canUnarchive = canUnarchive
        self.location = location
    }
}

/// Página do feed do mural (MURAL-05) — paginação por cursor (`sequence`, nunca
/// deslocamento numérico, 02-RESEARCH.md Pitfall 2). `nextCursor` é `nil` quando não há
/// mais páginas.
public struct RecadoFeedPage: Codable, Sendable {
    public var items: [RecadoDTO]
    public var nextCursor: Int64?
    /// Bloco de fixados (D-14, plano 02-11) — FORA da paginação por cursor: só vem
    /// preenchido na primeira página (requisição sem cursor) e é vazio nas seguintes.
    /// Recados fixados são excluídos de `items` (o fluxo cronológico), de modo que nenhum
    /// recado é renderizado duas vezes na mesma resposta. Ordenado do mais recentemente
    /// fixado para o mais antigo.
    public var pinned: [RecadoDTO]

    public init(items: [RecadoDTO], nextCursor: Int64?, pinned: [RecadoDTO] = []) {
        self.items = items
        self.nextCursor = nextCursor
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor
        case pinned
    }

    // Init manual (mesma razão de `CreateRecadoRequest.init(from:)`): `pinned` ausente do
    // JSON decodifica como coleção vazia, não como erro. Assimetria deliberada com
    // `RecadoDTO`, que NÃO ganha decodificação tolerante — o critério é o custo da falha,
    // não a elegância: um cliente novo contra um servidor ainda não atualizado renderizaria
    // tela preta no feed (a primeira tela do app), e o feed é a única resposta em que um
    // campo de coleção pode legitimamente não existir. Dentro de um `RecadoDTO` que o
    // servidor já mandou, todos os campos vêm juntos: os três sinais de permissão são tão
    // obrigatórios quanto `isMine`, decodificado sem tolerância desde o plano 02-01.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try container.decode([RecadoDTO].self, forKey: .items)
        self.nextCursor = try container.decodeIfPresent(Int64.self, forKey: .nextCursor)
        self.pinned = try container.decodeIfPresent([RecadoDTO].self, forKey: .pinned) ?? []
    }
}

/// Corpo de `POST /api/v1/recados`.
///
/// Deliberadamente não carrega `authorId` nem `householdId`: ambos são resolvidos no
/// servidor a partir do JWT verificado e do contexto de sessão — um campo que não existe no
/// tipo não pode ser lido por engano, mesmo que o corpo JSON bruto do request contenha essas
/// chaves (zero-trust do front-end, `.claude/CLAUDE.md`).
///
/// `mentionedUserIDs` carrega os identificadores de membro escolhidos num seletor
/// estruturado (D-06) — o servidor nunca faz varredura de texto procurando `@nome`, então a
/// ambiguidade de digitação deixa de existir por construção e a marcação sempre aponta para
/// a pessoa certa. A lista NÃO carrega estado de conclusão: D-04 fixa a marcação como
/// social, sem "resolvido/pendente".
public struct CreateRecadoRequest: Codable, Sendable {
    public var text: String?
    public var mentionedUserIDs: [UUID]
    /// Localização opcional (D-12, plano 02-08) — chave ausente do JSON é localização
    /// ausente, nunca erro. Os TRÊS lugares (propriedade, `CodingKeys`, `init(from:)`)
    /// carregam o campo: um corpo real que não passasse pelo `init(from:)` atualizado
    /// decodificaria a localização como nula silenciosamente.
    public var location: RecadoLocationDTO?

    public init(text: String?, mentionedUserIDs: [UUID] = [], location: RecadoLocationDTO? = nil) {
        self.text = text
        self.mentionedUserIDs = mentionedUserIDs
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case mentionedUserIDs
        case location
    }

    // Init manual (não synthesized): `mentionedUserIDs` precisa decodificar como `[]` quando
    // a chave está AUSENTE do JSON (um cliente anterior a este plano, ou qualquer chamador
    // que não marque ninguém, nunca envia a chave) — o `= []` do init acima só cobre
    // construção em Swift, nunca decodificação de um corpo de request real.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.mentionedUserIDs = try container.decodeIfPresent([UUID].self, forKey: .mentionedUserIDs) ?? []
        self.location = try container.decodeIfPresent(RecadoLocationDTO.self, forKey: .location)
    }
}

/// Corpo de `PATCH /api/v1/recados/:recadoID`.
///
/// `mentionedUserIDs` substitui o conjunto de menções do recado (não soma) — ver
/// `CreateRecadoRequest.mentionedUserIDs` para o mesmo contrato de seletor estruturado
/// (D-06) e de marcação sem estado (D-04).
public struct UpdateRecadoRequest: Codable, Sendable {
    public var text: String?
    public var mentionedUserIDs: [UUID]
    /// Localização opcional (D-12) — semântica de SUBSTITUIÇÃO, igual à de
    /// `mentionedUserIDs`: editar sem enviar localização limpa a localização do recado,
    /// nunca a preserva. Mesmo contrato de três lugares de `CreateRecadoRequest.location`.
    public var location: RecadoLocationDTO?

    public init(text: String?, mentionedUserIDs: [UUID] = [], location: RecadoLocationDTO? = nil) {
        self.text = text
        self.mentionedUserIDs = mentionedUserIDs
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case mentionedUserIDs
        case location
    }

    /// Mesma razão de `CreateRecadoRequest.init(from:)`: `mentionedUserIDs` ausente no JSON
    /// decodifica como `[]`, não como erro.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.mentionedUserIDs = try container.decodeIfPresent([UUID].self, forKey: .mentionedUserIDs) ?? []
        self.location = try container.decodeIfPresent(RecadoLocationDTO.self, forKey: .location)
    }
}

/// Corpo de `PUT /api/v1/recados/:recadoID/reactions`.
///
/// `kind` é o enum fechado `ReactionKind` (D-07): um valor fora do conjunto falha na
/// decodificação automaticamente (400), sem nenhuma comparação de string escrita à mão. O
/// tipo deliberadamente não carrega `userId` nem `recadoId` — ambos resolvidos no servidor a
/// partir do JWT verificado e do parâmetro de rota, mesmo motivo de
/// `DeviceRegistrationRequest`.
public struct SetReactionRequest: Codable, Sendable {
    public var kind: ReactionKind

    public init(kind: ReactionKind) {
        self.kind = kind
    }
}

/// Resposta de `PUT /api/v1/recados/:recadoID/reactions` — mesmo formato que
/// `RecadoDTO.reactions`/`RecadoDTO.myReaction` usam, calculado pelo mesmo helper
/// (`RecadoController.reactionSummary`) para o feed e a resposta de reação nunca divergirem.
public struct RecadoReactionSummaryDTO: Codable, Sendable {
    public var reactions: [ReactionCountDTO]
    public var myReaction: ReactionKind?

    public init(reactions: [ReactionCountDTO], myReaction: ReactionKind?) {
        self.reactions = reactions
        self.myReaction = myReaction
    }
}

/// Corpo de `POST /api/v1/recados/:recadoID/comments`.
///
/// Deliberadamente não carrega `authorId` nem `householdId` (mesmo motivo de
/// `DeviceRegistrationRequest`/`CreateRecadoRequest`): ambos resolvidos no servidor a partir
/// do JWT verificado e do contexto de sessão. `mentionedUserIDs` usa o mesmo seletor
/// estruturado do recado (D-06) — marcar dentro de um comentário notifica pelo mesmo
/// mecanismo do recado (D-09).
public struct CreateCommentRequest: Codable, Sendable {
    public var text: String
    public var mentionedUserIDs: [UUID]

    public init(text: String, mentionedUserIDs: [UUID] = []) {
        self.text = text
        self.mentionedUserIDs = mentionedUserIDs
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case mentionedUserIDs
    }

    // Mesma razão de CreateRecadoRequest.init(from:): mentionedUserIDs ausente no JSON
    // decodifica como [], não como erro.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decode(String.self, forKey: .text)
        self.mentionedUserIDs = try container.decodeIfPresent([UUID].self, forKey: .mentionedUserIDs) ?? []
    }
}


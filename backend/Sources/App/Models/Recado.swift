import Fluent
import Foundation

/// Um recado do mural (MURAL-01, MURAL-05) — escopado por `household_id` sob RLS
/// `ENABLE`+`FORCE` (`CreateRecadoSchema`), mesmo espírito de `households`/`device_tokens`.
/// `text` é opcional (D-01: um recado pode ser só texto, só foto(s), ou os dois — a regra
/// "texto OU foto" é do compose, não desta camada). `sequence` é o cursor monotônico de
/// paginação (02-RESEARCH.md Pattern 1/Alternatives Considered), lido de
/// `recados_sequence_seq` pelo controller antes do insert.
final class Recado: Model, @unchecked Sendable {
    static let schema = "recados"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @Parent(key: "author_id")
    var author: User

    @OptionalField(key: "text")
    var text: String?

    @Field(key: "sequence")
    var sequence: Int64

    /// Instante de fixação (D-14, plano 02-11) — `nil` é "não fixado". Coluna aditiva de
    /// `AddRecadoPinAndArchive`; ordena SÓ o bloco de fixados (mais recente primeiro). A
    /// ordenação do fluxo cronológico do feed continua sendo `sequence`, nunca esta coluna.
    /// Atribuída por propriedade pelos handlers (`pin`/`unpin`), nunca pelo `init`.
    @OptionalField(key: "pinned_at")
    var pinnedAt: Date?

    /// Instante de arquivamento (D-15, plano 02-11) — `nil` é "não arquivado". Coluna
    /// aditiva de `AddRecadoPinAndArchive`; um recado com valor aqui é invisível no feed e
    /// em toda rota de recado por id (filtro padrão de `loadRecadoOrNotFound`). A ordenação
    /// do fluxo do feed continua sendo `sequence`, nunca esta coluna — desarquivar devolve
    /// o recado à posição cronológica natural dele.
    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    /// Rótulo da localização opcional do recado (D-12, plano 02-08) — coluna aditiva de
    /// `AddPhotoCapturedAtAndRecadoLocation`. As três colunas de localização andam juntas:
    /// ou as três estão preenchidas (localização presente) ou as três são nulas (ausente) —
    /// invariante mantida por `RecadoController.normalizeLocation`, nunca pelo schema.
    /// Atribuída por propriedade pelos handlers (`create`/`update`), nunca pelo `init` —
    /// mesmo padrão de `pinnedAt`/`archivedAt`.
    @OptionalField(key: "location_text")
    var locationText: String?

    /// Latitude do instantâneo de localização (D-12) — ver `locationText`.
    @OptionalField(key: "location_lat")
    var locationLat: Double?

    /// Longitude do instantâneo de localização (D-12) — ver `locationText`.
    @OptionalField(key: "location_lng")
    var locationLng: Double?

    /// Instante do EVENTO do lembrete opcional (D-16, plano 02-14) — `nil` é "sem
    /// lembrete". Coluna aditiva de `AddRecadoEventReminder`. Anda SEMPRE junto de
    /// `remindOffsetSeconds`: ou as duas colunas estão preenchidas (lembrete presente) ou
    /// as duas são nulas (ausente) — invariante mantida pelo controller
    /// (`normalizeReminder` na escrita, `buildDTO` na leitura), nunca pelo schema, mesmo
    /// precedente das três colunas de localização. Atribuída por propriedade pelos
    /// handlers (`create`/`update`), nunca pelo `init`.
    @OptionalField(key: "event_at")
    var eventAt: Date?

    /// Antecedência do lembrete em SEGUNDOS antes de `eventAt` (D-16) — `nil` é "sem
    /// lembrete"; ver `eventAt` para a invariante de par indivisível. Sempre um valor do
    /// conjunto fechado `ReminderOffset` (validado por `normalizeReminder` na borda HTTP,
    /// nunca aqui), nunca negativa. Atribuída por propriedade pelos handlers, nunca pelo
    /// `init`.
    @OptionalField(key: "remind_offset_seconds")
    var remindOffsetSeconds: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        authorID: User.IDValue,
        text: String?,
        sequence: Int64
    ) {
        self.id = id
        self.$household.id = householdID
        self.$author.id = authorID
        self.text = text
        self.sequence = sequence
    }
}

/// Uma foto do carrossel de um recado (D-01, D-02 — até 10 por recado, validado na
/// aplicação, não no schema). `object_key` é a chave opaca do objeto no armazenamento
/// (`ObjectStorageClient`) — quem monta a chave e assina a URL de download é o
/// `RecadoPhotoController` do plano 02-04; este modelo só guarda a referência.
/// `unique(recado_id, position)` e `unique(object_key)` no schema garantem posição sem
/// colisão dentro do carrossel e chave de objeto nunca reaproveitada.
final class RecadoPhoto: Model, @unchecked Sendable {
    static let schema = "recado_photos"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @Parent(key: "recado_id")
    var recado: Recado

    @Field(key: "object_key")
    var objectKey: String

    @Field(key: "position")
    var position: Int

    @Field(key: "content_type")
    var contentType: String

    @Field(key: "byte_size")
    var byteSize: Int64

    /// Data de captura declarada pelo cliente no confirm (D-11, plano 02-08) — coluna
    /// aditiva de `AddPhotoCapturedAtAndRecadoLocation`, `nil` quando o arquivo não tinha
    /// metadado (ou o valor era implausível, ver `RecadoPhotoController.plausibleCapturedAt`).
    /// É metadado **só de exibição**: o servidor nunca viu os bytes e não tem como
    /// verificá-lo, então nunca entra em decisão de autorização, nunca em filtro e nunca em
    /// ordenação — a ordem do feed é `sequence`, a do carrossel é `position` (T-02-56).
    @OptionalField(key: "captured_at")
    var capturedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        recadoID: Recado.IDValue,
        objectKey: String,
        position: Int,
        contentType: String,
        byteSize: Int64,
        capturedAt: Date? = nil
    ) {
        self.id = id
        self.$household.id = householdID
        self.$recado.id = recadoID
        self.objectKey = objectKey
        self.position = position
        self.contentType = contentType
        self.byteSize = byteSize
        self.capturedAt = capturedAt
    }
}

/// Reação de um membro a um recado (D-07, D-07b) — `kind` guarda o `rawValue` cru do
/// `ReactionKind` fechado de `FridgeMagnetShared`, string crua na coluna e validada pelo enum
/// compartilhado na borda HTTP, igual a `DeviceToken.platform`/`environment`.
/// `unique(recado_id, user_id)` no schema é a constraint de D-07b: uma reação ativa por
/// pessoa por recado, trocar substitui em vez de acumular.
final class RecadoReaction: Model, @unchecked Sendable {
    static let schema = "recado_reactions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @Parent(key: "recado_id")
    var recado: Recado

    @Parent(key: "user_id")
    var user: User

    @Field(key: "kind")
    var kind: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        recadoID: Recado.IDValue,
        userID: User.IDValue,
        kind: String
    ) {
        self.id = id
        self.$household.id = householdID
        self.$recado.id = recadoID
        self.$user.id = userID
        self.kind = kind
    }
}

/// Comentário em lista plana cronológica (D-08 — sem resposta aninhada/thread, sem coluna
/// de comentário-pai por schema).
final class RecadoComment: Model, @unchecked Sendable {
    static let schema = "recado_comments"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @Parent(key: "recado_id")
    var recado: Recado

    @Parent(key: "author_id")
    var author: User

    @Field(key: "text")
    var text: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        recadoID: Recado.IDValue,
        authorID: User.IDValue,
        text: String
    ) {
        self.id = id
        self.$household.id = householdID
        self.$recado.id = recadoID
        self.$author.id = authorID
        self.text = text
    }
}

/// Uma @menção — marcação social sem estado (D-04), nunca uma tarefa com
/// resolvido/pendente. Exatamente um pai (`recado` OU `comment`, nunca os dois, nunca
/// nenhum — `CHECK recado_mentions_one_parent` no schema); a coluna do outro fica `nil`.
/// D-09: uma menção dentro de um comentário usa `comment`, uma menção no recado em si usa
/// `recado`.
final class RecadoMention: Model, @unchecked Sendable {
    static let schema = "recado_mentions"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "household_id")
    var household: Household

    @OptionalParent(key: "recado_id")
    var recado: Recado?

    @OptionalParent(key: "comment_id")
    var comment: RecadoComment?

    @Parent(key: "mentioned_user_id")
    var mentionedUser: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        householdID: Household.IDValue,
        recadoID: Recado.IDValue? = nil,
        commentID: RecadoComment.IDValue? = nil,
        mentionedUserID: User.IDValue
    ) {
        self.id = id
        self.$household.id = householdID
        self.$recado.id = recadoID
        self.$comment.id = commentID
        self.$mentionedUser.id = mentionedUserID
    }
}

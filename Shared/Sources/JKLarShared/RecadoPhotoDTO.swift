import Foundation

/// DTOs de presign/confirm/leitura de fotos do carrossel de um recado (MURAL-01, D-01, D-02) —
/// plano 02-04. Arquivo próprio (não `RecadoDTO.swift`, que pertence a outros planos desta
/// fase).
///
/// Nenhum destes tipos carrega `authorId`/`householdId`/posição escolhida pelo cliente:
/// autoria e casa são sempre resolvidas no servidor a partir do JWT/contexto de sessão, e
/// `position` é sempre atribuída pelo servidor na ordem em que as chaves chegam ao confirm —
/// zero-trust do front-end, `.claude/CLAUDE.md`.

/// Um slot de upload pedido pelo cliente — tipo e tamanho declarados, validados contra uma
/// lista fechada e um teto no servidor antes de qualquer URL ser assinada.
public struct PhotoUploadSlotRequest: Codable, Sendable {
    public var contentType: String
    public var byteSize: Int

    public init(contentType: String, byteSize: Int) {
        self.contentType = contentType
        self.byteSize = byteSize
    }
}

/// Corpo de `POST /api/v1/recados/:recadoID/photos/presign`.
public struct PresignPhotoUploadRequest: Codable, Sendable {
    public var slots: [PhotoUploadSlotRequest]

    public init(slots: [PhotoUploadSlotRequest]) {
        self.slots = slots
    }
}

/// Uma URL assinada de PUT — de curta duração (10 min), nunca cacheada pelo cliente além do
/// upload imediato.
public struct PresignedPhotoUploadDTO: Codable, Sendable {
    public var objectKey: String
    public var uploadURL: URL
    public var expiresAt: Date

    public init(objectKey: String, uploadURL: URL, expiresAt: Date) {
        self.objectKey = objectKey
        self.uploadURL = uploadURL
        self.expiresAt = expiresAt
    }
}

/// Resposta de `POST /api/v1/recados/:recadoID/photos/presign` — uma entrada por slot pedido,
/// na mesma ordem.
public struct PresignPhotoUploadResponse: Codable, Sendable {
    public var uploads: [PresignedPhotoUploadDTO]

    public init(uploads: [PresignedPhotoUploadDTO]) {
        self.uploads = uploads
    }
}

/// Corpo de `POST /api/v1/recados/:recadoID/photos/confirm` — as chaves que o cliente diz
/// terem sido enviadas com sucesso ao bucket. O servidor revalida cada uma (formato + `HEAD`
/// no armazenamento) antes de gravar qualquer linha.
public struct ConfirmPhotoUploadRequest: Codable, Sendable {
    public var objectKeys: [String]

    public init(objectKeys: [String]) {
        self.objectKeys = objectKeys
    }
}

/// Uma foto confirmada — sem URL (a leitura de URL de download é uma chamada em lote própria,
/// `PhotoDownloadURLsRequest`).
public struct ConfirmedPhotoDTO: Codable, Sendable {
    public var id: UUID
    public var position: Int

    public init(id: UUID, position: Int) {
        self.id = id
        self.position = position
    }
}

/// Corpo de `POST /api/v1/recados/photos/urls` — ids de recados de uma página do feed, numa
/// única chamada em lote (nunca uma URL assinada embutida no JSON do feed, que o cliente
/// poderia cachear em disco).
public struct PhotoDownloadURLsRequest: Codable, Sendable {
    public var recadoIDs: [UUID]

    public init(recadoIDs: [UUID]) {
        self.recadoIDs = recadoIDs
    }
}

/// Uma URL assinada de GET — de duração maior que o PUT (1h), mas ainda temporária.
public struct PhotoDownloadDTO: Codable, Sendable {
    public var id: UUID
    public var position: Int
    public var downloadURL: URL
    public var expiresAt: Date

    public init(id: UUID, position: Int, downloadURL: URL, expiresAt: Date) {
        self.id = id
        self.position = position
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
    }
}

/// Fotos de um recado, agrupadas — um recado de outra casa simplesmente não aparece nesta
/// lista (a RLS já o tornou inexistente para o requisitante; a rota nunca confirma isso com um
/// 403).
public struct RecadoPhotoURLsDTO: Codable, Sendable {
    public var recadoID: UUID
    public var photos: [PhotoDownloadDTO]

    public init(recadoID: UUID, photos: [PhotoDownloadDTO]) {
        self.recadoID = recadoID
        self.photos = photos
    }
}

/// Resposta de `POST /api/v1/recados/photos/urls`.
public struct PhotoDownloadURLsResponse: Codable, Sendable {
    public var recados: [RecadoPhotoURLsDTO]

    public init(recados: [RecadoPhotoURLsDTO]) {
        self.recados = recados
    }
}

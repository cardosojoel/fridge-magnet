import Fluent
import FluentSQL
import Foundation
import FridgeMagnetShared
import Vapor

/// `POST /api/v1/recados/:recadoID/photos/presign`, `POST /api/v1/recados/:recadoID/photos/confirm`,
/// `POST /api/v1/recados/photos/urls`, `DELETE /api/v1/recados/:recadoID/photos/:photoID` —
/// plano 02-04 (MURAL-01 parte foto, D-01, D-02).
///
/// Controller separado de `RecadoController` de propósito: superfície de autorização e de erro
/// distinta, e é o que permite este plano rodar na mesma onda que o plano 02-02 sem os dois
/// disputarem o mesmo arquivo.
///
/// Ordem obrigatória em `presign`/`confirm`/`deletePhoto` — **autorizar no Postgres antes de
/// assinar/apagar**: carregar o recado sob RLS (ausente → 404, nunca 403 — casa alheia é
/// invisível) → checar autoria (D-03, sem exceção de moderação para admin) → só então falar
/// com `req.application.objectStorageClient`. Esta ordem é a única garantia de isolamento
/// entre casas nesta camada: armazenamento de objeto não tem RLS própria
/// (`02-RESEARCH.md` §Summary, `02-COVERAGE.md`).
struct RecadoPhotoController: RouteCollection {
    /// D-02 — teto de fotos por recado, reforçado no servidor independentemente do que o
    /// cliente pediu (o limite visual do compose é conforto de interface, o servidor não
    /// confia nele — `02-RESEARCH.md` §Security Domain V5).
    static let maxPhotosPerRecado = 10

    /// 25 MB por foto — `02-RESEARCH.md` §Security Domain V5.
    static let maxPhotoBytes = 25 * 1024 * 1024

    /// Lista fechada de tipos de imagem aceitos, e a extensão que cada um vira na chave do
    /// objeto — nunca uma extensão derivada do nome de arquivo enviado pelo cliente.
    static let allowedContentTypes: [String: String] = [
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/heic": "heic",
    ]

    /// Expiração da URL de PUT — curta, porque é uma credencial temporária de escrita
    /// (`02-RESEARCH.md` §Security Domain V6).
    static let putExpirySeconds: TimeInterval = 600

    /// Expiração da URL de GET — mais longa que o PUT (a leitura é reusada durante a
    /// navegação no feed), ainda assim temporária.
    static let getExpirySeconds: TimeInterval = 3600

    func boot(routes: any RoutesBuilder) throws {
        let recados = routes.grouped("api", "v1", "recados")
        let authenticated = recados.grouped(SessionAuthenticator(), User.guardMiddleware())
        let scoped = authenticated.grouped(HouseholdContextMiddleware())

        scoped.post(":recadoID", "photos", "presign", use: presign)
        scoped.post(":recadoID", "photos", "confirm", use: confirm)
        scoped.post("photos", "urls", use: downloadURLs)
        scoped.delete(":recadoID", "photos", ":photoID", use: deletePhoto)
    }

    // MARK: POST /api/v1/recados/:recadoID/photos/presign

    @Sendable
    func presign(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let recadoID = req.parameters.get("recadoID", as: UUID.self) else {
            return try Self.errorResponse(code: .validation, message: "recadoID inválido.", status: .badRequest)
        }

        // 1. Carregar o recado sob RLS — ausente aqui significa "de outra casa" (RLS já
        //    escopou a consulta), então 404, nunca 403 (a rota não pode confirmar a
        //    existência de um recado alheio).
        guard let recado = try await Recado.query(on: req.scopedDB)
            .filter(\.$id == recadoID)
            .first()
        else {
            throw Abort(.notFound)
        }

        // 2. Só então checar autoria (D-03, sem exceção para admin).
        guard recado.$author.id == userID else {
            return try Self.errorResponse(
                code: .notAuthor,
                message: "Só o autor pode adicionar fotos a este recado.",
                status: .forbidden
            )
        }

        let body = try req.content.decode(PresignPhotoUploadRequest.self)

        let existingCount = try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .count()
        guard existingCount + body.slots.count <= Self.maxPhotosPerRecado else {
            return try Self.errorResponse(
                code: .photoLimitExceeded,
                message: "Este recado já atingiu o limite de 10 fotos.",
                status: .badRequest
            )
        }

        var uploads: [PresignedPhotoUploadDTO] = []
        uploads.reserveCapacity(body.slots.count)

        // 3. Só agora, com autorização e teto resolvidos, falar com o armazenamento.
        for slot in body.slots {
            guard let ext = Self.allowedContentTypes[slot.contentType] else {
                return try Self.errorResponse(
                    code: .validation,
                    message: "Tipo de foto não suportado.",
                    status: .badRequest
                )
            }
            guard slot.byteSize > 0, slot.byteSize <= Self.maxPhotoBytes else {
                return try Self.errorResponse(
                    code: .validation,
                    message: "Tamanho de foto inválido.",
                    status: .badRequest
                )
            }

            // Sufixo sempre um UUID novo por foto — duas chaves da mesma requisição nunca
            // são deriváveis uma da outra.
            let objectKey = RecadoPhotoObjectKey.make(
                householdID: context.householdID,
                recadoID: recadoID,
                ext: ext
            )
            let uploadURL = try await req.application.objectStorageClient.presignedPutURL(
                key: objectKey,
                expiresIn: Self.putExpirySeconds
            )
            uploads.append(PresignedPhotoUploadDTO(
                objectKey: objectKey,
                uploadURL: uploadURL,
                expiresAt: Date().addingTimeInterval(Self.putExpirySeconds)
            ))
        }

        return try Self.jsonResponse(PresignPhotoUploadResponse(uploads: uploads), status: .ok)
    }

    // MARK: POST /api/v1/recados/:recadoID/photos/confirm

    @Sendable
    func confirm(req: Request) async throws -> Response {
        guard let context = req.householdContext else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard let recadoID = req.parameters.get("recadoID", as: UUID.self) else {
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
                message: "Só o autor pode confirmar fotos deste recado.",
                status: .forbidden
            )
        }

        let body = try req.content.decode(ConfirmPhotoUploadRequest.self)

        // `capturedAtByKey` é montado ANTES de qualquer filtragem, chaveado por `objectKey`
        // — o filtro de retentativa idempotente (`newKeys`, abaixo) não tem como deslocar
        // uma data para a foto errada, que é exatamente o furo de um array paralelo
        // indexado por posição (02-ADDENDUM-RESEARCH.md Pitfall 3). Chave repetida no mesmo
        // corpo fica com a última ocorrência (regra explícita, variante de `Dictionary` que
        // resolve colisão — nunca a que aborta em chave duplicada).
        let capturedAtByKey = Dictionary(
            body.photos.map { ($0.objectKey, Self.plausibleCapturedAt($0.capturedAt)) },
            uniquingKeysWith: { _, last in last }
        )

        // Cada chave precisa bater com o formato esperado (casa + recado corretos, sufixo
        // UUID válido) ANTES de qualquer consulta ao armazenamento — uma chave de outro
        // recado, ou inventada, nunca chega a virar consulta (T-02-27: sem isso o confirm
        // seria um oráculo de existência de objeto alheio).
        for key in body.photos.map(\.objectKey) {
            guard RecadoPhotoObjectKey.validate(key, householdID: context.householdID, recadoID: recadoID) else {
                return try Self.errorResponse(
                    code: .validation,
                    message: "Chave de foto inválida para este recado.",
                    status: .badRequest
                )
            }
        }

        let existingPhotos = try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$recado.$id == recadoID)
            .all()
        let existingKeys = Set(existingPhotos.map(\.objectKey))

        // Chave já confirmada antes é ignorada em silêncio — confirm repetido não duplica
        // linha (a constraint unique(object_key) é a rede de segurança, não o mecanismo
        // primário).
        let newKeys = body.photos.map(\.objectKey).filter { !existingKeys.contains($0) }

        guard existingPhotos.count + newKeys.count <= Self.maxPhotosPerRecado else {
            return try Self.errorResponse(
                code: .photoLimitExceeded,
                message: "Este recado já atingiu o limite de 10 fotos.",
                status: .badRequest
            )
        }

        guard !newKeys.isEmpty else {
            // Nada de novo para confirmar (todas as chaves já existiam) — idempotente,
            // devolve o estado atual sem gravar nada. `capturedAt` sempre pelo helper
            // único de fallback — duas cópias da regra divergiriam (Pitfall 6).
            let dtos = try existingPhotos
                .sorted { $0.position < $1.position }
                .map {
                    ConfirmedPhotoDTO(
                        id: try $0.requireID(),
                        position: $0.position,
                        capturedAt: RecadoController.resolvedCapturedAt($0)
                    )
                }
            return try Self.jsonResponse(dtos, status: .created)
        }

        // Verificação de chegada — tudo ou nada. O backend nunca viu os bytes; sem esta
        // checagem, uma falha de rede no meio do upload produziria linha de foto apontando
        // para objeto inexistente e carrossel com imagem quebrada (Pitfall 3). `content_type`/
        // `byte_size` vêm sempre daqui (do armazenamento), nunca do corpo do request — que
        // nem carrega esses campos (T-02-36).
        var metadataByKey: [String: ObjectMetadata] = [:]
        for key in newKeys {
            guard let metadata = try await req.application.objectStorageClient.objectMetadata(key: key) else {
                return try Self.errorResponse(
                    code: .photoNotUploaded,
                    message: "Uma ou mais fotos ainda não chegaram ao armazenamento.",
                    status: .conflict
                )
            }
            metadataByKey[key] = metadata
        }

        var nextPosition = (existingPhotos.map(\.position).max().map { $0 + 1 }) ?? 0
        var savedPhotos: [RecadoPhoto] = []
        for key in newKeys {
            guard let metadata = metadataByKey[key] else {
                // Inalcançável: todo `newKeys` passou pelo laço de verificação acima, que só
                // segue adiante depois de popular `metadataByKey` para cada chave.
                throw Abort(.internalServerError)
            }
            let photo = RecadoPhoto(
                householdID: context.householdID,
                recadoID: recadoID,
                objectKey: key,
                position: nextPosition,
                contentType: metadata.contentType,
                byteSize: metadata.byteSize,
                // Achata o opcional duplo: chave ausente do dicionário E valor nulo
                // significam a mesma coisa — sem metadado de captura.
                capturedAt: capturedAtByKey[key] ?? nil
            )
            try await photo.save(on: req.scopedDB)
            savedPhotos.append(photo)
            nextPosition += 1
        }

        let dtos = try savedPhotos.map {
            ConfirmedPhotoDTO(
                id: try $0.requireID(),
                position: $0.position,
                capturedAt: RecadoController.resolvedCapturedAt($0)
            )
        }
        return try Self.jsonResponse(dtos, status: .created)
    }

    // MARK: POST /api/v1/recados/photos/urls

    @Sendable
    func downloadURLs(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }

        let body = try req.content.decode(PhotoDownloadURLsRequest.self)
        guard !body.recadoIDs.isEmpty else {
            return try Self.jsonResponse(PhotoDownloadURLsResponse(recados: []), status: .ok)
        }

        // A RLS já elimina recado de outra casa da consulta — um id alheio simplesmente não
        // produz linha e não aparece na resposta (sem 403, para a rota nunca confirmar
        // existência de recado alheio).
        let photos = try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$recado.$id ~~ body.recadoIDs)
            .sort(\.$position, .ascending)
            .all()

        var photosByRecado: [UUID: [RecadoPhoto]] = [:]
        for photo in photos {
            photosByRecado[photo.$recado.id, default: []].append(photo)
        }

        var recadosResponse: [RecadoPhotoURLsDTO] = []
        for recadoID in body.recadoIDs {
            guard let recadoPhotos = photosByRecado[recadoID], !recadoPhotos.isEmpty else { continue }
            var downloadDTOs: [PhotoDownloadDTO] = []
            downloadDTOs.reserveCapacity(recadoPhotos.count)
            for photo in recadoPhotos {
                let downloadURL = try await req.application.objectStorageClient.presignedGetURL(
                    key: photo.objectKey,
                    expiresIn: Self.getExpirySeconds
                )
                downloadDTOs.append(PhotoDownloadDTO(
                    id: try photo.requireID(),
                    position: photo.position,
                    downloadURL: downloadURL,
                    expiresAt: Date().addingTimeInterval(Self.getExpirySeconds)
                ))
            }
            recadosResponse.append(RecadoPhotoURLsDTO(recadoID: recadoID, photos: downloadDTOs))
        }

        return try Self.jsonResponse(PhotoDownloadURLsResponse(recados: recadosResponse), status: .ok)
    }

    // MARK: DELETE /api/v1/recados/:recadoID/photos/:photoID

    @Sendable
    func deletePhoto(req: Request) async throws -> Response {
        guard req.householdContext != nil else {
            throw Abort(.forbidden)
        }
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()

        guard
            let recadoID = req.parameters.get("recadoID", as: UUID.self),
            let photoID = req.parameters.get("photoID", as: UUID.self)
        else {
            return try Self.errorResponse(code: .validation, message: "identificador inválido.", status: .badRequest)
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
                message: "Só o autor pode remover fotos deste recado.",
                status: .forbidden
            )
        }

        guard let photo = try await RecadoPhoto.query(on: req.scopedDB)
            .filter(\.$id == photoID)
            .filter(\.$recado.$id == recadoID)
            .first()
        else {
            throw Abort(.notFound)
        }

        let objectKey = photo.objectKey
        try await photo.delete(on: req.scopedDB)

        // Melhor esforço: a linha já foi apagada; falha aqui é custo de armazenamento
        // órfão, não uma falha de correção — mas sem esta chamada a foto apagada
        // continuaria alcançável por qualquer URL assinada de leitura ainda válida.
        do {
            try await req.application.objectStorageClient.deleteObjects(keys: [objectKey])
        } catch {
            req.logger.error("falha ao apagar objeto de armazenamento (foto \(photoID)): \(error)")
        }

        return Response(status: .noContent)
    }

    // MARK: Helpers privados

    /// Rejeita o absurdo, aceita o resto (D-11, T-02-56): o servidor nunca viu os bytes da
    /// foto e não tem como verificar a data de captura declarada — a única defesa razoável
    /// é gravar `NULL` (que cai no fallback de exibição) para valor anterior a 1970 ou mais
    /// de 24h à frente do relógio do servidor, em vez de poluir a coluna de timestamp. A
    /// foto continua sendo confirmada normalmente: data implausível nunca é motivo de
    /// recusa, porque o metadado é só de exibição.
    private static func plausibleCapturedAt(_ date: Date?) -> Date? {
        guard let date else { return nil }
        guard date >= Date(timeIntervalSince1970: 0) else { return nil }
        guard date <= Date().addingTimeInterval(24 * 60 * 60) else { return nil }
        return date
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

/// Esquema de nomenclatura da chave de objeto — aprovado no `checkpoint:decision` da Task 1
/// deste plano (option-a): `households/{householdID}/recados/{recadoID}/{photoID}.{ext}`.
/// Hierárquico com ids reais — permite apagar/auditar por casa com uma única operação de
/// prefixo; a chave nunca é o controle de acesso primário (a autorização sempre resolve no
/// Postgres antes de qualquer chave ser montada ou validada).
enum RecadoPhotoObjectKey {
    /// Monta uma chave nova — o sufixo é sempre um UUID recém-gerado, nunca dependente de
    /// nenhuma entrada do cliente, então duas chaves da mesma requisição nunca são deriváveis
    /// uma da outra por incremento.
    static func make(householdID: UUID, recadoID: UUID, ext: String) -> String {
        "households/\(householdID.uuidString)/recados/\(recadoID.uuidString)/\(UUID().uuidString).\(ext)"
    }

    /// Valida que uma chave apresentada no `confirm` pertence exatamente a esta casa e a este
    /// recado, e que o sufixo é `{uuid}.{ext-não-vazia}` — chamado ANTES de qualquer consulta
    /// ao armazenamento (T-02-27).
    static func validate(_ key: String, householdID: UUID, recadoID: UUID) -> Bool {
        let expectedPrefix = "households/\(householdID.uuidString)/recados/\(recadoID.uuidString)/"
        guard key.hasPrefix(expectedPrefix) else { return false }
        let suffix = key.dropFirst(expectedPrefix.count)
        let components = suffix.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2, !components[1].isEmpty else { return false }
        return UUID(uuidString: String(components[0])) != nil
    }
}

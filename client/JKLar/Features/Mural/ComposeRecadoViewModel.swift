import Foundation
import JKLarShared
import Observation

/// Formulário de compose no caminho de texto (plano 02-05 Task 3) e de fotos/menção (plano
/// 02-06) — modela tanto a criação de um recado novo quanto a edição do próprio, no molde de
/// ação de `HouseholdViewModel.removeMember` (ramo de erro tipado específico + genérico).
@MainActor
@Observable
final class ComposeRecadoViewModel {
    /// Decide título, rótulo do CTA e qual rota do `APIClient` chamar.
    enum Mode: Equatable {
        case new
        case editing(recadoID: UUID)
    }

    /// Entrada crua de uma foto recém-selecionada — já com os bytes carregados e o tipo
    /// detectado. `ComposeRecadoView` monta isto a partir do `PhotosPickerItem`
    /// (`loadTransferable`, framework `PhotosUI`) depois que os bytes chegam; este view-model
    /// nunca importa `PhotosUI` diretamente, para continuar testável sem depender do seletor
    /// nativo.
    struct StagedPhotoInput: Sendable {
        let data: Data
        let contentType: String

        init(data: Data, contentType: String) {
            self.data = data
            self.contentType = contentType
        }
    }

    /// Uma foto anexada ao compose, com o próprio estado de envio (D-01/D-02) — cada
    /// miniatura resolve de forma independente das outras (uma falhar nunca trava as demais).
    struct StagedPhoto: Identifiable, Sendable, Equatable {
        enum UploadState: Equatable, Sendable {
            case pending
            case uploading
            case uploaded(objectKey: String)
            case failed
        }

        let id: UUID
        let data: Data
        let contentType: String
        var uploadState: UploadState

        init(id: UUID = UUID(), data: Data, contentType: String, uploadState: UploadState = .pending) {
            self.id = id
            self.data = data
            self.contentType = contentType
            self.uploadState = uploadState
        }
    }

    /// Teto de fotos por recado (D-02) — o corte aqui é conforto de interface; o servidor
    /// reforça o mesmo teto de forma independente (plano 02-04, T-02-44).
    static let maxPhotos = 10

    let mode: Mode
    var text: String
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    private(set) var stagedPhotos: [StagedPhoto] = []

    private let apiClient: APIClient
    private let photoUploadService: PhotoUploadService
    /// Id do recado recém-criado (modo novo) ou o `recadoID` do modo edição — guardado depois
    /// que `submit()` cria/atualiza o recado, para `retryUpload(photoID:)` saber a que recado
    /// escopar o presign/confirm de uma retentativa isolada, sem precisar de outro `submit()`.
    private var lastKnownRecadoID: UUID?

    var canAddMorePhotos: Bool {
        stagedPhotos.count < Self.maxPhotos
    }

    var photoCapMessage: String? {
        canAddMorePhotos ? nil : JKCopy.muralComposePhotoCapReached
    }

    var stagedPhotoCounterLabel: String {
        JKCopy.muralComposePhotoCounter(stagedPhotos.count)
    }

    /// Regra completa de D-01: `!isSubmitting`, nenhuma foto ainda em `pending`/`uploading`, e
    /// (texto não vazio **ou** ao menos uma foto em `uploaded`). Marcar alguém nunca entra
    /// nesta conta — menção é sempre opcional (D-01/D-05).
    var canSubmit: Bool {
        guard !isSubmitting, !hasPhotosStillResolving else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUploadedPhoto = stagedPhotos.contains { if case .uploaded = $0.uploadState { true } else { false } }
        return hasText || hasUploadedPhoto
    }

    private var hasPhotosStillResolving: Bool {
        stagedPhotos.contains { photo in
            switch photo.uploadState {
            case .pending, .uploading: true
            case .uploaded, .failed: false
            }
        }
    }

    init(
        mode: Mode = .new,
        initialText: String = "",
        apiClient: APIClient = APIClient(),
        photoUploadService: PhotoUploadService = PhotoUploadService()
    ) {
        self.mode = mode
        self.text = initialText
        self.apiClient = apiClient
        self.photoUploadService = photoUploadService
    }

    /// Converte itens já carregados do seletor em `StagedPhoto`, cortando no teto de 10
    /// (D-02) — conforto de interface, o servidor reforça o mesmo teto de forma independente.
    /// Itens além do que resta são descartados em silêncio (o botão "Adicionar fotos" já fica
    /// desabilitado ao chegar no teto, então isto só é alcançável numa corrida de seleção
    /// múltipla).
    func addPhotos(_ inputs: [StagedPhotoInput]) {
        let remainingSlots = Self.maxPhotos - stagedPhotos.count
        guard remainingSlots > 0 else { return }
        let accepted = inputs.prefix(remainingSlots)
        stagedPhotos.append(contentsOf: accepted.map {
            StagedPhoto(data: $0.data, contentType: $0.contentType)
        })
    }

    func removePhoto(id: UUID) {
        stagedPhotos.removeAll { $0.id == id }
    }

    /// Guarda de "já em voo" (mesma disciplina de `MuralFeedViewModel.loadNextPage()`):
    /// `submit()` chamado duas vezes em concorrência dispara exatamente uma chamada de rede.
    /// Nunca limpa `text` num erro — a pessoa não perde o que digitou. Sequência obrigatória
    /// quando há fotos anexadas: (1) criar/atualizar o recado; (2) presign de um slot por foto
    /// ainda `pending`; (3) enviar cada foto direto pra URL assinada — uma falha marca só
    /// aquela miniatura e segue com as demais; (4) confirmar só as chaves que chegaram a
    /// `uploaded`. O recado tem de existir antes de qualquer chave de objeto, porque a chave é
    /// escopada pelo recado.
    func submit(onSuccess: (RecadoDTO) -> Void) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let recado: RecadoDTO
            switch mode {
            case .new:
                recado = try await apiClient.createRecado(CreateRecadoRequest(text: text))
            case .editing(let recadoID):
                recado = try await apiClient.updateRecado(id: recadoID, UpdateRecadoRequest(text: text))
            }
            lastKnownRecadoID = recado.id

            await uploadPendingPhotos(recadoID: recado.id)

            onSuccess(recado)
        } catch APIClientError.apiError(.notAuthor) {
            errorMessage = JKCopy.muralComposeNotAuthorError
        } catch {
            errorMessage = JKCopy.muralComposeGenericPublishError
        }
    }

    /// `retryUpload` numa foto em `.failed` refaz presign + envio só daquela miniatura — nunca
    /// reenvia as outras, que já resolveram (`uploaded`) ou continuam falhadas até sua própria
    /// retentativa.
    func retryUpload(photoID: UUID) async {
        guard let recadoID = lastKnownRecadoID else { return }
        guard let index = stagedPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        guard stagedPhotos[index].uploadState == .failed else { return }
        let photo = stagedPhotos[index]

        do {
            let presigned = try await apiClient.presignPhotoUploads(
                recadoID: recadoID,
                slots: [PhotoUploadSlotRequest(contentType: photo.contentType, byteSize: photo.data.count)]
            )
            guard let upload = presigned.uploads.first else { return }
            setUploadState(photoID: photo.id, to: .uploading)
            try await photoUploadService.upload(data: photo.data, to: upload.uploadURL, contentType: photo.contentType)
            setUploadState(photoID: photo.id, to: .uploaded(objectKey: upload.objectKey))
            _ = try await apiClient.confirmPhotoUploads(recadoID: recadoID, objectKeys: [upload.objectKey])
            if !stagedPhotos.contains(where: { $0.uploadState == .failed }) {
                errorMessage = nil
            }
        } catch {
            setUploadState(photoID: photo.id, to: .failed)
        }
    }

    // MARK: - Envio de fotos (privado)

    private func uploadPendingPhotos(recadoID: UUID) async {
        let pending = stagedPhotos.filter { $0.uploadState == .pending }
        guard !pending.isEmpty else { return }

        let presigned: PresignPhotoUploadResponse
        do {
            let slots = pending.map { PhotoUploadSlotRequest(contentType: $0.contentType, byteSize: $0.data.count) }
            presigned = try await apiClient.presignPhotoUploads(recadoID: recadoID, slots: slots)
        } catch APIClientError.apiError(.photoLimitExceeded) {
            // Nenhum envio é tentado quando o presign já recusa o lote inteiro.
            errorMessage = JKCopy.muralComposePhotoCapReached
            return
        } catch {
            errorMessage = JKCopy.muralComposePhotoUploadPartialFailure
            return
        }

        var uploadedKeys: [String] = []
        for (photo, upload) in zip(pending, presigned.uploads) {
            setUploadState(photoID: photo.id, to: .uploading)
            do {
                try await photoUploadService.upload(data: photo.data, to: upload.uploadURL, contentType: photo.contentType)
                setUploadState(photoID: photo.id, to: .uploaded(objectKey: upload.objectKey))
                uploadedKeys.append(upload.objectKey)
            } catch {
                setUploadState(photoID: photo.id, to: .failed)
            }
        }

        let anyUploadFailed = uploadedKeys.count != pending.count
        guard !uploadedKeys.isEmpty else {
            if anyUploadFailed {
                errorMessage = JKCopy.muralComposePhotoUploadPartialFailure
            }
            return
        }

        do {
            _ = try await apiClient.confirmPhotoUploads(recadoID: recadoID, objectKeys: uploadedKeys)
            if anyUploadFailed {
                errorMessage = JKCopy.muralComposePhotoUploadPartialFailure
            }
        } catch {
            // Confirm recusado (ex.: .photoNotUploaded, T-02-45) — as chaves desta chamada
            // voltam para `failed`, a falha nunca é silenciosa.
            markFailed(objectKeys: uploadedKeys)
            errorMessage = JKCopy.muralComposePhotoUploadPartialFailure
        }
    }

    private func setUploadState(photoID: UUID, to state: StagedPhoto.UploadState) {
        guard let index = stagedPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        stagedPhotos[index].uploadState = state
    }

    private func markFailed(objectKeys: [String]) {
        for index in stagedPhotos.indices {
            if case .uploaded(let key) = stagedPhotos[index].uploadState, objectKeys.contains(key) {
                stagedPhotos[index].uploadState = .failed
            }
        }
    }
}

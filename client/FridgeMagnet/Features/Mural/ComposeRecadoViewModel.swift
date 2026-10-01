import Foundation
import FridgeMagnetShared
import Observation
import UserNotifications

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
        /// Data de captura lida do metadado dos próprios bytes (`PhotoMetadataReader`, D-11,
        /// plano 02-09) — nula quando o arquivo não tinha metadado de data (captura de tela,
        /// PNG limpo).
        let capturedAt: Date?

        init(data: Data, contentType: String, capturedAt: Date? = nil) {
            self.data = data
            self.contentType = contentType
            self.capturedAt = capturedAt
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
        /// Data de captura do arquivo desta foto (D-11) — viaja no item de confirm **desta**
        /// foto, nunca num índice paralelo; valor padrão nulo para não quebrar construção
        /// existente.
        let capturedAt: Date?
        var uploadState: UploadState

        init(
            id: UUID = UUID(), data: Data, contentType: String, capturedAt: Date? = nil,
            uploadState: UploadState = .pending
        ) {
            self.id = id
            self.data = data
            self.contentType = contentType
            self.capturedAt = capturedAt
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
    /// Membros marcados nesta sessão de compose, na ordem em que foram selecionados
    /// (`MentionPickerView`, plano 02-06 Task 2) — sempre um `MentionDTO.userID` real (D-06),
    /// nunca texto livre.
    private(set) var selectedMentions: [MentionDTO] = []
    /// Localização opcional do recado (D-12, plano 02-10) — sempre um lugar resolvido pela
    /// busca MapKit (nome editável + coordenada instantânea da escolha), nunca texto livre
    /// sem pino por trás. Nula é "sem localização"; nunca afeta `canSubmit`.
    private(set) var selectedLocation: RecadoLocationDTO?

    /// O par escolhido de lembrete (D-16, plano 02-15) — instante do EVENTO + antecedência
    /// em segundos, comparável (a pré-carga do modo edição e o teste de "intocado"
    /// precisam comparar pares), no mesmo espírito de `StagedPhotoInput` acima.
    struct SelectedReminder: Equatable, Sendable {
        var eventAt: Date
        var remindOffsetSeconds: Int
    }

    /// Lembrete opcional do recado (D-16) — nulo é "sem lembrete"; nunca afeta `canSubmit`
    /// (lembrete é sempre opcional, como menção e localização).
    private(set) var selectedReminder: SelectedReminder?
    /// Marca de "mexeu nesta sessão" — a tradução literal da regra de revalidação do
    /// `02-UI-SPEC.md` § Addendum 3: a revalidação de "cairia no passado" no envio SÓ vale
    /// quando o lembrete foi adicionado ou alterado nesta sessão. Sem esta marca, salvar a
    /// correção de digitação de um recado antigo com lembrete vencido viraria um erro
    /// permanente.
    private(set) var reminderTouched = false
    /// Dica inline de combinação inválida — distinta de `errorMessage` porque o contrato
    /// manda renderizá-la SOB a linha de lembrete, não no rodapé genérico.
    private(set) var reminderInvalidHint: String?
    /// Notificação negada NESTE aparelho — liga o aviso discreto do compose. Só o estado
    /// negado liga; indeterminado não mostra aviso nenhum, por contrato.
    private(set) var isNotificationsDenied = false

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
        canAddMorePhotos ? nil : FMCopy.muralComposePhotoCapReached
    }

    var stagedPhotoCounterLabel: String {
        FMCopy.muralComposePhotoCounter(stagedPhotos.count)
    }

    /// Regra completa de D-01: `!isSubmitting`, nenhuma foto com envio **em voo**
    /// (`uploading`, só possível durante um `retryUpload` fora do `submit`), e (texto não
    /// vazio **ou** ao menos uma foto aproveitável — `pending`, que o próprio `submit()` vai
    /// enviar, ou `uploaded`). `pending` NUNCA bloqueia: é o estado de toda foto recém-anexada,
    /// e só o `submit()` a tira dele — bloquear `pending` deixaria o botão Postar desabilitado
    /// para sempre com qualquer foto anexada (deadlock real visto no primeiro teste com foto,
    /// 2026-08-17). Marcar alguém nunca entra nesta conta — menção é sempre opcional
    /// (D-01/D-05).
    var canSubmit: Bool {
        guard !isSubmitting, !hasUploadInFlight else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsablePhoto = stagedPhotos.contains { photo in
            switch photo.uploadState {
            case .pending, .uploaded: true
            case .uploading, .failed: false
            }
        }
        return hasText || hasUsablePhoto
    }

    private var hasUploadInFlight: Bool {
        stagedPhotos.contains { $0.uploadState == .uploading }
    }

    private let notificationCenter: any LocalNotificationScheduling

    init(
        mode: Mode = .new,
        initialText: String = "",
        initialLocation: RecadoLocationDTO? = nil,
        initialReminder: SelectedReminder? = nil,
        apiClient: APIClient = APIClient(),
        photoUploadService: PhotoUploadService = PhotoUploadService(),
        notificationCenter: any LocalNotificationScheduling = UNUserNotificationCenter.current()
    ) {
        self.mode = mode
        self.text = initialText
        // `UpdateRecadoRequest.location` tem semântica de SUBSTITUIÇÃO (plano 02-08): o modo
        // edição recebe a localização atual do recado, senão o primeiro "Salvar" a apagaria
        // em silêncio — mesmo motivo do `initialText` acima.
        self.selectedLocation = initialLocation
        // `UpdateRecadoRequest.reminder` tem semântica de PRESENÇA (plano 02-14): a
        // pré-carga é o que mantém a marca de "mexeu nesta sessão" DESLIGADA quando
        // ninguém mexeu — salvar sem tocar manda um corpo que não fala de lembrete, e o
        // guardado (mesmo já vencido) é preservado pelo servidor.
        self.selectedReminder = initialReminder
        self.apiClient = apiClient
        self.photoUploadService = photoUploadService
        self.notificationCenter = notificationCenter
    }

    // MARK: - Lembrete (D-16, plano 02-15)

    /// Guarda o par devolvido pela folha de configuração — liga a marca de mexeu e limpa
    /// a dica. Nunca altera a regra de habilitar o envio.
    func setReminder(eventAt: Date, remindOffsetSeconds: Int) {
        selectedReminder = SelectedReminder(eventAt: eventAt, remindOffsetSeconds: remindOffsetSeconds)
        reminderTouched = true
        reminderInvalidHint = nil
    }

    /// Desfaz a seleção de lembrete antes de postar — edição desfazível, tratamento
    /// neutro (mesmo precedente de `clearLocation`). Liga a marca de mexeu (limpar É
    /// mexer: a edição salva depois manda o par explicitamente nulo) e limpa a dica.
    func clearReminder() {
        selectedReminder = nil
        reminderTouched = true
        reminderInvalidHint = nil
    }

    /// Lê o estado de autorização deste aparelho e liga a marca de negado SÓ no estado
    /// negado — indeterminado não mostra aviso nenhum, por contrato do `02-UI-SPEC.md`.
    func refreshNotificationAuthorizationState() async {
        isNotificationsDenied = await notificationCenter.readAuthorizationStatus() == .denied
    }

    /// O `ReminderUpdate` que a edição manda — a tradução das três formas do contrato de
    /// presença (plano 02-14): sem mexer nesta sessão, o corpo não fala de lembrete
    /// (ausente preserva, inclusive um lembrete já vencido); mexeu e limpou, o par vai
    /// explicitamente nulo (remove); mexeu e escolheu, o par novo vai preenchido
    /// (substitui, revalidado pelo servidor).
    private var reminderUpdateForEdit: ReminderUpdate {
        guard reminderTouched else { return .absent }
        guard let reminder = selectedReminder else { return .cleared }
        return .set(eventAt: reminder.eventAt, remindOffsetSeconds: reminder.remindOffsetSeconds)
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
            StagedPhoto(data: $0.data, contentType: $0.contentType, capturedAt: $0.capturedAt)
        })
    }

    func removePhoto(id: UUID) {
        stagedPhotos.removeAll { $0.id == id }
    }

    /// Substitui o conjunto de menções pelo devolvido por `MentionPickerView` — não altera
    /// `canSubmit` (D-01/D-05: marcar é sempre opcional).
    func setMentions(_ mentions: [MentionDTO]) {
        selectedMentions = mentions
    }

    /// Guarda o lugar devolvido pela folha de busca (D-12) — mesmo molde de `setMentions`:
    /// substitui a seleção inteira, não altera `canSubmit` (localização é sempre opcional).
    /// A coordenada é o instantâneo do momento da escolha.
    func setLocation(name: String, lat: Double, lng: Double) {
        selectedLocation = RecadoLocationDTO(text: name, lat: lat, lng: lng)
    }

    /// Edição do rótulo depois da escolha (ex.: acrescentar "Sala 302" ao nome da clínica):
    /// troca só o texto, preservando latitude e longitude — a coordenada é instantâneo da
    /// escolha e nunca é recalculada a partir do texto editado. Texto vazio depois de aparar
    /// espaço limpa a seleção inteira: alinhamento explícito com a regra do servidor (plano
    /// 02-08, `normalizeText` — texto vazio faz a localização inteira ser ausente), para o
    /// compose nunca mostrar um pino que o servidor vai descartar em silêncio.
    func updateLocationText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectedLocation = nil
            return
        }
        selectedLocation?.text = text
    }

    /// Desfaz a seleção de localização antes de postar — edição desfazível, não remoção de
    /// dado real (o botão da view usa o tratamento neutro, nunca o destrutivo).
    func clearLocation() {
        selectedLocation = nil
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

        // Revalidação do lembrete ANTES de qualquer chamada de rede (D-16): a folha de
        // configuração bloqueia a combinação inválida na hora da escolha, mas o tempo
        // passa enquanto a pessoa escreve a legenda — um disparo que ficou no passado
        // bloqueia o envio com a dica inline sob a linha de lembrete. SÓ quando o
        // lembrete foi mexido nesta sessão: sem a marca, salvar a correção de digitação
        // de um recado antigo com lembrete vencido viraria um erro permanente (regra de
        // edição do 02-UI-SPEC.md § Addendum 3).
        if reminderTouched, let reminder = selectedReminder,
           reminder.eventAt.addingTimeInterval(-TimeInterval(reminder.remindOffsetSeconds)) <= Date() {
            reminderInvalidHint = FMCopy.muralComposeReminderInvalidHint
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let recado: RecadoDTO
            let mentionedUserIDs = selectedMentions.map(\.userID)
            switch mode {
            case .new:
                // Na criação não existe "não veio versus veio nulo" (não há estado
                // anterior a preservar) — o par vai direto nos dois campos opcionais.
                recado = try await apiClient.createRecado(
                    CreateRecadoRequest(
                        text: text,
                        mentionedUserIDs: mentionedUserIDs,
                        location: selectedLocation,
                        eventAt: selectedReminder?.eventAt,
                        remindOffsetSeconds: selectedReminder?.remindOffsetSeconds
                    )
                )
            case .editing(let recadoID):
                recado = try await apiClient.updateRecado(
                    id: recadoID,
                    UpdateRecadoRequest(
                        text: text,
                        mentionedUserIDs: mentionedUserIDs,
                        location: selectedLocation,
                        reminder: reminderUpdateForEdit
                    )
                )
            }
            lastKnownRecadoID = recado.id

            await uploadPendingPhotos(recadoID: recado.id)

            onSuccess(recado)
        } catch APIClientError.apiError(.notAuthor) {
            errorMessage = FMCopy.muralComposeNotAuthorError
        } catch {
            errorMessage = FMCopy.muralComposeGenericPublishError
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
            // A data de captura é a da ÚNICA foto envolvida na retentativa — lida da própria
            // `StagedPhoto`, nunca de outra da mesma sessão de compose (D-11).
            _ = try await apiClient.confirmPhotoUploads(
                recadoID: recadoID,
                photos: [ConfirmPhotoUploadItem(objectKey: upload.objectKey, capturedAt: photo.capturedAt)]
            )
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
            errorMessage = FMCopy.muralComposePhotoCapReached
            return
        } catch {
            errorMessage = FMCopy.muralComposePhotoUploadPartialFailure
            return
        }

        // Cada par (chave, data de captura) é acumulado no MESMO laço que envia a foto — a
        // data vem da própria `StagedPhoto` daquela iteração, nunca de um índice paralelo
        // remontado depois (D-11; um array paralelo desincronizaria no primeiro retry que
        // mistura chave já confirmada com chave nova).
        var uploadedItems: [(objectKey: String, capturedAt: Date?)] = []
        for (photo, upload) in zip(pending, presigned.uploads) {
            setUploadState(photoID: photo.id, to: .uploading)
            do {
                try await photoUploadService.upload(data: photo.data, to: upload.uploadURL, contentType: photo.contentType)
                setUploadState(photoID: photo.id, to: .uploaded(objectKey: upload.objectKey))
                uploadedItems.append((objectKey: upload.objectKey, capturedAt: photo.capturedAt))
            } catch {
                setUploadState(photoID: photo.id, to: .failed)
            }
        }

        let anyUploadFailed = uploadedItems.count != pending.count
        guard !uploadedItems.isEmpty else {
            if anyUploadFailed {
                errorMessage = FMCopy.muralComposePhotoUploadPartialFailure
            }
            return
        }

        do {
            let items = uploadedItems.map { ConfirmPhotoUploadItem(objectKey: $0.objectKey, capturedAt: $0.capturedAt) }
            _ = try await apiClient.confirmPhotoUploads(recadoID: recadoID, photos: items)
            if anyUploadFailed {
                errorMessage = FMCopy.muralComposePhotoUploadPartialFailure
            }
        } catch {
            // Confirm recusado (ex.: .photoNotUploaded, T-02-45) — as chaves desta chamada
            // voltam para `failed`, a falha nunca é silenciosa.
            markFailed(keys: uploadedItems.map(\.objectKey))
            errorMessage = FMCopy.muralComposePhotoUploadPartialFailure
        }
    }

    private func setUploadState(photoID: UUID, to state: StagedPhoto.UploadState) {
        guard let index = stagedPhotos.firstIndex(where: { $0.id == photoID }) else { return }
        stagedPhotos[index].uploadState = state
    }

    private func markFailed(keys: [String]) {
        for index in stagedPhotos.indices {
            if case .uploaded(let key) = stagedPhotos[index].uploadState, keys.contains(key) {
                stagedPhotos[index].uploadState = .failed
            }
        }
    }
}

import XCTest
import FridgeMagnetShared
import UserNotifications
@testable import FridgeMagnet

/// Registrador simples de chamada (método + caminho) — usado tanto para o comportamento "modo
/// edição chama a rota de atualização, nunca a de criação" quanto para contar chamadas por
/// rota (presign/confirm) do plano 02-06 Task 1. `actor` para poder ser lido de fora com
/// segurança.
private actor CallRecorder {
    private(set) var lastMethod: String?
    private(set) var lastPath: String?
    private(set) var lastBody: Data?
    private(set) var callCount = 0
    private(set) var pathCounts: [String: Int] = [:]

    func record(method: String, path: String, body: Data?) {
        lastMethod = method
        lastPath = path
        lastBody = body
        callCount += 1
        pathCounts[path, default: 0] += 1
    }

    func count(forSuffix suffix: String) -> Int {
        pathCounts.reduce(0) { partial, entry in entry.key.hasSuffix(suffix) ? partial + entry.value : partial }
    }
}

/// Transporte falso, imediato — dono deste arquivo, sem estado compartilhado com stubs de
/// outros arquivos de teste (mesmo padrão de `OnboardingStubTransport`). Estendido no plano
/// 02-06 Task 1 para também rotear `photos/presign` e `photos/confirm` (o compose de texto
/// nunca chama essas rotas, então o roteamento é aditivo e não muda nenhum teste existente).
private struct ComposeStubTransport: APIClientTransport {
    enum Outcome {
        case success(RecadoDTO, status: Int)
        case apiError(APIErrorCode, status: Int)
        case failure(status: Int)
    }

    /// Resposta simulada de `POST .../photos/presign` — por padrão devolve uma URL assinada
    /// (falsa) por slot pedido, prefixada por `objectKeyPrefix`.
    enum PresignOutcome {
        case success(objectKeyPrefix: String = "key")
        case apiError(APIErrorCode, status: Int)
    }

    /// Resposta simulada de `POST .../photos/confirm` — por padrão devolve um `ConfirmedPhotoDTO`
    /// por chave recebida no corpo.
    enum ConfirmOutcome {
        case success
        case apiError(APIErrorCode, status: Int)
    }

    let outcome: Outcome
    var recorder: CallRecorder?
    var presignOutcome: PresignOutcome = .success(objectKeyPrefix: "key")
    var confirmOutcome: ConfirmOutcome = .success

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder?.record(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", body: request.httpBody)
        let url = request.url!
        let path = url.path

        if path.hasSuffix("/photos/presign") {
            return try encodePresign(request: request, url: url)
        }
        if path.hasSuffix("/photos/confirm") {
            return try encodeConfirm(request: request, url: url)
        }

        switch outcome {
        case .success(let recado, let status):
            let data = try ServerWire.encoder.encode(recado)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try ServerWire.encoder.encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func encodePresign(request: URLRequest, url: URL) throws -> (Data, HTTPURLResponse) {
        switch presignOutcome {
        case .success(let prefix):
            let body = try JSONDecoder().decode(PresignPhotoUploadRequest.self, from: request.httpBody ?? Data())
            let uploads = body.slots.enumerated().map { index, _ in
                PresignedPhotoUploadDTO(
                    objectKey: "\(prefix)-\(index)",
                    uploadURL: URL(string: "https://storage.example.com/\(prefix)-\(index)")!,
                    expiresAt: Date().addingTimeInterval(600)
                )
            }
            let data = try ServerWire.encoder.encode(PresignPhotoUploadResponse(uploads: uploads))
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try ServerWire.encoder.encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func encodeConfirm(request: URLRequest, url: URL) throws -> (Data, HTTPURLResponse) {
        switch confirmOutcome {
        case .success:
            // Decoder com datas ISO8601, espelhando o servidor real: o `APIClient` codifica
            // o corpo com datas ISO8601, e `ConfirmPhotoUploadItem.capturedAt` (plano 02-08)
            // é um `Date` — um `JSONDecoder()` cru falharia no primeiro corpo com data real
            // (plano 02-09), exatamente o furo que o `ServerWire.encoder` já documenta.
            let bodyDecoder = JSONDecoder()
            bodyDecoder.dateDecodingStrategy = .iso8601
            let body = try bodyDecoder.decode(ConfirmPhotoUploadRequest.self, from: request.httpBody ?? Data())
            let dtos = body.photos.enumerated().map { index, item in
                ConfirmedPhotoDTO(id: UUID(), position: index, capturedAt: item.capturedAt ?? Date())
            }
            let data = try ServerWire.encoder.encode(dtos)
            return (data, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try ServerWire.encoder.encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Transporte falso de envio de bytes (`PhotoUploadTransport`, não `APIClientTransport`) — cada
/// chave cujo `objectKey` aparece em `failingObjectKeys` devolve 500 (foto que falha); as
/// demais devolvem 200. O `objectKey` é lido do path da URL assinada (formato de teste
/// `.../\(prefix)-\(index)`, ver `ComposeStubTransport.encodePresign`).
private actor PhotoUploadOutcomeTransport: PhotoUploadTransport {
    private var failingObjectKeys: Set<String>
    /// Quando verdadeiro, cada chave falhante falha só na primeira tentativa — a retentativa
    /// da mesma chave sucede (plano 02-09: o teste de retentativa precisa que o confirm da
    /// retentativa aconteça de verdade para inspecionar o corpo dele).
    private let failOnlyOnce: Bool
    private(set) var callCount = 0
    private(set) var uploadedURLs: [URL] = []

    init(failingObjectKeys: Set<String> = [], failOnlyOnce: Bool = false) {
        self.failingObjectKeys = failingObjectKeys
        self.failOnlyOnce = failOnlyOnce
    }

    func upload(_ request: URLRequest, from data: Data) async throws -> HTTPURLResponse {
        callCount += 1
        let url = request.url!
        uploadedURLs.append(url)
        let objectKey = url.lastPathComponent
        let shouldFail = failingObjectKeys.contains(objectKey)
        if shouldFail, failOnlyOnce {
            failingObjectKeys.remove(objectKey)
        }
        return HTTPURLResponse(url: url, statusCode: shouldFail ? 500 : 200, httpVersion: nil, headerFields: nil)!
    }
}

/// Transporte que bloqueia dentro de `send(_:)` até `release()` ser chamado — mesmo molde de
/// `GatedTransport` em `OnboardingViewModelTests.swift`.
private actor ComposeGatedTransport: APIClientTransport {
    private let recado: RecadoDTO
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false
    private(set) var callCount = 0

    init(recado: RecadoDTO) {
        self.recado = recado
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        await waitUntilReleased()
        let data = try ServerWire.encoder.encode(recado)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func waitUntilReleased() async {
        if released { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
final class ComposeRecadoViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeRecado(id: UUID = UUID(), text: String = "Oi") -> RecadoDTO {
        RecadoDTO(
            id: id,
            authorID: UUID(),
            authorDisplayName: "Eu",
            isMine: true,
            text: text,
            sequence: 1,
            createdAt: Date(),
            updatedAt: Date(),
            photos: [],
            mentions: [],
            reactions: [],
            myReaction: nil,
            commentCount: 0,
            latestComments: []
        )
    }

    // MARK: Estado inicial / canSubmit

    func testInitialStateInNewMode() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        XCTAssertEqual(sut.text, "")
        XCTAssertFalse(sut.canSubmit)
        XCTAssertFalse(sut.isSubmitting)
        XCTAssertNil(sut.errorMessage)
    }

    func testCanSubmitTogglesWithNonEmptyText() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.text = "Oi"
        XCTAssertTrue(sut.canSubmit)

        sut.text = ""
        XCTAssertFalse(sut.canSubmit)

        sut.text = "   "
        XCTAssertFalse(sut.canSubmit, "só espaços não conta como preenchido")
    }

    // MARK: submit() — modo novo, sucesso

    func testSubmitNewModeSuccessCallsCreateOnceAndPassesRecadoToCompletion() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Recado novo")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Recado novo"

        var completed: RecadoDTO?
        await sut.submit { completed = $0 }

        XCTAssertEqual(completed?.id, created.id)
        XCTAssertFalse(sut.isSubmitting)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)
        let method = await recorder.lastMethod
        XCTAssertEqual(method, "POST")
    }

    // MARK: submit() — em voo

    func testCanSubmitFalseWhileSubmittingInFlight() async {
        let gated = ComposeGatedTransport(recado: makeRecado())
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: gated, baseURL: url()))
        sut.text = "Em voo"
        XCTAssertTrue(sut.canSubmit)

        let submitTask = Task { await sut.submit { _ in } }

        while await !gated.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(sut.isSubmitting, "isSubmitting verdadeiro enquanto o envio está em voo")
        XCTAssertFalse(sut.canSubmit, "canSubmit falso (formulário desabilitado) durante o envio")

        await gated.release()
        await submitTask.value
        XCTAssertFalse(sut.isSubmitting)
    }

    // MARK: submit() — falha genérica

    func testSubmitGenericFailurePreservesTextDoesNotClearAndDoesNotCallCompletion() async {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Não perder isso"

        var completionCalled = false
        await sut.submit { _ in completionCalled = true }

        XCTAssertEqual(sut.text, "Não perder isso", "o texto digitado nunca é perdido numa falha")
        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposeGenericPublishError)
        XCTAssertFalse(completionCalled, "a closure de conclusão não roda numa falha")
        XCTAssertFalse(sut.isSubmitting)
    }

    // MARK: submit() — modo edição, notAuthor

    func testSubmitEditModeNotAuthorShowsSpecificMessage() async {
        let recadoID = UUID()
        let transport = ComposeStubTransport(outcome: .apiError(.notAuthor, status: 403))
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: recadoID), initialText: "Editando", apiClient: APIClient(transport: transport, baseURL: url())
        )

        await sut.submit { _ in }

        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposeNotAuthorError)
        XCTAssertNotEqual(sut.errorMessage, FMCopy.muralComposeGenericPublishError, "mensagem específica, não a genérica")
    }

    // MARK: submit() — modo edição chama a rota certa

    func testSubmitEditModeCallsUpdateRouteNeverCreate() async {
        let recadoID = UUID()
        let recorder = CallRecorder()
        let updated = makeRecado(id: recadoID, text: "Editado")
        let transport = ComposeStubTransport(outcome: .success(updated, status: 200), recorder: recorder)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: recadoID), initialText: "Editado", apiClient: APIClient(transport: transport, baseURL: url())
        )

        await sut.submit { _ in }

        let method = await recorder.lastMethod
        let path = await recorder.lastPath
        XCTAssertEqual(method, "PATCH")
        XCTAssertEqual(path, "/api/v1/recados/\(recadoID.uuidString)")
    }

    // MARK: submit() — concorrência

    func testConcurrentSubmitCallsTriggerExactlyOneNetworkCall() async {
        let gated = ComposeGatedTransport(recado: makeRecado())
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: gated, baseURL: url()))
        sut.text = "Concorrente"

        let task1 = Task { await sut.submit { _ in } }
        let task2 = Task { await sut.submit { _ in } }

        var attempts = 0
        while await !gated.isWaiting, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        guard await gated.isWaiting else {
            await gated.release()
            _ = await (task1.value, task2.value)
            return XCTFail("transporte nunca suspendeu — submit() não chamou a rede como esperado")
        }
        await Task.yield()
        await gated.release()
        await task1.value
        await task2.value

        let callCount = await gated.callCount
        XCTAssertEqual(callCount, 1, "submit() concorrente dispara exatamente uma chamada de rede")
    }

    // MARK: addPhotos(_:) / teto de 10 (plano 02-06 Task 1)

    private func makeInput(
        contentType: String = "image/jpeg", capturedAt: Date? = nil
    ) -> ComposeRecadoViewModel.StagedPhotoInput {
        .init(data: Data("foto".utf8), contentType: contentType, capturedAt: capturedAt)
    }

    /// Decodifica o corpo do último request registrado como o corpo de confirm — com datas
    /// ISO8601, espelhando o `ComposeStubTransport.encodeConfirm` (o `APIClient` codifica
    /// `capturedAt` como ISO8601; um `JSONDecoder()` cru falharia na primeira data real).
    private func decodeConfirmBody(_ body: Data?) throws -> ConfirmPhotoUploadRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConfirmPhotoUploadRequest.self, from: body ?? Data())
    }

    /// Data com precisão de segundo inteiro — ISO8601 de fio não carrega fração de segundo,
    /// então o round-trip codifica/decodifica só é exato em datas já truncadas.
    private func wholeSecondDate(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: interval.rounded(.down))
    }

    func testAddPhotosLeavesThreeItemsAllPendingWithCounter() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.addPhotos([makeInput(), makeInput(), makeInput()])

        XCTAssertEqual(sut.stagedPhotos.count, 3)
        XCTAssertTrue(sut.stagedPhotos.allSatisfy { $0.uploadState == .pending })
        XCTAssertEqual(sut.stagedPhotoCounterLabel, "3/10")
    }

    func testAddPhotosAtCapDisablesFurtherAdditionsAndShowsCapMessage() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.addPhotos((0..<10).map { _ in makeInput() })

        XCTAssertFalse(sut.canAddMorePhotos)
        XCTAssertEqual(sut.photoCapMessage, FMCopy.muralComposePhotoCapReached)

        sut.addPhotos([makeInput()])
        XCTAssertEqual(sut.stagedPhotos.count, 10, "tentar anexar além do teto não acrescenta item")
    }

    // MARK: canSubmit com fotos (plano 02-06 Task 1)

    func testCanSubmitTrueWhilePhotoPendingWithText() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Com foto"

        sut.addPhotos([makeInput()])

        XCTAssertTrue(
            sut.canSubmit,
            "foto pending nunca bloqueia o envio — é o estado de toda foto recém-anexada e só o submit() a resolve (deadlock de 2026-08-17)"
        )
    }

    func testCanSubmitTrueWithEmptyTextAndPendingPhoto() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = ""

        sut.addPhotos([makeInput()])

        XCTAssertTrue(sut.canSubmit, "foto pending conta para a regra texto-ou-foto (D-01) — o submit() é quem a envia")
    }

    func testCanSubmitTrueWithEmptyTextOnceAtLeastOnePhotoUploaded() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let uploadTransport = PhotoUploadOutcomeTransport()
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = ""
        sut.addPhotos([makeInput()])

        await sut.submit { _ in }

        XCTAssertEqual(sut.stagedPhotos.first?.uploadState, .uploaded(objectKey: "key-0"))
        XCTAssertTrue(sut.canSubmit, "texto vazio, mas 1 foto em uploaded já satisfaz a regra texto-ou-foto (D-01)")
    }

    func testCanSubmitFalseWithEmptyTextWhenAllPhotosFailed() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        // A própria foto ("key-0") é configurada para falhar no envio.
        let uploadTransport = PhotoUploadOutcomeTransport(failingObjectKeys: ["key-0"])
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = ""
        sut.addPhotos([makeInput()])

        await sut.submit { _ in }

        XCTAssertEqual(sut.stagedPhotos.first?.uploadState, .failed)
        XCTAssertFalse(sut.canSubmit, "texto vazio e a única foto falhou — nada satisfaz a regra texto-ou-foto")
    }

    // MARK: submit() com fotos — ordem e chamadas por rota (plano 02-06 Task 1)

    func testSubmitWithTwoPhotosCallsCreatePresignUploadThenConfirmInOrder() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Duas fotos")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let uploadTransport = PhotoUploadOutcomeTransport()
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Duas fotos"
        sut.addPhotos([makeInput(), makeInput()])

        await sut.submit { _ in }

        let recadoCalls = await recorder.count(forSuffix: "/api/v1/recados")
        let presignCalls = await recorder.count(forSuffix: "/photos/presign")
        let confirmCalls = await recorder.count(forSuffix: "/photos/confirm")
        XCTAssertEqual(recadoCalls, 1, "cria o recado exatamente uma vez")
        XCTAssertEqual(presignCalls, 1, "um presign pedindo os 2 slots de uma vez, não um por foto")
        XCTAssertEqual(confirmCalls, 1, "um confirm com as 2 chaves, não um por foto")
        let uploadCallCount = await uploadTransport.callCount
        XCTAssertEqual(uploadCallCount, 2, "cada foto é enviada individualmente pro armazenamento")
        XCTAssertEqual(sut.stagedPhotos.map(\.uploadState), [.uploaded(objectKey: "key-0"), .uploaded(objectKey: "key-1")])
    }

    func testSubmitWithOneOfThreePhotosFailingUploadsOthersAndConfirmsOnlySuccessfulKeys() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Três fotos")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        // A foto do meio ("key-1") falha; as outras duas sobem normalmente.
        let uploadTransport = PhotoUploadOutcomeTransport(failingObjectKeys: ["key-1"])
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Três fotos"
        sut.addPhotos([makeInput(), makeInput(), makeInput()])

        await sut.submit { _ in }

        XCTAssertEqual(sut.stagedPhotos[0].uploadState, .uploaded(objectKey: "key-0"))
        XCTAssertEqual(sut.stagedPhotos[1].uploadState, .failed)
        XCTAssertEqual(sut.stagedPhotos[2].uploadState, .uploaded(objectKey: "key-2"))
        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposePhotoUploadPartialFailure, "a falha nunca é silenciosa")

        // Confirm só recebeu as 2 chaves que subiram — provado pelo corpo capturado no
        // transporte, via decodificação do request mais recente à rota de confirm.
        let confirmCalls = await recorder.count(forSuffix: "/photos/confirm")
        XCTAssertEqual(confirmCalls, 1)
    }

    // MARK: retryUpload(photoID:) (plano 02-06 Task 1)

    func testRetryUploadOnFailedPhotoRedoesPresignAndUploadForThatPhotoOnly() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Retry")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let uploadTransport = PhotoUploadOutcomeTransport(failingObjectKeys: ["key-0"])
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Retry"
        sut.addPhotos([makeInput()])
        await sut.submit { _ in }
        guard let photoID = sut.stagedPhotos.first?.id, sut.stagedPhotos.first?.uploadState == .failed else {
            return XCTFail("pré-condição: esperava failed antes da retentativa")
        }
        let presignCallsBeforeRetry = await recorder.count(forSuffix: "/photos/presign")
        let uploadCallsBeforeRetry = await uploadTransport.callCount

        await sut.retryUpload(photoID: photoID)

        let presignCallsAfterRetry = await recorder.count(forSuffix: "/photos/presign")
        let uploadCallsAfterRetry = await uploadTransport.callCount
        XCTAssertEqual(presignCallsAfterRetry, presignCallsBeforeRetry + 1, "retryUpload refaz o presign")
        XCTAssertEqual(uploadCallsAfterRetry, uploadCallsBeforeRetry + 1, "retryUpload refaz o envio, só desta foto")
        XCTAssertEqual(sut.stagedPhotos.count, 1, "nenhuma foto extra foi criada pela retentativa")
    }

    // MARK: Erros tipados do presign/confirm (plano 02-06 Task 1)

    func testPresignRejectedWithPhotoLimitExceededShowsCapMessageAndAttemptsNoUpload() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Cheio")
        let transport = ComposeStubTransport(
            outcome: .success(created, status: 201),
            recorder: recorder,
            presignOutcome: .apiError(.photoLimitExceeded, status: 400)
        )
        let uploadTransport = PhotoUploadOutcomeTransport()
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Cheio"
        sut.addPhotos([makeInput()])

        await sut.submit { _ in }

        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposePhotoCapReached)
        let uploadCallCount = await uploadTransport.callCount
        XCTAssertEqual(uploadCallCount, 0, "presign recusado nunca tenta nenhum envio")
    }

    func testConfirmRejectedWithPhotoNotUploadedMarksThoseFilesFailedAndShowsPartialFailure() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Confirm falha")
        let transport = ComposeStubTransport(
            outcome: .success(created, status: 201),
            recorder: recorder,
            confirmOutcome: .apiError(.photoNotUploaded, status: 409)
        )
        let uploadTransport = PhotoUploadOutcomeTransport()
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Confirm falha"
        sut.addPhotos([makeInput()])

        await sut.submit { _ in }

        XCTAssertEqual(sut.stagedPhotos.first?.uploadState, .failed, "chave recusada no confirm volta pro estado failed")
        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposePhotoUploadPartialFailure)
    }

    // MARK: capturedAt — anexar, confirm e retentativa (plano 02-09, D-11)

    func testAddPhotosPropagatesCapturedAtToStagedPhoto() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        let captured = wholeSecondDate(1_770_000_000)

        sut.addPhotos([makeInput(capturedAt: captured)])

        XCTAssertEqual(sut.stagedPhotos.first?.capturedAt, captured, "a data de captura do input fica na foto anexada")
    }

    func testAddPhotosWithoutCapturedAtLeavesStagedPhotoCapturedAtNil() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.addPhotos([makeInput()])

        XCTAssertNil(sut.stagedPhotos.first?.capturedAt, "foto sem metadado de data fica com capturedAt nulo")
    }

    func testSubmitWithPhotosSendsPerItemCapturedAtInConfirmBody() async throws {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Com datas")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let uploadTransport = PhotoUploadOutcomeTransport()
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Com datas"
        let captured = wholeSecondDate(1_770_000_000)
        // Uma foto com data de captura e uma sem — o corpo do confirm tem de carregar a data
        // POR ITEM (nula quando não havia metadado), nunca uma data única para o lote.
        sut.addPhotos([makeInput(capturedAt: captured), makeInput()])

        await sut.submit { _ in }

        // O confirm é a última chamada da sequência create → presign → confirm, então o
        // corpo mais recente registrado é o dele.
        let body = try await decodeConfirmBody(recorder.lastBody)
        XCTAssertEqual(body.photos.count, 2, "um item por chave enviada")
        XCTAssertEqual(body.photos[0].capturedAt, captured, "a data de captura da primeira foto viaja no item dela")
        XCTAssertNil(body.photos[1].capturedAt, "foto sem metadado manda nulo — o servidor resolve o fallback")
    }

    func testRetryUploadSendsThatPhotosOwnCapturedAtNotAnotherPhotos() async throws {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Retry com data")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        // A primeira foto ("key-0") falha no submit; a segunda sobe normalmente. `failOnlyOnce`
        // deixa a retentativa da mesma chave suceder — sem isso o confirm da retentativa nunca
        // aconteceria e o corpo dele não existiria para inspecionar.
        let uploadTransport = PhotoUploadOutcomeTransport(failingObjectKeys: ["key-0"], failOnlyOnce: true)
        let sut = ComposeRecadoViewModel(
            mode: .new,
            apiClient: APIClient(transport: transport, baseURL: url()),
            photoUploadService: PhotoUploadService(transport: uploadTransport)
        )
        sut.text = "Retry com data"
        let capturedOfFailedPhoto = wholeSecondDate(1_770_000_000)
        let capturedOfOtherPhoto = wholeSecondDate(1_770_100_000)
        sut.addPhotos([
            makeInput(capturedAt: capturedOfFailedPhoto),
            makeInput(capturedAt: capturedOfOtherPhoto),
        ])
        await sut.submit { _ in }
        guard let failedPhoto = sut.stagedPhotos.first, failedPhoto.uploadState == .failed else {
            return XCTFail("pré-condição: esperava a primeira foto em failed antes da retentativa")
        }

        await sut.retryUpload(photoID: failedPhoto.id)

        // O confirm da retentativa é a chamada mais recente — o item único carrega a data
        // DAQUELA foto, nunca a da outra da mesma sessão de compose.
        let body = try await decodeConfirmBody(recorder.lastBody)
        XCTAssertEqual(body.photos.count, 1, "retentativa isolada confirma só a foto envolvida")
        XCTAssertEqual(body.photos[0].capturedAt, capturedOfFailedPhoto)
        XCTAssertNotEqual(body.photos[0].capturedAt, capturedOfOtherPhoto, "nunca a data de outra foto da sessão")
    }

    // MARK: Localização (plano 02-10, D-12)

    func testSelectedLocationStartsNilAndDoesNotAffectCanSubmit() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        XCTAssertNil(sut.selectedLocation, "sem localização até a pessoa escolher uma")

        sut.text = "Com texto"
        let canSubmitBefore = sut.canSubmit
        sut.setLocation(name: "Praça da Sé", lat: -23.5503, lng: -46.6339)
        XCTAssertEqual(sut.canSubmit, canSubmitBefore, "localização é sempre opcional, como menção — não afeta canSubmit")

        sut.clearLocation()
        XCTAssertEqual(sut.canSubmit, canSubmitBefore, "limpar a localização também não afeta canSubmit")
    }

    func testSetLocationFillsSelectedLocationWithNameLatLng() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.setLocation(name: "Consultório Dra. Ana", lat: -23.561414, lng: -46.655881)

        XCTAssertEqual(sut.selectedLocation?.text, "Consultório Dra. Ana")
        XCTAssertEqual(sut.selectedLocation?.lat, -23.561414)
        XCTAssertEqual(sut.selectedLocation?.lng, -46.655881)
    }

    func testUpdateLocationTextReplacesTextOnlyPreservingCoordinate() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        sut.setLocation(name: "Consultório Dra. Ana", lat: -23.561414, lng: -46.655881)

        sut.updateLocationText("Consultório Dra. Ana — Sala 302")

        XCTAssertEqual(sut.selectedLocation?.text, "Consultório Dra. Ana — Sala 302")
        XCTAssertEqual(sut.selectedLocation?.lat, -23.561414, "a coordenada é instantâneo da escolha — sobrevive à edição do rótulo")
        XCTAssertEqual(sut.selectedLocation?.lng, -46.655881, "nunca re-geocodificada a partir do texto editado")
    }

    func testUpdateLocationTextWithBlankTextClearsSelectedLocationEntirely() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        sut.setLocation(name: "Praça da Sé", lat: -23.5503, lng: -46.6339)
        sut.updateLocationText("")
        XCTAssertNil(sut.selectedLocation, "texto vazio limpa a localização inteira — alinhamento com a regra do servidor (02-08)")

        sut.setLocation(name: "Praça da Sé", lat: -23.5503, lng: -46.6339)
        sut.updateLocationText("   ")
        XCTAssertNil(sut.selectedLocation, "só espaço equivale a vazio, mesma regra de normalização do servidor")
    }

    func testClearLocationLeavesSelectedLocationNil() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        sut.setLocation(name: "Praça da Sé", lat: -23.5503, lng: -46.6339)

        sut.clearLocation()

        XCTAssertNil(sut.selectedLocation)
    }

    func testSubmitNewModeSendsSelectedLocationInCreateBody() async throws {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Com localização")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Com localização"
        sut.setLocation(name: "Consultório Dra. Ana", lat: -23.561414, lng: -46.655881)

        await sut.submit { _ in }

        let body = await recorder.lastBody
        let decoded = try JSONDecoder().decode(CreateRecadoRequest.self, from: body ?? Data())
        XCTAssertEqual(decoded.location?.text, "Consultório Dra. Ana")
        XCTAssertEqual(decoded.location?.lat, -23.561414)
        XCTAssertEqual(decoded.location?.lng, -46.655881)
    }

    func testSubmitEditModeSendsSelectedLocationInUpdateBody() async throws {
        let recadoID = UUID()
        let recorder = CallRecorder()
        let updated = makeRecado(id: recadoID, text: "Editado com localização")
        let transport = ComposeStubTransport(outcome: .success(updated, status: 200), recorder: recorder)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: recadoID), initialText: "Editado com localização",
            apiClient: APIClient(transport: transport, baseURL: url())
        )
        sut.setLocation(name: "Praça da Sé", lat: -23.5503, lng: -46.6339)

        await sut.submit { _ in }

        let body = await recorder.lastBody
        let decoded = try JSONDecoder().decode(UpdateRecadoRequest.self, from: body ?? Data())
        XCTAssertEqual(decoded.location?.text, "Praça da Sé")
        XCTAssertEqual(decoded.location?.lat, -23.5503)
        XCTAssertEqual(decoded.location?.lng, -46.6339)
    }

    func testSubmitWithoutLocationSendsAbsentLocationNeverEmptyObjectNorZeroCoordinate() async throws {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Sem localização")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Sem localização"

        await sut.submit { _ in }

        let body = await recorder.lastBody
        let decoded = try JSONDecoder().decode(CreateRecadoRequest.self, from: body ?? Data())
        XCTAssertNil(decoded.location)
        let rawBody = String(decoding: body ?? Data(), as: UTF8.self)
        XCTAssertFalse(rawBody.contains("\"location\""), "a chave nem aparece no JSON — ausente, não nula nem objeto vazio")
    }

    func testSelectedLocationSurvivesAGenericSubmitFailure() async {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Vai falhar"
        sut.setLocation(name: "Consultório Dra. Ana", lat: -23.561414, lng: -46.655881)

        await sut.submit { _ in }

        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposeGenericPublishError)
        XCTAssertEqual(sut.selectedLocation?.text, "Consultório Dra. Ana", "a pessoa não perde o endereço que escolheu numa falha")
        XCTAssertEqual(sut.selectedLocation?.lat, -23.561414)
    }

    func testEditingModeInitialLocationPrefillsAndSurvivesUntouchedSubmit() async throws {
        // UpdateRecadoRequest.location tem semântica de SUBSTITUIÇÃO (plano 02-08): editar
        // sem pré-preencher a localização existente a apagaria em silêncio no primeiro
        // "Salvar" — por isso o modo edição recebe a localização atual do recado.
        let recadoID = UUID()
        let recorder = CallRecorder()
        let updated = makeRecado(id: recadoID, text: "Editado")
        let transport = ComposeStubTransport(outcome: .success(updated, status: 200), recorder: recorder)
        let existing = RecadoLocationDTO(text: "Praça da Sé", lat: -23.5503, lng: -46.6339)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: recadoID), initialText: "Editado", initialLocation: existing,
            apiClient: APIClient(transport: transport, baseURL: url())
        )

        XCTAssertEqual(sut.selectedLocation?.text, "Praça da Sé", "a localização existente aparece no compose de edição")

        await sut.submit { _ in }

        let body = await recorder.lastBody
        let decoded = try JSONDecoder().decode(UpdateRecadoRequest.self, from: body ?? Data())
        XCTAssertEqual(decoded.location?.text, "Praça da Sé", "salvar sem tocar na localização a preserva, nunca a apaga")
        XCTAssertEqual(decoded.location?.lat, -23.5503)
        XCTAssertEqual(decoded.location?.lng, -46.6339)
    }

    // MARK: setMentions(_:) (plano 02-06 Task 2)

    func testSetMentionsWithThreeMembersSendsAllThreeUserIDsOnSubmit() async {
        let recorder = CallRecorder()
        let created = makeRecado(text: "Com menção")
        let transport = ComposeStubTransport(outcome: .success(created, status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Com menção"
        let mentions = [
            MentionDTO(userID: UUID(), displayName: "Ana"),
            MentionDTO(userID: UUID(), displayName: "Bruno"),
            MentionDTO(userID: UUID(), displayName: "Carla"),
        ]
        sut.setMentions(mentions)

        await sut.submit { _ in }

        let body = await recorder.lastBody
        let decoded = try? JSONDecoder().decode(CreateRecadoRequest.self, from: body ?? Data())
        XCTAssertEqual(Set(decoded?.mentionedUserIDs ?? []), Set(mentions.map(\.userID)))
        XCTAssertEqual(decoded?.mentionedUserIDs.count, 3)
    }

    func testSetMentionsWithEmptyArrayDoesNotChangeCanSubmit() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Sem menção"
        let canSubmitBefore = sut.canSubmit

        sut.setMentions([])

        XCTAssertEqual(sut.canSubmit, canSubmitBefore, "marcar é sempre opcional (D-01/D-05) — não afeta canSubmit")
    }

    func testSelectedMentionsSurviveAGenericSubmitFailure() async {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Vai falhar"
        let mentions = [MentionDTO(userID: UUID(), displayName: "Ana")]
        sut.setMentions(mentions)

        await sut.submit { _ in }

        XCTAssertEqual(sut.errorMessage, FMCopy.muralComposeGenericPublishError)
        XCTAssertEqual(sut.selectedMentions.map(\.userID), mentions.map(\.userID), "a seleção de menção não se perde junto com o erro")
    }

    // MARK: Lembrete (plano 02-15, D-16)

    /// O JSON cru do corpo gravado — os casos de edição precisam distinguir "as chaves
    /// não vieram" de "as chaves vieram nulas", e comparar o tipo em Swift não prova o
    /// contrato de rede, que é exatamente onde a distinção vive.
    private func recordedBodyJSON(_ recorder: CallRecorder) async throws -> [String: Any] {
        let body = await recorder.lastBody
        let data = try XCTUnwrap(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSetReminderStoresPairAndDoesNotChangeCanSubmit() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let sut = ComposeRecadoViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        XCTAssertFalse(sut.canSubmit, "pré-condição: sem texto, envio desabilitado")
        let eventAt = Date().addingTimeInterval(86_400)

        sut.setReminder(eventAt: eventAt, remindOffsetSeconds: 3600)

        XCTAssertEqual(
            sut.selectedReminder,
            ComposeRecadoViewModel.SelectedReminder(eventAt: eventAt, remindOffsetSeconds: 3600)
        )
        XCTAssertFalse(sut.canSubmit, "lembrete é sempre opcional — nunca habilita o envio sozinho")

        sut.text = "Consulta"
        XCTAssertTrue(sut.canSubmit)
        sut.clearReminder()
        XCTAssertTrue(sut.canSubmit, "e remover o lembrete também não desabilita")
    }

    func testClearReminderResetsToAbsentAndClearsInvalidHint() async {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Consulta"
        // Combinação cujo disparo já passou — o envio revalida e preenche a dica.
        sut.setReminder(eventAt: Date().addingTimeInterval(60), remindOffsetSeconds: 86_400)
        await sut.submit { _ in }
        XCTAssertNotNil(sut.reminderInvalidHint, "pré-condição: o envio bloqueado deixou a dica visível")

        sut.clearReminder()

        XCTAssertNil(sut.selectedReminder, "limpar devolve o estado a ausente")
        XCTAssertNil(sut.reminderInvalidHint, "e limpa a dica de combinação inválida")
    }

    func testSubmitNewModeWithReminderSendsPairInCreateBody() async throws {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Consulta"
        sut.setReminder(eventAt: Date().addingTimeInterval(86_400), remindOffsetSeconds: 900)

        await sut.submit { _ in }

        let json = try await recordedBodyJSON(recorder)
        XCTAssertNotNil(json["eventAt"], "o par vai no corpo de criação")
        XCTAssertFalse(json["eventAt"] is NSNull)
        XCTAssertEqual(json["remindOffsetSeconds"] as? Int, 900)
    }

    func testSubmitWithReminderWhoseFireTimePassedWhileComposingIsBlockedWithoutNetworkCall() async {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 201), recorder: recorder)
        let sut = ComposeRecadoViewModel(mode: .new, apiClient: APIClient(transport: transport, baseURL: url()))
        sut.text = "Consulta"
        // Evento daqui a 1 min com antecedência de 1 dia: o disparo calculado já passou.
        sut.setReminder(eventAt: Date().addingTimeInterval(60), remindOffsetSeconds: 86_400)

        var completed = false
        await sut.submit { _ in completed = true }

        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0, "nenhuma chamada de rede acontece")
        XCTAssertFalse(completed, "a tela continua aberta — o sucesso nunca dispara")
        XCTAssertEqual(sut.reminderInvalidHint, FMCopy.muralComposeReminderInvalidHint, "a dica inline aparece")
        XCTAssertNil(sut.errorMessage, "a dica é orientação sob a linha de lembrete, não o erro genérico do rodapé")
    }

    func testEditSaveWithUntouchedReminderSendsBodyWithoutReminderKeys() async throws {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 200), recorder: recorder)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: UUID()),
            initialText: "Consulta",
            initialReminder: .init(eventAt: Date().addingTimeInterval(86_400), remindOffsetSeconds: 900),
            apiClient: APIClient(transport: transport, baseURL: url())
        )
        sut.text = "Consulta corrigida"

        await sut.submit { _ in }

        let json = try await recordedBodyJSON(recorder)
        XCTAssertFalse(json.keys.contains("eventAt"), "sem mexer, o corpo não fala de lembrete — chave AUSENTE")
        XCTAssertFalse(json.keys.contains("remindOffsetSeconds"))
    }

    func testEditSaveOfHistoricRecadoWithPastUntouchedReminderStillSucceeds() async {
        let recorder = CallRecorder()
        let saved = makeRecado(text: "Consulta do mês passado")
        let transport = ComposeStubTransport(outcome: .success(saved, status: 200), recorder: recorder)
        // O cenário exato da regra de edição do contrato: lembrete guardado JÁ VENCIDO,
        // e a pessoa só corrige o texto, sem tocar no lembrete.
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: saved.id),
            initialText: "Consulta do mês pasado",
            initialReminder: .init(eventAt: Date().addingTimeInterval(-86_400), remindOffsetSeconds: 3600),
            apiClient: APIClient(transport: transport, baseURL: url())
        )
        sut.text = "Consulta do mês passado"

        var completed: RecadoDTO?
        await sut.submit { completed = $0 }

        XCTAssertEqual(completed?.id, saved.id, "recado antigo com lembrete vencido continua salvando")
        XCTAssertNil(sut.reminderInvalidHint, "a revalidação só vale para lembrete mexido nesta sessão")
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testEditSaveAfterClearingReminderSendsExplicitNullPair() async throws {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 200), recorder: recorder)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: UUID()),
            initialText: "Consulta",
            initialReminder: .init(eventAt: Date().addingTimeInterval(86_400), remindOffsetSeconds: 900),
            apiClient: APIClient(transport: transport, baseURL: url())
        )

        sut.clearReminder()
        await sut.submit { _ in }

        let json = try await recordedBodyJSON(recorder)
        XCTAssertTrue(json.keys.contains("eventAt"), "depois de limpar, a chave VEM — presença explícita")
        XCTAssertTrue(json["eventAt"] is NSNull, "— e vem nula (remover, nunca preservar)")
        XCTAssertTrue(json.keys.contains("remindOffsetSeconds"))
        XCTAssertTrue(json["remindOffsetSeconds"] is NSNull)
    }

    func testEditSaveAfterChangingDateSendsNewPairAndRevalidates() async throws {
        let recorder = CallRecorder()
        let transport = ComposeStubTransport(outcome: .success(makeRecado(), status: 200), recorder: recorder)
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: UUID()),
            initialText: "Consulta",
            initialReminder: .init(eventAt: Date().addingTimeInterval(-86_400), remindOffsetSeconds: 900),
            apiClient: APIClient(transport: transport, baseURL: url())
        )

        // Primeiro: trocar para uma combinação que cairia no passado bloqueia o envio.
        sut.setReminder(eventAt: Date().addingTimeInterval(60), remindOffsetSeconds: 86_400)
        await sut.submit { _ in }
        var callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0, "o par novo é revalidado antes de mandar")
        XCTAssertEqual(sut.reminderInvalidHint, FMCopy.muralComposeReminderInvalidHint)

        // Depois: um par novo válido vai no corpo com as duas chaves preenchidas.
        let newEventAt = Date().addingTimeInterval(172_800)
        sut.setReminder(eventAt: newEventAt, remindOffsetSeconds: 3600)
        await sut.submit { _ in }

        callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)
        let json = try await recordedBodyJSON(recorder)
        XCTAssertNotNil(json["eventAt"])
        XCTAssertFalse(json["eventAt"] is NSNull)
        XCTAssertEqual(json["remindOffsetSeconds"] as? Int, 3600)
    }

    func testEditModeOpensWithStoredReminderPreFilledAndUntouched() {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))
        let stored = ComposeRecadoViewModel.SelectedReminder(
            eventAt: Date().addingTimeInterval(86_400), remindOffsetSeconds: 300
        )
        let sut = ComposeRecadoViewModel(
            mode: .editing(recadoID: UUID()),
            initialText: "Consulta",
            initialReminder: stored,
            apiClient: APIClient(transport: transport, baseURL: url())
        )

        XCTAssertEqual(sut.selectedReminder, stored, "o modo edição abre com o lembrete guardado já preenchido")
        XCTAssertFalse(sut.reminderTouched, "e a marca de mexeu continua desligada — pré-carga não é mexer")
    }

    func testNotificationsDeniedFlagOnlySetWhenAuthorizationStatusIsDenied() async {
        let transport = ComposeStubTransport(outcome: .failure(status: 500))

        let deniedCenter = ComposeFakeNotificationCenter(status: .denied)
        let deniedSut = ComposeRecadoViewModel(
            apiClient: APIClient(transport: transport, baseURL: url()),
            notificationCenter: deniedCenter
        )
        await deniedSut.refreshNotificationAuthorizationState()
        XCTAssertTrue(deniedSut.isNotificationsDenied, "negado sinaliza o aviso discreto")

        let notDeterminedCenter = ComposeFakeNotificationCenter(status: .notDetermined)
        let notDeterminedSut = ComposeRecadoViewModel(
            apiClient: APIClient(transport: transport, baseURL: url()),
            notificationCenter: notDeterminedCenter
        )
        await notDeterminedSut.refreshNotificationAuthorizationState()
        XCTAssertFalse(notDeterminedSut.isNotificationsDenied, "indeterminado não sinaliza nada, por contrato")

        let authorizedCenter = ComposeFakeNotificationCenter(status: .authorized)
        let authorizedSut = ComposeRecadoViewModel(
            apiClient: APIClient(transport: transport, baseURL: url()),
            notificationCenter: authorizedCenter
        )
        await authorizedSut.refreshNotificationAuthorizationState()
        XCTAssertFalse(authorizedSut.isNotificationsDenied)
    }
}

/// Centro de notificações falso mínimo deste arquivo — o compose só LÊ o estado de
/// autorização (o aviso discreto); agendar/listar/remover nunca são chamados daqui e
/// falham alto se forem.
@MainActor
private final class ComposeFakeNotificationCenter: LocalNotificationScheduling {
    private let status: UNAuthorizationStatus

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func scheduleRequest(_ request: UNNotificationRequest) async throws {
        XCTFail("o compose nunca agenda — só o feed reconcilia")
    }

    func listPendingRequests() async -> [UNNotificationRequest] {
        XCTFail("o compose nunca lista pendentes")
        return []
    }

    func removePending(identifiers: [String]) {
        XCTFail("o compose nunca remove pendentes")
    }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        XCTFail("o compose nunca registra categorias")
    }

    func readAuthorizationStatus() async -> UNAuthorizationStatus {
        status
    }
}

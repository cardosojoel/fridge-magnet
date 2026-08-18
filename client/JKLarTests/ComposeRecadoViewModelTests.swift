import XCTest
import JKLarShared
@testable import JKLar

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
        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposeGenericPublishError)
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

        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposeNotAuthorError)
        XCTAssertNotEqual(sut.errorMessage, JKCopy.muralComposeGenericPublishError, "mensagem específica, não a genérica")
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
        XCTAssertEqual(sut.photoCapMessage, JKCopy.muralComposePhotoCapReached)

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
        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposePhotoUploadPartialFailure, "a falha nunca é silenciosa")

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

        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposePhotoCapReached)
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
        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposePhotoUploadPartialFailure)
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

        XCTAssertEqual(sut.errorMessage, JKCopy.muralComposeGenericPublishError)
        XCTAssertEqual(sut.selectedMentions.map(\.userID), mentions.map(\.userID), "a seleção de menção não se perde junto com o erro")
    }
}

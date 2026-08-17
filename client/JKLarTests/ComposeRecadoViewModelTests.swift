import XCTest
import JKLarShared
@testable import JKLar

/// Registrador simples de chamada (método + caminho) — usado só para o comportamento "modo
/// edição chama a rota de atualização, nunca a de criação" precisar de uma prova mais forte
/// do que o status HTTP devolvido. `actor` para poder ser lido de fora com segurança.
private actor CallRecorder {
    private(set) var lastMethod: String?
    private(set) var lastPath: String?
    private(set) var callCount = 0

    func record(method: String, path: String) {
        lastMethod = method
        lastPath = path
        callCount += 1
    }
}

/// Transporte falso, imediato — dono deste arquivo, sem estado compartilhado com stubs de
/// outros arquivos de teste (mesmo padrão de `OnboardingStubTransport`).
private struct ComposeStubTransport: APIClientTransport {
    enum Outcome {
        case success(RecadoDTO, status: Int)
        case apiError(APIErrorCode, status: Int)
        case failure(status: Int)
    }

    let outcome: Outcome
    var recorder: CallRecorder?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder?.record(method: request.httpMethod ?? "GET", path: request.url?.path ?? "")
        let url = request.url!
        switch outcome {
        case .success(let recado, let status):
            let data = try JSONEncoder().encode(recado)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try JSONEncoder().encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
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
        let data = try JSONEncoder().encode(recado)
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
}

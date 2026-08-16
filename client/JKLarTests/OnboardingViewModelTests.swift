import XCTest
import JKLarShared
@testable import JKLar

/// Transporte falso, imediato — não precisa simular renovação de 401 nem concorrência
/// (`OnboardingViewModel` só chama `createHousehold`/`updateProfile`, nunca uma rota que
/// dependa do ciclo de refresh do plano 01-05). Dono deste arquivo, sem estado compartilhado
/// com `APIClientRefreshTests.FakeTransport`.
private struct OnboardingStubTransport: APIClientTransport {
    enum Outcome {
        case success(HouseholdDTO)
        case failure(status: Int)
    }

    let outcome: Outcome

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        switch outcome {
        case .success(let household):
            let data = try JSONEncoder().encode(household)
            return (data, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Transporte que bloqueia dentro de `send(_:)` até `release()` ser chamado — usado só para
/// provar `canSubmitCreate == false` enquanto uma criação está genuinamente em voo, sem
/// depender de timing/sleep: o teste espera deterministicamente até `isWaiting` virar `true`
/// (o transporte já suspendeu dentro do request em voo) antes de afirmar qualquer coisa.
private actor GatedTransport: APIClientTransport {
    private let outcome: OnboardingStubTransport.Outcome
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    init(outcome: OnboardingStubTransport.Outcome) {
        self.outcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await waitUntilReleased()
        let url = request.url!
        switch outcome {
        case .success(let household):
            let data = try JSONEncoder().encode(household)
            return (data, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
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

/// Cobre os cinco primeiros itens testáveis em isolamento (sem SwiftUI/simulador) do
/// `<behavior>` da Task 1 do plano 01-07: habilitação de `canSubmitCreate`, corte em 40
/// caracteres, estado em voo, sucesso preenchendo `createdHousehold`, e falha preservando o
/// texto digitado com a cópia genérica de `JKCopy`.
@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeSUT(outcome: OnboardingStubTransport.Outcome) -> OnboardingViewModel {
        let transport = OnboardingStubTransport(outcome: outcome)
        let client = APIClient(transport: transport, baseURL: url())
        return OnboardingViewModel(apiClient: client)
    }

    func testCanSubmitCreateFalseWhenNameIsEmptyOrOnlyWhitespace() {
        let sut = makeSUT(outcome: .failure(status: 500))
        XCTAssertFalse(sut.canSubmitCreate, "campo vazio nunca habilita o CTA")

        sut.houseName = "   "
        XCTAssertFalse(sut.canSubmitCreate, "só espaços não conta como preenchido")
    }

    func testCanSubmitCreateTrueFromFirstNonWhitespaceCharacter() {
        let sut = makeSUT(outcome: .failure(status: 500))
        sut.houseName = "F"
        XCTAssertTrue(sut.canSubmitCreate, "o primeiro caractere não-branco já habilita o CTA")
    }

    func testCanSubmitCreateFalseWhileSubmitting() async {
        let household = HouseholdDTO(id: UUID(), name: "Família Silva", memberCount: 1, myRole: .admin)
        let transport = GatedTransport(outcome: .success(household))
        let client = APIClient(transport: transport, baseURL: url())
        let sut = OnboardingViewModel(apiClient: client)
        sut.houseName = "Família Silva"
        XCTAssertTrue(sut.canSubmitCreate)

        let submitTask = Task { await sut.submitCreate() }

        while await !transport.isWaiting {
            await Task.yield()
        }
        XCTAssertFalse(sut.canSubmitCreate, "canSubmitCreate é falso enquanto a criação está em voo")

        await transport.release()
        await submitTask.value
        XCTAssertNotNil(sut.createdHousehold, "depois de liberado, o request completa normalmente")
    }

    func testHouseNameInputCapsAt40Characters() {
        let sut = makeSUT(outcome: .failure(status: 500))
        sut.houseName = String(repeating: "A", count: 50)
        XCTAssertEqual(sut.houseName.count, OnboardingViewModel.maxHouseholdNameLength)
        XCTAssertEqual(sut.houseName, String(repeating: "A", count: 40))
    }

    func testSuccessfulCreationSetsCreatedHousehold() async {
        let household = HouseholdDTO(id: UUID(), name: "Família Silva", memberCount: 1, myRole: .admin)
        let sut = makeSUT(outcome: .success(household))
        sut.houseName = "Família Silva"

        await sut.submitCreate()

        XCTAssertEqual(sut.createdHousehold?.name, "Família Silva")
        XCTAssertEqual(sut.createdHousehold?.myRole, .admin)
        XCTAssertNil(sut.errorMessage)
        XCTAssertFalse(sut.isSubmitting)
    }

    func testFailedCreationPreservesTypedTextAndShowsGenericError() async {
        let sut = makeSUT(outcome: .failure(status: 500))
        sut.houseName = "Família Silva"

        await sut.submitCreate()

        XCTAssertEqual(sut.houseName, "Família Silva", "o texto digitado nunca é perdido numa falha")
        XCTAssertEqual(sut.errorMessage, JKCopy.onboardingCreateGenericError)
        XCTAssertNil(sut.createdHousehold)
        XCTAssertFalse(sut.isSubmitting)
    }
}

import XCTest
import FridgeMagnetShared
@testable import FridgeMagnet

/// Transporte falso, imediato — dono deste arquivo, sem estado compartilhado com
/// `APIClientRefreshTests.FakeTransport`/`OnboardingViewModelTests.OnboardingStubTransport`
/// (mesmo padrão dos dois).
private struct JoinStubTransport: APIClientTransport {
    enum Outcome {
        case success(HouseholdDTO)
        case apiError(APIErrorCode, status: Int)
    }

    let outcome: Outcome

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        switch outcome {
        case .success(let household):
            let data = try ServerWire.encoder.encode(household)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try ServerWire.encoder.encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Transporte que bloqueia dentro de `send(_:)` até `release()` ser chamado — mesmo padrão
/// de `GatedTransport` em `OnboardingViewModelTests.swift` (plano 01-07), usado aqui para
/// provar `canSubmit == false` enquanto uma validação está genuinamente em voo, sem
/// depender de `Task.sleep`/timing.
private actor JoinGatedTransport: APIClientTransport {
    private let outcome: JoinStubTransport.Outcome
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false

    init(outcome: JoinStubTransport.Outcome) {
        self.outcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await waitUntilReleased()
        let url = request.url!
        switch outcome {
        case .success(let household):
            let data = try ServerWire.encoder.encode(household)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try ServerWire.encoder.encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
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
/// `<behavior>` da Task 1 do plano 01-09: habilitação de `canSubmit`, normalização +
/// filtro de alfabeto, estado em voo, e a tradução de
/// `inviteInvalid`/`inviteExpired`/`householdFull` preservando o código digitado.
@MainActor
final class JoinByCodeViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeSUT(outcome: JoinStubTransport.Outcome) -> JoinByCodeViewModel {
        let transport = JoinStubTransport(outcome: outcome)
        let client = APIClient(transport: transport, baseURL: url())
        return JoinByCodeViewModel(apiClient: client)
    }

    func testCanSubmitFalseFrom0To5CharactersAndTrueAtExactly6() {
        let sut = makeSUT(outcome: .apiError(.inviteInvalid, status: 404))
        XCTAssertFalse(sut.canSubmit, "campo vazio nunca habilita o CTA")

        sut.code = "ABC23"
        XCTAssertEqual(sut.code.count, 5)
        XCTAssertFalse(sut.canSubmit, "5 caracteres ainda não habilita")

        sut.code = "ABC234"
        XCTAssertEqual(sut.code.count, 6)
        XCTAssertTrue(sut.canSubmit, "exatamente 6 caracteres habilita")
    }

    func testInputNormalizesToUppercaseAndFiltersInviteAlphabet() {
        let sut = makeSUT(outcome: .apiError(.inviteInvalid, status: 404))
        sut.code = "ab-o0i1l!"
        // Alfabeto sem 0/O/1/I/L (mesmo do InviteCodeGenerator do backend, plano 01-06) —
        // só "AB" sobra dos caracteres digitados, já em maiúsculas.
        XCTAssertEqual(sut.code, "AB")
    }

    func testCanSubmitFalseWhileValidationInFlight() async {
        let household = HouseholdDTO(id: UUID(), name: "Família Silva", memberCount: 2, myRole: .adulto)
        let transport = JoinGatedTransport(outcome: .success(household))
        let client = APIClient(transport: transport, baseURL: url())
        let sut = JoinByCodeViewModel(apiClient: client)
        sut.code = "ABC234"
        XCTAssertTrue(sut.canSubmit)

        let submitTask = Task { await sut.submit() }

        while await !transport.isWaiting {
            await Task.yield()
        }
        XCTAssertFalse(sut.canSubmit, "canSubmit é falso enquanto a validação está em voo")

        await transport.release()
        await submitTask.value
        XCTAssertNotNil(sut.joinedHousehold, "depois de liberado, o request completa normalmente")
    }

    func testInvalidAndExpiredCodesProduceSameMessageAndPreserveTypedCode() async {
        for (code, status) in [(APIErrorCode.inviteInvalid, 404), (APIErrorCode.inviteExpired, 410)] {
            let sut = makeSUT(outcome: .apiError(code, status: status))
            sut.code = "ABC234"

            await sut.submit()

            XCTAssertEqual(sut.code, "ABC234", "o código digitado nunca é perdido numa falha")
            XCTAssertEqual(sut.errorMessage, FMCopy.onboardingInvalidCodeError)
            XCTAssertNil(sut.joinedHousehold)
            XCTAssertFalse(sut.isSubmitting)
        }
    }

    func testHouseholdFullProducesVerbatimMessageAndPreservesTypedCode() async {
        let sut = makeSUT(outcome: .apiError(.householdFull, status: 409))
        sut.code = "ABC234"

        await sut.submit()

        XCTAssertEqual(sut.code, "ABC234", "o código digitado nunca é perdido numa falha")
        XCTAssertEqual(sut.errorMessage, "Esta casa já atingiu o limite de 10 membros.")
        XCTAssertEqual(sut.submitError, .householdFull)
    }
}

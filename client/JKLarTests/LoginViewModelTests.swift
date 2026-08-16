import XCTest
@testable import JKLar

/// Sincroniza uma fake de sign-in com o teste: `wait()` suspende até `open()` ser chamado,
/// permitindo inspecionar o estado do `LoginViewModel` enquanto o "SDK" ainda está em voo —
/// sem isso, um fake que retorna na hora nunca deixaria a asserção de `isInProgress`/
/// `isDisabled` observar um estado real de "em andamento".
actor SignalGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

struct FakeGoogleSignInService: GoogleSignInServiceProtocol {
    var gate: SignalGate?
    var result: Result<GoogleSignInResult, GoogleSignInError>

    func signIn() async -> Result<GoogleSignInResult, GoogleSignInError> {
        if let gate { await gate.wait() }
        return result
    }
}

struct FakeMicrosoftSignInService: MicrosoftSignInServiceProtocol {
    var gate: SignalGate?
    var result: Result<MicrosoftSignInResult, MicrosoftSignInError>

    func signIn() async -> Result<MicrosoftSignInResult, MicrosoftSignInError> {
        if let gate { await gate.wait() }
        return result
    }
}

/// Plano 01-08 Task 3 — estados por provedor com serviços de sign-in falsos. Nenhum teste
/// abre janela de consentimento real; `AppleSignInService.result(from:)` é exercitado com um
/// `Result<AppleSignInResult, AppleSignInError>` construído diretamente (o mesmo tipo que o
/// `onCompletion` do `SignInWithAppleButton` produziria), sem `ASAuthorizationController`.
@MainActor
final class LoginViewModelTests: XCTestCase {
    // MARK: Estado inicial

    func testInitialStateHasNoProviderInProgressAndNoError() {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        for provider in LoginViewModel.Provider.allCases {
            XCTAssertFalse(viewModel.isInProgress(provider))
            XCTAssertFalse(viewModel.isDisabled(provider))
        }
        XCTAssertNil(viewModel.errorMessage)
    }

    // MARK: Apple — beginApple roda de forma síncrona no toque

    func testBeginAppleShowsProgressOnAppleAndDisablesTheOtherTwo() {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        viewModel.beginApple()

        XCTAssertTrue(viewModel.isInProgress(.apple))
        XCTAssertFalse(viewModel.isDisabled(.apple), "o próprio botão em andamento não conta como 'desabilitado pelos outros'")
        XCTAssertTrue(viewModel.isDisabled(.google))
        XCTAssertTrue(viewModel.isDisabled(.microsoft))
    }

    func testAppleCompletionSuccessCallsExchangeWithTokenAndClearsProgress() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )
        viewModel.beginApple()

        var exchangedToken: String?
        var exchangedDisplayName: String?
        await viewModel.handleAppleCompletion(
            .success(AppleSignInResult(identityToken: "apple-token", displayName: "Joel")),
            exchange: { token, displayName in
                exchangedToken = token
                exchangedDisplayName = displayName
            }
        )

        XCTAssertEqual(exchangedToken, "apple-token")
        XCTAssertEqual(exchangedDisplayName, "Joel")
        XCTAssertFalse(viewModel.isInProgress(.apple))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAppleCompletionCancelledReturnsToInitialStateWithoutError() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )
        viewModel.beginApple()

        await viewModel.handleAppleCompletion(.failure(.cancelled), exchange: { _, _ in
            XCTFail("cancelamento não pode chamar exchange")
        })

        XCTAssertFalse(viewModel.isInProgress(.apple))
        XCTAssertFalse(viewModel.isDisabled(.google))
        XCTAssertNil(viewModel.errorMessage, "cancelamento pelo usuário nunca mostra mensagem de erro")
    }

    func testAppleCompletionFailureShowsErrorMessage() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )
        viewModel.beginApple()

        await viewModel.handleAppleCompletion(.failure(.missingIdentityToken), exchange: { _, _ in })

        XCTAssertFalse(viewModel.isInProgress(.apple))
        XCTAssertEqual(viewModel.errorMessage, JKCopy.loginErrorMessage)
    }

    func testExchangeFailureAfterAppleSuccessShowsErrorMessage() async {
        struct ExchangeError: Error {}
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )
        viewModel.beginApple()

        await viewModel.handleAppleCompletion(
            .success(AppleSignInResult(identityToken: "apple-token", displayName: nil)),
            exchange: { _, _ in throw ExchangeError() }
        )

        XCTAssertFalse(viewModel.isInProgress(.apple))
        XCTAssertEqual(viewModel.errorMessage, JKCopy.loginErrorMessage)
    }

    // MARK: Google — em andamento de verdade (SignalGate), desabilita os outros dois

    func testTappingGoogleShowsProgressOnGoogleAndDisablesTheOtherTwo() async {
        let gate = SignalGate()
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(
                gate: gate,
                result: .success(GoogleSignInResult(identityToken: "google-token", displayName: "Joel"))
            ),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        let task = Task { await viewModel.signInWithGoogle(exchange: { _, _ in }) }
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewModel.isInProgress(.google))
        XCTAssertFalse(viewModel.isDisabled(.google))
        XCTAssertTrue(viewModel.isDisabled(.apple))
        XCTAssertTrue(viewModel.isDisabled(.microsoft))

        await gate.open()
        await task.value

        XCTAssertFalse(viewModel.isInProgress(.google))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testGoogleSignInSuccessCallsExchangeWithToken() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(
                result: .success(GoogleSignInResult(identityToken: "google-token", displayName: "Joel"))
            ),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        var exchangedToken: String?
        await viewModel.signInWithGoogle(exchange: { token, _ in exchangedToken = token })

        XCTAssertEqual(exchangedToken, "google-token")
        XCTAssertFalse(viewModel.isInProgress(.google))
    }

    func testGoogleSignInCancellationReturnsToInitialStateWithoutError() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        await viewModel.signInWithGoogle(exchange: { _, _ in
            XCTFail("cancelamento não pode chamar exchange")
        })

        XCTAssertFalse(viewModel.isInProgress(.google))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testGoogleSignInFailureShowsErrorMessage() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.missingIdentityToken)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        await viewModel.signInWithGoogle(exchange: { _, _ in })

        XCTAssertFalse(viewModel.isInProgress(.google))
        XCTAssertEqual(viewModel.errorMessage, JKCopy.loginErrorMessage)
    }

    // MARK: Microsoft — mesmos cinco cenários

    func testTappingMicrosoftShowsProgressOnMicrosoftAndDisablesTheOtherTwo() async {
        let gate = SignalGate()
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(
                gate: gate,
                result: .success(MicrosoftSignInResult(identityToken: "ms-token", displayName: "Joel"))
            )
        )

        let task = Task { await viewModel.signInWithMicrosoft(exchange: { _, _ in }) }
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(viewModel.isInProgress(.microsoft))
        XCTAssertFalse(viewModel.isDisabled(.microsoft))
        XCTAssertTrue(viewModel.isDisabled(.apple))
        XCTAssertTrue(viewModel.isDisabled(.google))

        await gate.open()
        await task.value

        XCTAssertFalse(viewModel.isInProgress(.microsoft))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testMicrosoftSignInSuccessCallsExchangeWithToken() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(
                result: .success(MicrosoftSignInResult(identityToken: "ms-token", displayName: "Joel"))
            )
        )

        var exchangedToken: String?
        var exchangedDisplayName: String?
        await viewModel.signInWithMicrosoft(exchange: { token, displayName in
            exchangedToken = token
            exchangedDisplayName = displayName
        })

        XCTAssertEqual(exchangedToken, "ms-token")
        XCTAssertEqual(exchangedDisplayName, "Joel")
        XCTAssertFalse(viewModel.isInProgress(.microsoft))
    }

    func testMicrosoftSignInCancellationReturnsToInitialStateWithoutError() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.cancelled))
        )

        await viewModel.signInWithMicrosoft(exchange: { _, _ in
            XCTFail("cancelamento não pode chamar exchange")
        })

        XCTAssertFalse(viewModel.isInProgress(.microsoft))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testMicrosoftSignInFailureShowsErrorMessage() async {
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(result: .failure(.cancelled)),
            microsoftService: FakeMicrosoftSignInService(result: .failure(.missingIdentityToken))
        )

        await viewModel.signInWithMicrosoft(exchange: { _, _ in })

        XCTAssertFalse(viewModel.isInProgress(.microsoft))
        XCTAssertEqual(viewModel.errorMessage, JKCopy.loginErrorMessage)
    }

    // MARK: Um provedor em andamento nunca deixa um segundo começar

    func testSecondProviderTapWhileFirstInProgressIsIgnored() async {
        let gate = SignalGate()
        let viewModel = LoginViewModel(
            googleService: FakeGoogleSignInService(
                gate: gate,
                result: .success(GoogleSignInResult(identityToken: "google-token", displayName: nil))
            ),
            microsoftService: FakeMicrosoftSignInService(result: .success(MicrosoftSignInResult(identityToken: "ms-token", displayName: nil)))
        )

        let firstTask = Task { await viewModel.signInWithGoogle(exchange: { _, _ in }) }
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(viewModel.isInProgress(.google))

        // Enquanto o Google está em voo, um toque no Microsoft não pode iniciar um segundo
        // fluxo — o guard `inProgressProvider == nil` de `signInWithMicrosoft` barra isso.
        await viewModel.signInWithMicrosoft(exchange: { _, _ in
            XCTFail("um segundo provedor não pode chamar exchange enquanto o primeiro está em andamento")
        })
        XCTAssertTrue(viewModel.isInProgress(.google), "o provedor em andamento continua sendo o Google")

        await gate.open()
        await firstTask.value
    }
}

import Foundation
import JKLarShared
import Observation

/// Estado de login por provedor, independente de SwiftUI — é o que torna
/// `LoginViewModelTests` possível sem renderizar nenhuma view real. `LoginView` só
/// reflete `inProgressProvider`/`errorMessage`; toda decisão de estado mora aqui.
///
/// `exchange`, passado por `LoginView` a cada chamada em vez de guardado como propriedade,
/// mantém este tipo desacoplado de `SessionStore`/`APIClient` — os testes substituem por um
/// closure fake que só grava a chamada, sem precisar de `FakeTransport`/rede nenhuma.
@MainActor
@Observable
final class LoginViewModel {
    enum Provider: CaseIterable, Sendable {
        case apple
        case google
        case microsoft
    }

    private(set) var inProgressProvider: Provider?
    private(set) var errorMessage: String?

    private let googleService: any GoogleSignInServiceProtocol
    private let microsoftService: any MicrosoftSignInServiceProtocol

    init(
        googleService: any GoogleSignInServiceProtocol = GoogleSignInService(),
        microsoftService: any MicrosoftSignInServiceProtocol = MicrosoftSignInService()
    ) {
        self.googleService = googleService
        self.microsoftService = microsoftService
    }

    /// `true` só para o provedor tocado — o botão dele troca o rótulo por `ProgressView`
    /// (01-UI-SPEC.md "loading | login-buttons").
    func isInProgress(_ provider: Provider) -> Bool {
        inProgressProvider == provider
    }

    /// `true` para os outros dois enquanto um terceiro está em andamento — desabilitados,
    /// nunca escondidos.
    func isDisabled(_ provider: Provider) -> Bool {
        inProgressProvider != nil && inProgressProvider != provider
    }

    func clearError() {
        errorMessage = nil
    }

    /// Chamado de dentro do closure de configuração (`request in ...`) do
    /// `SignInWithAppleButton` — esse closure roda de forma síncrona no toque, antes de o
    /// fluxo nativo abrir, e é o único jeito de os outros dois botões desabilitarem já
    /// durante o prompt da Apple (que `onCompletion` só entrega depois de fechado).
    func beginApple() {
        guard inProgressProvider == nil else { return }
        inProgressProvider = .apple
        errorMessage = nil
    }

    func handleAppleCompletion(
        _ result: Result<AppleSignInResult, AppleSignInError>,
        exchange: (String, String?) async throws -> Void
    ) async {
        switch result {
        case .success(let signInResult):
            await complete(.apple, identityToken: signInResult.identityToken, displayName: signInResult.displayName, exchange: exchange)
        case .failure(.cancelled):
            // Cancelamento pelo usuário: volta ao estado inicial sem mensagem de erro.
            inProgressProvider = nil
        case .failure:
            inProgressProvider = nil
            errorMessage = JKCopy.loginErrorMessage
        }
    }

    func signInWithGoogle(exchange: (String, String?) async throws -> Void) async {
        guard inProgressProvider == nil else { return }
        inProgressProvider = .google
        errorMessage = nil

        switch await googleService.signIn() {
        case .success(let result):
            await complete(.google, identityToken: result.identityToken, displayName: result.displayName, exchange: exchange)
        case .failure(.cancelled):
            inProgressProvider = nil
        case .failure:
            inProgressProvider = nil
            errorMessage = JKCopy.loginErrorMessage
        }
    }

    func signInWithMicrosoft(exchange: (String, String?) async throws -> Void) async {
        guard inProgressProvider == nil else { return }
        inProgressProvider = .microsoft
        errorMessage = nil

        switch await microsoftService.signIn() {
        case .success(let result):
            await complete(.microsoft, identityToken: result.identityToken, displayName: result.displayName, exchange: exchange)
        case .failure(.cancelled):
            inProgressProvider = nil
        case .failure:
            inProgressProvider = nil
            errorMessage = JKCopy.loginErrorMessage
        }
    }

    private func complete(
        _ provider: Provider,
        identityToken: String,
        displayName: String?,
        exchange: (String, String?) async throws -> Void
    ) async {
        do {
            try await exchange(identityToken, displayName)
            inProgressProvider = nil
        } catch {
            inProgressProvider = nil
            errorMessage = JKCopy.loginErrorMessage
        }
    }
}

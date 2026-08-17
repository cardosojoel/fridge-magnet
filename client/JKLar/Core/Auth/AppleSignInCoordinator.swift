import AuthenticationServices
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Dirige o fluxo real de Sign in with Apple via `ASAuthorizationController` + delegate — o
/// caminho clássico do UIKit/AppKit, em vez do wrapper `SignInWithAppleButton` da SwiftUI.
///
/// Por que não o botão nativo da SwiftUI: no iOS Simulator, o `onCompletion` do
/// `SignInWithAppleButton` nunca é chamado, mesmo com o AuthKit registrando
/// "Successfully completed authorization" com credencial válida dentro do processo do app
/// (diagnosticado ao vivo em 2026-08-17 — a autorização chega ao processo, a ponte SwiftUI a
/// perde; três reproduções consecutivas com instrumentação em cada elo da cadeia). O caminho
/// por delegate usa outra tubulação de entrega e funciona nas duas plataformas; o request em
/// si continua vindo de `AppleSignInService.makeRequest()`, previsto exatamente para
/// contextos sem o controle nativo da SwiftUI.
@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<Result<ASAuthorization, Error>, Never>?
    // O controller não retém o delegate — sem esta referência forte durante o fluxo, o
    // coordinator poderia ser desalocado com o prompt nativo ainda aberto.
    private var activeController: ASAuthorizationController?

    /// Abre o prompt nativo e devolve o resultado no mesmo formato (`Result<ASAuthorization,
    /// Error>`) que o `onCompletion` do `SignInWithAppleButton` entregava — `LoginView`
    /// continua convergindo em `AppleSignInService.result(from:)` sem mudança de contrato.
    func signIn() async -> Result<ASAuthorization, Error> {
        // Um fluxo por vez: um segundo toque enquanto o prompt está aberto é impossível pela
        // UI (`LoginViewModel.beginApple()` já bloqueia), mas o guard mantém a invariante
        // localmente em vez de confiar só no chamador.
        if continuation != nil {
            return .failure(ASAuthorizationError(.canceled))
        }
        let controller = ASAuthorizationController(authorizationRequests: [AppleSignInService.makeRequest()])
        controller.delegate = self
        controller.presentationContextProvider = self
        activeController = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
        activeController = nil
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        finish(.failure(error))
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return keyWindow ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}

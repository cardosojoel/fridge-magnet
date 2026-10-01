import AuthenticationServices
import Foundation

/// Resultado do fluxo real de Sign in with Apple: o identity token assinado (D-12, usado uma
/// única vez para trocar por sessão no backend e descartado — nunca gravado em disco) e o
/// nome, que a Apple só entrega na primeira autorização do usuário para este app.
struct AppleSignInResult: Sendable {
    var identityToken: String
    var displayName: String?
}

enum AppleSignInError: Error, Equatable {
    case cancelled
    case missingIdentityToken
    case other(String)
}

/// Ponte entre o `SignInWithAppleButton` nativo do `LoginView` (D-01, 01-UI-SPEC.md) e o
/// contrato de domínio do FridgeMagnet.
///
/// O próprio `SignInWithAppleButton` da SwiftUI já cria e dirige, ao ser tocado, um
/// `ASAuthorizationController` configurado por `ASAuthorizationAppleIDProvider` — é esse o
/// "fluxo ASAuthorization real" que o botão abre. Este serviço não recria um segundo
/// controller (isso mostraria dois prompts de autorização para o mesmo toque); em vez disso
/// configura o escopo do request que o botão cria e extrai `(identityToken, fullName?)` do
/// resultado real que o botão devolve — é o que `LoginView` usa para chamar
/// `APIClient.createSession(provider: .apple, ...)`.
enum AppleSignInService {
    /// Escopo pedido ao usuário — nome e e-mail, entregues só na primeira autorização.
    static func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// Cria um request já configurado via `ASAuthorizationAppleIDProvider` diretamente —
    /// para qualquer contexto que precise disparar o fluxo sem o controle nativo da SwiftUI
    /// (ex.: um botão customizado em uma superfície futura sem `SignInWithAppleButton`
    /// disponível). Não é o caminho usado por `LoginView` hoje, que recebe o request já
    /// criado pelo próprio `SignInWithAppleButton`.
    static func makeRequest() -> ASAuthorizationAppleIDRequest {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configure(request)
        return request
    }

    /// Extrai `(identityToken, fullName?)` do resultado que `SignInWithAppleButton` devolve
    /// em `onCompletion`. Cancelamento pelo usuário mapeia para `.cancelled` (D: volta ao
    /// estado inicial sem mensagem de erro); qualquer outra falha vira `.other`.
    static func result(from authorizationResult: Result<ASAuthorization, Error>) -> Result<AppleSignInResult, AppleSignInError> {
        switch authorizationResult {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                return .failure(.missingIdentityToken)
            }
            let displayName = credential.fullName.flatMap { components -> String? in
                let formatted = PersonNameComponentsFormatter().string(from: components)
                return formatted.isEmpty ? nil : formatted
            }
            return .success(AppleSignInResult(identityToken: identityToken, displayName: displayName))
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return .failure(.cancelled)
            }
            return .failure(.other(error.localizedDescription))
        }
    }
}

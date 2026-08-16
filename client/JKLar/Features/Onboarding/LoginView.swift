import AuthenticationServices
import JKLarShared
import SwiftUI

/// Tela de login. D-01: Sign in with Apple aparece primeiro e é o único botão de provedor
/// nesta fatia — os botões de Google e Microsoft chegam no plano 01-08, na mesma ordem
/// definida por D-01 (Apple, depois Google, depois Microsoft). Não há botão inerte
/// desenhado aqui para provedores futuros.
///
/// O toque no `SignInWithAppleButton` nativo abre o fluxo `ASAuthorization` real; ao
/// concluir, `AppleSignInService.result(from:)` extrai `(identityToken, fullName?)` e
/// `SessionStore.signIn` troca isso por uma sessão do JK Lar (`APIClient.createSession`),
/// gravando no Keychain e atualizando o roteador de `RootView`.
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SessionStore.self) private var sessionStore

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: JKSpacing.xl) {
            Spacer(minLength: JKSpacing.xxxl)

            VStack(spacing: JKSpacing.sm) {
                Text(JKCopy.appName)
                    .font(JKTypography.display)
                    .multilineTextAlignment(.center)

                Text(JKCopy.loginTagline)
                    .font(JKTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let errorMessage {
                VStack(spacing: JKSpacing.sm) {
                    Text(errorMessage)
                        .font(JKTypography.label)
                        .foregroundStyle(JKColor.jkDestructive)
                        .multilineTextAlignment(.center)

                    Button(JKCopy.loginErrorRetry) {
                        self.errorMessage = nil
                    }
                    .font(JKTypography.body)
                }
            }

            signInControl
                .disabled(isSigningIn)

            Spacer(minLength: JKSpacing.xl)
        }
        .padding(.horizontal, JKSpacing.lg)
        .jkGlassBackground()
    }

    /// Enquanto `isSigningIn` é `true`, o botão tocado troca o rótulo por `ProgressView` no
    /// mesmo espaço/frame — a estrutura da tela não pode saltar durante o login
    /// (01-UI-SPEC.md "loading | login-buttons").
    @ViewBuilder
    private var signInControl: some View {
        if isSigningIn {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
                .background(colorScheme == .dark ? Color.white : Color.black, in: JKLayout.controlShape)
        } else {
            SignInWithAppleButton(.continue) { request in
                AppleSignInService.configure(request)
            } onCompletion: { result in
                Task { await handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            .cornerRadius(JKLayout.controlCornerRadius)
        }
    }

    private func handleAppleCompletion(_ authorizationResult: Result<ASAuthorization, Error>) async {
        switch AppleSignInService.result(from: authorizationResult) {
        case .success(let signInResult):
            await performSignIn(with: signInResult)
        case .failure(.cancelled):
            // Cancelamento pelo usuário: volta ao estado inicial sem mensagem de erro.
            isSigningIn = false
        case .failure:
            isSigningIn = false
            errorMessage = JKCopy.loginErrorMessage
        }
    }

    private func performSignIn(with result: AppleSignInResult) async {
        isSigningIn = true
        errorMessage = nil
        do {
            try await sessionStore.signIn(
                provider: .apple,
                identityToken: result.identityToken,
                displayName: result.displayName,
                gender: nil
            )
        } catch {
            errorMessage = JKCopy.loginErrorMessage
        }
        isSigningIn = false
    }
}

#Preview {
    LoginView()
        .environment(SessionStore())
}

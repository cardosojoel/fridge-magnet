import AuthenticationServices
import JKLarShared
import SwiftUI

/// Tela de login. D-01: a ordem dos três botões é sempre Apple, Google, Microsoft — Apple
/// obrigatório primeiro pela App Store Guideline 4.8, os outros dois na ordem que
/// `01-CONTEXT.md`/`01-UI-SPEC.md` fixam.
///
/// Todo estado por provedor (qual está em andamento, qual mensagem de erro mostrar) vive em
/// `LoginViewModel` — esta view só o reflete. O toque no `SignInWithAppleButton` nativo abre
/// o fluxo `ASAuthorization` real; o toque em Google/Microsoft chama
/// `GoogleSignInService`/`MicrosoftSignInService` (SDKs GIDSignIn/MSAL, plano 01-08). Os três
/// caminhos convergem no mesmo `SessionStore.signIn(provider:identityToken:...)`.
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SessionStore.self) private var sessionStore

    @State private var viewModel = LoginViewModel()

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

            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: JKSpacing.sm) {
                    Text(errorMessage)
                        .font(JKTypography.label)
                        .foregroundStyle(JKColor.jkDestructive)
                        .multilineTextAlignment(.center)

                    Button(JKCopy.loginErrorRetry) {
                        viewModel.clearError()
                    }
                    .font(JKTypography.body)
                }
            }

            VStack(spacing: JKSpacing.sm) {
                appleRow
                googleRow
                microsoftRow
            }

            Spacer(minLength: JKSpacing.xl)
        }
        .padding(.horizontal, JKSpacing.lg)
        .jkGlassBackground()
    }

    /// Enquanto `.apple` está em andamento, o controle inteiro troca para `ProgressView` no
    /// mesmo espaço/frame — a estrutura da tela não pode saltar durante o login
    /// (01-UI-SPEC.md "loading | login-buttons"). Os outros dois botões desabilitam, nunca
    /// escondem, via `.disabled(viewModel.isDisabled(.apple))`.
    @ViewBuilder
    private var appleRow: some View {
        if viewModel.isInProgress(.apple) {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
                .background(colorScheme == .dark ? Color.white : Color.black, in: JKLayout.controlShape)
        } else {
            SignInWithAppleButton(.continue) { request in
                AppleSignInService.configure(request)
                // Roda de forma síncrona no toque, antes do fluxo nativo abrir — é o que
                // permite os outros dois botões desabilitarem já durante o prompt da Apple.
                viewModel.beginApple()
            } onCompletion: { result in
                Task {
                    await viewModel.handleAppleCompletion(
                        AppleSignInService.result(from: result),
                        exchange: exchange(provider: .apple)
                    )
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            .cornerRadius(JKLayout.controlCornerRadius)
            .disabled(viewModel.isDisabled(.apple))
        }
    }

    private var googleRow: some View {
        Button {
            Task { await viewModel.signInWithGoogle(exchange: exchange(provider: .google)) }
        } label: {
            if viewModel.isInProgress(.google) {
                ProgressView()
            } else {
                Text(JKCopy.loginContinueWithGoogle)
            }
        }
        .buttonStyle(.jkPrimary)
        .disabled(viewModel.isInProgress(.google) || viewModel.isDisabled(.google))
    }

    private var microsoftRow: some View {
        Button {
            Task { await viewModel.signInWithMicrosoft(exchange: exchange(provider: .microsoft)) }
        } label: {
            if viewModel.isInProgress(.microsoft) {
                ProgressView()
            } else {
                Text(JKCopy.loginContinueWithMicrosoft)
            }
        }
        .buttonStyle(.jkPrimary)
        .disabled(viewModel.isInProgress(.microsoft) || viewModel.isDisabled(.microsoft))
    }

    /// `SessionStore` nunca é conhecido por `LoginViewModel` (mantém o modelo testável sem
    /// `FakeTransport`) — esta view é quem fecha o laço, chamando o mesmo
    /// `createSession(provider:identityToken:...)` para os três provedores.
    private func exchange(provider: AuthProvider) -> (String, String?) async throws -> Void {
        { identityToken, displayName in
            try await sessionStore.signIn(provider: provider, identityToken: identityToken, displayName: displayName, gender: nil)
        }
    }
}

#Preview {
    LoginView()
        .environment(SessionStore())
}

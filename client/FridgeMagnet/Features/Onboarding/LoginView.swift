import AuthenticationServices
import FridgeMagnetShared
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
    // Fluxo Apple dirigido por `ASAuthorizationController` + delegate, não pelo
    // `SignInWithAppleButton` da SwiftUI — o `onCompletion` do wrapper nunca dispara no iOS
    // Simulator mesmo com autorização concluída (ver doc de `AppleSignInCoordinator`).
    @State private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        VStack(spacing: FMSpacing.xl) {
            Spacer(minLength: FMSpacing.xxxl)

            VStack(spacing: FMSpacing.sm) {
                Text(FMCopy.appName)
                    .font(FMTypography.display)
                    .multilineTextAlignment(.center)

                Text(FMCopy.loginTagline)
                    .font(FMTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: FMSpacing.sm) {
                    Text(errorMessage)
                        .font(FMTypography.label)
                        .foregroundStyle(FMColor.jkDestructive)
                        .multilineTextAlignment(.center)

                    Button(FMCopy.loginErrorRetry) {
                        viewModel.clearError()
                    }
                    .font(FMTypography.body)
                }
            }

            VStack(spacing: FMSpacing.sm) {
                appleRow
                googleRow
                microsoftRow
            }

            Spacer(minLength: FMSpacing.xl)
        }
        .padding(.horizontal, FMSpacing.lg)
        .jkGlassBackground()
    }

    /// Enquanto `.apple` está em andamento, o controle inteiro troca para `ProgressView` no
    /// mesmo espaço/frame — a estrutura da tela não pode saltar durante o login
    /// (01-UI-SPEC.md "loading | login-buttons"). Os outros dois botões desabilitam, nunca
    /// escondem, via `.disabled(viewModel.isDisabled(.apple))`.
    ///
    /// Botão custom no visual das Apple HIG (fundo preto/branco por esquema, logo +
    /// "Continuar com a Apple"), não o `SignInWithAppleButton` — além do bug de callback do
    /// wrapper (doc de `AppleSignInCoordinator`), o nativo renderizava rótulo em inglês,
    /// inconsistente com os irmãos Google/Microsoft em português.
    @ViewBuilder
    private var appleRow: some View {
        if viewModel.isInProgress(.apple) {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: FMLayout.minTapTarget)
                .background(colorScheme == .dark ? Color.white : Color.black, in: FMLayout.controlShape)
        } else {
            Button {
                // Mesma ordem do fluxo antigo: `beginApple()` roda no toque, antes de o
                // prompt nativo abrir — é o que desabilita os outros dois botões já durante
                // o prompt da Apple.
                viewModel.beginApple()
                Task {
                    let result = await appleCoordinator.signIn()
                    await viewModel.handleAppleCompletion(
                        AppleSignInService.result(from: result),
                        exchange: exchange(provider: .apple)
                    )
                }
            } label: {
                Label(FMCopy.loginContinueWithApple, systemImage: "apple.logo")
                    .font(FMTypography.body)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: FMLayout.minTapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .background(colorScheme == .dark ? Color.white : Color.black, in: FMLayout.controlShape)
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
                Text(FMCopy.loginContinueWithGoogle)
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
                Text(FMCopy.loginContinueWithMicrosoft)
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

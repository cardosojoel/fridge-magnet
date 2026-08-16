import AuthenticationServices
import SwiftUI

/// Tela de login. D-01: Sign in with Apple aparece primeiro e é o único botão de provedor
/// nesta fatia — os botões de Google e Microsoft chegam no plano 01-08, na mesma ordem
/// definida por D-01 (Apple, depois Google, depois Microsoft). Não há botão inerte
/// desenhado aqui para provedores futuros.
///
/// Ligar o toque a um serviço de autenticação real (troca do identity token pelo backend,
/// gravação da sessão no Keychain) é escopo do plano 01-05. Aqui o botão nativo já existe e
/// já está desenhado sobre o fundo translúcido, mas `onCompletion` ainda não faz nada.
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme

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

            SignInWithAppleButton(.continue) { _ in
                // Ligado ao serviço de autenticação real no plano 01-05.
            } onCompletion: { _ in
                // Ligado ao serviço de autenticação real no plano 01-05.
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            .cornerRadius(JKLayout.controlCornerRadius)

            Spacer(minLength: JKSpacing.xl)
        }
        .padding(.horizontal, JKSpacing.lg)
        .jkGlassBackground()
    }
}

#Preview {
    LoginView()
}

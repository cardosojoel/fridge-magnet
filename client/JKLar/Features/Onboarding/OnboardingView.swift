import JKLarShared
import SwiftUI

/// Gate obrigatório de casa (D-02) — `RootView` só chega aqui em `.needsHousehold`, e este
/// é o único destino desse estado (não existe navegação imperativa que o contorne).
///
/// O seletor segmentado do 01-UI-SPEC.md tem os dois rótulos desde já: o ramo "Criar casa"
/// (plano 01-07) e o ramo "Entrar com código" (`JoinByCodeView`, plano 01-09) — a segunda
/// pessoa entra na casa por um código de convite ou por um link `jklar://join/<CODE>`, cujo
/// código guardado em `DeepLinkRouter` é consumido aqui assim que este gate aparece de
/// verdade, nunca antes (D-02).
struct OnboardingView: View {
    private enum Mode: Hashable {
        case create
        case join
    }

    @Environment(SessionStore.self) private var sessionStore
    @Environment(DeepLinkRouter.self) private var deepLinkRouter
    @State private var mode: Mode = .create
    @State private var viewModel = OnboardingViewModel()
    @State private var joinViewModel = JoinByCodeViewModel()

    var body: some View {
        VStack(spacing: JKSpacing.lg) {
            Picker("", selection: $mode) {
                Text(JKCopy.onboardingToggleCreate).tag(Mode.create)
                Text(JKCopy.onboardingToggleJoin).tag(Mode.join)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .create:
                createHouseholdForm
            case .join:
                JoinByCodeView(viewModel: joinViewModel)
            }

            Spacer()
        }
        .padding(JKSpacing.lg)
        .jkGlassBackground()
        .task {
            applyPendingDeepLinkIfNeeded()
        }
        .onChange(of: deepLinkRouter.pendingJoinCode) { _, _ in
            applyPendingDeepLinkIfNeeded()
        }
    }

    /// Consome um código pendente de `jklar://join/<CODE>` (D-02): tanto no primeiro
    /// aparecimento deste gate (link aberto antes do login) quanto num link aberto com o
    /// app já rodando neste mesmo gate (`.onChange`, comportamento #6 da Task 1).
    private func applyPendingDeepLinkIfNeeded() {
        guard let code = deepLinkRouter.consumePendingJoinCode() else { return }
        mode = .join
        joinViewModel.prefill(code: code)
    }

    private var createHouseholdForm: some View {
        JKCard {
            VStack(alignment: .leading, spacing: JKSpacing.md) {
                Text(JKCopy.onboardingCreateHeading)
                    .font(JKTypography.heading)

                TextField(JKCopy.onboardingHouseNamePlaceholder, text: $viewModel.houseName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isSubmitting)

                genderPicker
                    .disabled(viewModel.isSubmitting)

                // ProgressView com os campos desabilitados (não escondidos) durante a
                // criação — 01-UI-SPEC.md "loading | create-house-form".
                if viewModel.isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(JKTypography.label)
                        .foregroundStyle(JKColor.jkDestructive)
                }

                Button(JKCopy.onboardingCreateCTA) {
                    submit()
                }
                .buttonStyle(.jkPrimary)
                .disabled(!viewModel.canSubmitCreate)
            }
        }
    }

    private var genderPicker: some View {
        Picker(JKCopy.onboardingGenderLabel, selection: $viewModel.gender) {
            Text(JKCopy.onboardingGenderPlaceholder).tag(Gender?.none)
            Text(JKCopy.onboardingGenderFeminino).tag(Gender?.some(.feminino))
            Text(JKCopy.onboardingGenderMasculino).tag(Gender?.some(.masculino))
            Text(JKCopy.onboardingGenderNaoInformado).tag(Gender?.some(.naoInformado))
        }
        .pickerStyle(.menu)
    }

    /// Cria a casa e, com sucesso, reconfirma o estado no servidor via
    /// `SessionStore.hydrate()` — a mesma fonte de verdade usada por todo o roteador desde
    /// o plano 01-05 (T-05-06). `OnboardingViewModel` nunca decide navegação sozinho.
    private func submit() {
        Task {
            await viewModel.submitCreate()
            if viewModel.createdHousehold != nil {
                await sessionStore.hydrate()
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environment(SessionStore())
        .environment(DeepLinkRouter())
}

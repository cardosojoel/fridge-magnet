import JKLarShared
import SwiftUI

/// Gate obrigatório de casa (D-02) — `RootView` só chega aqui em `.needsHousehold`, e este
/// é o único destino desse estado (não existe navegação imperativa que o contorne).
///
/// O seletor segmentado do 01-UI-SPEC.md tem os dois rótulos desde já: só o ramo "Criar
/// casa" está ligado nesta fatia. O ramo "Entrar com código" leva a uma view própria ainda
/// vazia (`JoinHouseholdPlaceholderView`), que o plano 01-09 preenche sem precisar redesenhar
/// esta navegação.
struct OnboardingView: View {
    private enum Mode: Hashable {
        case create
        case join
    }

    @Environment(SessionStore.self) private var sessionStore
    @State private var mode: Mode = .create
    @State private var viewModel = OnboardingViewModel()

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
                JoinHouseholdPlaceholderView()
            }

            Spacer()
        }
        .padding(JKSpacing.lg)
        .jkGlassBackground()
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

/// Ramo "Entrar com código" — destino próprio e vazio nesta fatia (D-02 exige que o gate
/// tenha as duas saídas desde já, nunca um beco sem saída). O plano 01-09 assume a
/// propriedade deste arquivo e preenche o formulário real de entrar por convite.
private struct JoinHouseholdPlaceholderView: View {
    var body: some View {
        Text(JKCopy.onboardingJoinPlaceholder)
            .font(JKTypography.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(JKSpacing.lg)
    }
}

#Preview {
    OnboardingView()
        .environment(SessionStore())
}

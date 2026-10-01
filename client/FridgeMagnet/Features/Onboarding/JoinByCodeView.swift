import FridgeMagnetShared
import SwiftUI

/// Ramo "Entrar com código" do gate de casa (D-02, D-05) — os quatro estados exigidos por
/// 01-UI-SPEC.md § UI Considerations `code-entry-form`: vazio/parcial (CTA desabilitado até
/// 6 caracteres), em voo (`ProgressView` + campo desabilitado), código inválido/expirado
/// (borda vermelha + tremor, texto preservado) e casa lotada (mensagem verbatim do
/// CONTEXT.md + orientação complementar).
///
/// Nenhum estado é decidido aqui: a view só reflete `JoinByCodeViewModel.submitError`, que
/// por sua vez só traduz o `APIErrorCode` tipado que o servidor devolveu — nunca um
/// `switch` em string de mensagem (T-09-04).
struct JoinByCodeView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Bindable var viewModel: JoinByCodeViewModel

    @State private var shakeTicks: CGFloat = 0

    var body: some View {
        FMCard {
            VStack(alignment: .leading, spacing: FMSpacing.md) {
                TextField(FMCopy.onboardingCodeFieldPlaceholder, text: $viewModel.code)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isSubmitting)
                    .overlay(
                        FMLayout.controlShape
                            .stroke(
                                viewModel.submitError == .invalidOrExpired ? FMColor.jkDestructive : .clear,
                                lineWidth: 1.5
                            )
                    )
                    .modifier(FMShakeEffect(shakes: shakeTicks))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif

                // ProgressView com o campo desabilitado (já acima) durante a validação —
                // 01-UI-SPEC.md "loading | code-entry-form".
                if viewModel.isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: FMSpacing.xs) {
                        Text(errorMessage)
                            .font(FMTypography.label)
                            .foregroundStyle(FMColor.jkDestructive)

                        // Orientação complementar da mensagem verbatim de casa lotada —
                        // nunca concatenada na string verbatim em si (CONTEXT.md).
                        if viewModel.submitError == .householdFull {
                            Text(FMCopy.onboardingHouseholdFullErrorDetail)
                                .font(FMTypography.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button(FMCopy.onboardingJoinCTA) {
                    submit()
                }
                .buttonStyle(.jkPrimary)
                .disabled(!viewModel.canSubmit)
            }
        }
        .onChange(of: viewModel.submitError) { _, newValue in
            guard newValue == .invalidOrExpired else { return }
            withAnimation(.default) { shakeTicks += 1 }
        }
    }

    /// Sucesso reconfirma o estado no servidor via `SessionStore.hydrate()` — a mesma fonte
    /// de verdade usada por `OnboardingView.submit()` desde o plano 01-07 (T-05-06).
    /// `JoinByCodeViewModel` nunca decide navegação sozinho.
    private func submit() {
        Task {
            await viewModel.submit()
            if viewModel.joinedHousehold != nil {
                await sessionStore.hydrate()
            }
        }
    }
}

/// Tremor horizontal do campo em código inválido/expirado (01-UI-SPEC.md "error |
/// code-entry-form"). `GeometryEffect` clássico: `shakes` incrementa a cada erro e SwiftUI
/// interpola `animatableData` sozinho entre o valor antigo e o novo.
private struct FMShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    private let amount: CGFloat = 8
    private let shakesPerUnit: CGFloat = 3

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(shakes * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

#Preview {
    JoinByCodeView(viewModel: JoinByCodeViewModel())
        .environment(SessionStore())
        .padding()
}

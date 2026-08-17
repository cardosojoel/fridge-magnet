import SwiftUI

/// Sheet apresentado por `RootView` na primeira transição para `.inHousehold` (D-13) —
/// nunca antes de haver casa, uma única vez por instalação (`PushRegistrationService.hasShownPrimer`).
///
/// As quatro linhas do Copywriting Contract vêm todas de `JKCopy` (mesmo contrato já
/// verificado nos planos 01-07/01-09/01-10) — nenhum literal solto em `Text(`. `.thickMaterial`
/// com raio de 28 no topo, mesmos tokens de `InviteSheet` (01-UI-SPEC.md § Native Materials).
///
/// D-14: recusar — pelo botão secundário ou pelo prompt do sistema — nunca bloqueia nada.
/// `stage` só controla o que este sheet mostra; nenhum outro estado do app muda por causa de
/// uma recusa (ver `PushRegistrationServiceTests.testRootViewStateRemainsInHouseholdAfterPrimerDecline`).
struct NotificationPrimerView: View {
    let pushRegistrationService: PushRegistrationService

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .prompting

    private enum Stage: Equatable {
        case prompting
        case declined
    }

    var body: some View {
        VStack(spacing: JKSpacing.lg) {
            switch stage {
            case .prompting:
                promptContent
            case .declined:
                declinedContent
            }
        }
        .padding(JKSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial)
        .presentationDetents([.medium])
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: JKSpacing.md) {
            Text(JKCopy.notificationPrimerHeading)
                .font(JKTypography.heading)

            Text(JKCopy.notificationPrimerBody)
                .font(JKTypography.body)
                .foregroundStyle(.secondary)

            Button(JKCopy.notificationPrimerPrimaryCTA) {
                Task { await requestAuthorization() }
            }
            .buttonStyle(.jkPrimary)

            Button(JKCopy.notificationPrimerSecondaryCTA) {
                decline()
            }
            .font(JKTypography.body)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var declinedContent: some View {
        Text(JKCopy.notificationPrimerReassurance)
            .font(JKTypography.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .task {
                // Mostra a mensagem de reasseguramento e fecha — nunca insiste (D-14). O
                // Copywriting Contract não define um rótulo de botão para fechar esta
                // mensagem; o próprio sheet se fecha depois de um instante de leitura.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                dismiss()
            }
    }

    /// Tocar em "Ativar notificações" pede a autorização do sistema. Concedida, dispara o
    /// registro remoto (dentro de `PushRegistrationService.requestAuthorization()`) e fecha.
    /// Negada, mostra a mesma tela de reasseguramento da recusa manual — D-14 não distingue
    /// os dois caminhos de recusa.
    private func requestAuthorization() async {
        let granted = await pushRegistrationService.requestAuthorization()
        if granted {
            dismiss()
        } else {
            stage = .declined
        }
    }

    private func decline() {
        pushRegistrationService.markPrimerShown()
        stage = .declined
    }
}

#Preview {
    NotificationPrimerView(pushRegistrationService: PushRegistrationService(apiClient: APIClient()))
}

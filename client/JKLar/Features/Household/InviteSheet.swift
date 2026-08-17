import JKLarShared
import SwiftUI

/// Folha apresentada pelo botão Convidar da `HouseholdView` (D-05, IDENT-04) — código em
/// destaque em `jkAccent` (01-UI-SPEC.md § Color reserva o acento exatamente para os
/// caracteres do convite), data de expiração e um `ShareLink` com a URL do convite.
///
/// A folha só lista o que `listInvites()` devolveu (rota sob RLS): um convite de outra casa
/// não tem como chegar aqui (IDENT-05, T-09-03). Quem abre este sheet já passou pelo gate
/// `myRole == .admin` de `HouseholdView` — conveniência de UI, não segurança; o 403 do
/// `RequireRoleMiddleware` no servidor é a linha de defesa real (T-09-02).
struct InviteSheet: View {
    @State private var viewModel = InviteSheetViewModel()

    var body: some View {
        VStack(spacing: JKSpacing.lg) {
            Text(JKCopy.inviteSheetHeading)
                .font(JKTypography.heading)

            switch viewModel.state {
            case .loading:
                ProgressView()
            case .loaded(let invite):
                inviteContent(invite)
            case .error(let message):
                errorContent(message: message)
            }

            Spacer()
        }
        .padding(JKSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial)
        .presentationDetents([.medium])
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
        .task {
            await viewModel.loadOrCreateInvite()
        }
    }

    private func inviteContent(_ invite: InviteDTO) -> some View {
        VStack(spacing: JKSpacing.md) {
            // Único uso de `jkAccent` fora de CTA (01-UI-SPEC.md § Color): "the invite-code
            // characters themselves (emphasis text)".
            Text(invite.code)
                .font(JKTypography.display)
                .foregroundStyle(JKColor.jkAccent)
                .tracking(4)

            Text(JKCopy.inviteSheetExpiresLabel(invite.expiresAt))
                .font(JKTypography.label)
                .foregroundStyle(.secondary)

            if let url = URL(string: invite.url) {
                ShareLink(item: url) {
                    Label(JKCopy.inviteSheetShareCTA, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.jkPrimary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: JKSpacing.sm) {
            Text(message)
                .font(JKTypography.label)
                .foregroundStyle(JKColor.jkDestructive)

            Button(JKCopy.retryButtonLabel) {
                Task { await viewModel.loadOrCreateInvite() }
            }
            .font(JKTypography.body)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Carga do convite a mostrar na folha — os três estados exigidos por `InviteSheet`
/// (carregando/carregado/erro). Não listado no `<files>` do plano como um arquivo próprio:
/// vive junto de `InviteSheet` porque não há mais nenhum outro consumidor deste estado.
@MainActor
@Observable
private final class InviteSheetViewModel {
    enum LoadState {
        case loading
        case loaded(InviteDTO)
        case error(message: String)
    }

    private(set) var state: LoadState = .loading

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Mostra o convite mais recente que `listInvites()` devolveu (rota sob RLS, ordenada do
    /// mais recente para o mais antigo pelo servidor) — só gera um código novo
    /// (`createInvite()`) se a casa ainda não tiver nenhum convite ativo. Evita acumular um
    /// convite novo a cada vez que o admin reabre a folha.
    func loadOrCreateInvite() async {
        state = .loading
        do {
            let invites = try await apiClient.listInvites()
            if let mostRecent = invites.first {
                state = .loaded(mostRecent)
                return
            }
            let created = try await apiClient.createInvite()
            state = .loaded(created)
        } catch {
            state = .error(message: JKCopy.inviteSheetLoadErrorMessage)
        }
    }
}

#Preview {
    InviteSheet()
}

import JKLarShared
import Observation
import SwiftUI

/// Carga da lista de membros pra marcação (D-06) — molde de `HouseholdViewModel`: `LoadState`
/// de três casos, `load()` chamando `apiClient.members()`. `selectedUserIDs` guarda o
/// conjunto (checagem rápida de "está marcado?"); `selectionOrder` guarda a mesma seleção na
/// ordem em que foi feita, porque `selectedMentions` (devolvido ao compose) precisa preservar
/// ordem de seleção, não a ordem da lista de membros.
@MainActor
@Observable
final class MentionPickerViewModel {
    enum LoadState {
        case loading
        case loaded(members: [MemberDTO])
        case error(message: String, lastGood: [MemberDTO]?)
    }

    private(set) var state: LoadState = .loading
    private(set) var selectedUserIDs: Set<UUID>
    private(set) var selectionOrder: [UUID]

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient(), initiallySelected: [UUID] = []) {
        self.apiClient = apiClient
        self.selectedUserIDs = Set(initiallySelected)
        self.selectionOrder = initiallySelected
    }

    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            let members = try await apiClient.members()
            state = .loaded(members: members)
        } catch {
            state = .error(message: JKCopy.muralMentionPickerLoadError, lastGood: previousGood)
        }
    }

    /// Alterna a seleção de `member` — a própria pessoa (`member.isSelf`) é selecionável como
    /// qualquer outra: marcar a si mesmo é registro social legítimo (plano 02-02, o backend
    /// simplesmente não manda push para si).
    func toggle(_ member: MemberDTO) {
        if selectedUserIDs.contains(member.userID) {
            selectedUserIDs.remove(member.userID)
            selectionOrder.removeAll { $0 == member.userID }
        } else {
            selectedUserIDs.insert(member.userID)
            selectionOrder.append(member.userID)
        }
    }

    /// Conjunto final a devolver ao compose, na ordem de seleção — só resolve nomes se a
    /// lista de membros já carregou.
    var selectedMentions: [MentionDTO] {
        guard case .loaded(let members) = state else { return [] }
        let membersByUserID = Dictionary(uniqueKeysWithValues: members.map { ($0.userID, $0) })
        return selectionOrder.compactMap { userID in
            membersByUserID[userID].map { MentionDTO(userID: $0.userID, displayName: $0.displayName) }
        }
    }

    private var currentGood: [MemberDTO]? {
        switch state {
        case .loading: nil
        case .loaded(let members): members
        case .error(_, let lastGood): lastGood
        }
    }
}

/// Folha de seletor estruturado de menção (D-06) — lista de membros da casa com marca de
/// verificação, nunca entrada de texto livre. Apresentada pelo botão "Marcar alguém" do
/// compose (plano 02-06 Task 2).
///
/// `jkElevatedSurface`/`JKLayout.sheetShape`, mesmo precedente visual de `ComposeRecadoView`/
/// `InviteSheet` — sem `NavigationStack` (nenhuma outra folha do mural usa uma), por isso os
/// botões de concluir/cancelar ficam inline no corpo, não num toolbar.
struct MentionPickerView: View {
    @State private var viewModel: MentionPickerViewModel
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    /// Chamado só quando a pessoa confirma (nunca no dismiss por swipe/cancelar) — devolve o
    /// conjunto selecionado na ordem de seleção.
    let onConfirm: ([MentionDTO]) -> Void

    init(initiallySelected: [UUID] = [], apiClient: APIClient = APIClient(), onConfirm: @escaping ([MentionDTO]) -> Void) {
        _viewModel = State(initialValue: MentionPickerViewModel(apiClient: apiClient, initiallySelected: initiallySelected))
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JKSpacing.lg) {
            Text(JKCopy.muralMentionPickerTitle)
                .font(JKTypography.heading)

            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .loaded(let members):
                loadedContent(members: members)
            case .error(let message, let lastGood):
                errorContent(message: message, lastGood: lastGood)
            }

            confirmButton

            Button(JKCopy.cancelButtonLabel) {
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(JKSpacing.lg)
        .background(.thickMaterial)
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
        .task {
            await viewModel.load()
        }
    }

    /// Casa com apenas o próprio membro (n=1) mostra a cópia de único-membro em vez de campo
    /// de busca + lista (nada pra buscar). n≥2: campo de busca (filtro local de lista, nunca
    /// vira menção — D-06) + linhas com marca de verificação.
    @ViewBuilder
    private func loadedContent(members: [MemberDTO]) -> some View {
        if members.count <= 1 {
            Text(JKCopy.muralMentionPickerOnlyMemberState)
                .font(JKTypography.label)
                .foregroundStyle(.secondary)
        } else {
            TextField(JKCopy.muralMentionPickerSearchPlaceholder, text: $searchText)
                .font(JKTypography.body)

            ScrollView {
                LazyVStack(spacing: JKSpacing.xs) {
                    ForEach(filteredMembers(members), id: \.id) { member in
                        memberRow(member)
                    }
                }
            }
        }
    }

    private func filteredMembers(_ members: [MemberDTO]) -> [MemberDTO] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return members }
        return members.filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(query) }
    }

    /// Altura mínima `JKLayout.memberRowMinHeight`, nome truncado em uma linha (mesma
    /// convenção da lista de membros da Fase 1), área tocável cobrindo a linha inteira.
    private func memberRow(_ member: MemberDTO) -> some View {
        let isSelected = viewModel.selectedUserIDs.contains(member.userID)
        return Button {
            viewModel.toggle(member)
        } label: {
            HStack(spacing: JKSpacing.sm) {
                Text(member.displayName ?? JKCopy.householdUnnamedMember)
                    .font(JKTypography.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? JKColor.jkAccent : Color.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(JKColor.jkAccent)
                }
            }
            .frame(minHeight: JKLayout.memberRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func errorContent(message: String, lastGood: [MemberDTO]?) -> some View {
        if let lastGood {
            loadedContent(members: lastGood)
        }
        VStack(spacing: JKSpacing.sm) {
            Text(message)
                .font(JKTypography.label)
                .foregroundStyle(JKColor.jkDestructive)
            Button(JKCopy.retryButtonLabel) {
                Task { await viewModel.load() }
            }
            .font(JKTypography.body)
        }
    }

    private var confirmButton: some View {
        Button {
            onConfirm(viewModel.selectedMentions)
            dismiss()
        } label: {
            Text(JKCopy.doneButtonLabel)
        }
        .buttonStyle(.jkPrimary)
    }
}

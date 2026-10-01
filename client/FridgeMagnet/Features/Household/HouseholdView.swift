import FridgeMagnetShared
import SwiftUI

/// Tela da casa — nome e lista de membros (IDENT-03/IDENT-04/IDENT-05), com os três estados
/// obrigatórios do 01-UI-SPEC.md: carregando (esqueleto), carregado (cópia no singular com 1
/// membro, plural de 2 a 10, parando de crescer em 10 sem chrome especial) e erro (Tentar de
/// novo inline, preservando a última lista boa quando houver uma).
///
/// O botão Convidar (plano 01-09) só renderiza quando `household.myRole == .admin` — isso é
/// conveniência de UI (T-09-02), a linha de defesa real é o 403 do `RequireRoleMiddleware`
/// no servidor (plano 01-06). `HouseholdViewModel` busca a lista real de
/// `GET /households/current/members`, que já suporta 2–10 membros sem trocar a chamada de
/// rede desde o plano 01-07.
///
/// Plano 01-10 (IDENT-06, segunda ação): remover membro (admin-only, `swipeActions` na linha
/// + `contextMenu` equivalente para macOS, onde não há swipe) e sair da casa (linha
/// destrutiva no rodapé, qualquer papel). A tela precisou virar um `List` — `.swipeActions`
/// só funciona em linhas de `List`, não em `ScrollView`/`VStack` — mas cada linha continua
/// sendo um `FMCard` sobre Material, com o chrome padrão de lista escondido
/// (`.listRowSeparator`/`.listRowBackground`), para manter o visual estabelecido pelos planos
/// 01-07/01-09.
struct HouseholdView: View {
    @Environment(SessionStore.self) private var sessionStore
    @State private var viewModel = HouseholdViewModel()
    @State private var isInviteSheetPresented = false
    @State private var isLeaveConfirmationPresented = false
    @State private var memberPendingRemoval: MemberDTO?
    @State private var isEditNamePresented = false
    @State private var editNameDraft = ""

    var body: some View {
        // Contêiner de navegação (plano 02-12, `<planner_assumptions>` item 1): a linha
        // "Arquivados" do contrato é uma linha de navegação padrão com chevron, e nenhum
        // contêiner de navegação existia no app — sem ele, a linha não teria para onde
        // empurrar a tela. A barra de navegação da raiz fica visível por padrão; escondê-la
        // é o ajuste previsto no checkpoint de verificação humana, caso incomode.
        NavigationStack {
            List {
            switch viewModel.state {
            case .loading:
                loadingSkeleton
            case .loaded(let household, let members):
                loadedContent(household: household, members: members)
            case .error(let message, let lastGood):
                errorContent(message: message, lastGood: lastGood)
            }

            if let actionErrorMessage = viewModel.actionErrorMessage {
                Text(actionErrorMessage)
                    .font(FMTypography.label)
                    .foregroundStyle(FMColor.jkDestructive)
                    .plainRow()
            }

            // "Sair da casa" (01-UI-SPEC.md): linha destrutiva no rodapé, visível para
            // qualquer papel — não depende de `myRole`.
            Button(role: .destructive) {
                isLeaveConfirmationPresented = true
            } label: {
                Text(FMCopy.householdLeaveRowLabel)
            }
            .tint(FMColor.jkDestructive)
            .plainRow()
            }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .jkGlassBackground()
        .task {
            viewModel.sessionStore = sessionStore
            await viewModel.load()
        }
        .sheet(isPresented: $isInviteSheetPresented) {
            InviteSheet()
        }
        .confirmationDialog(
            FMCopy.householdLeaveRowLabel,
            isPresented: $isLeaveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(FMCopy.householdLeaveConfirmButton, role: .destructive) {
                Task { await viewModel.leaveHousehold() }
            }
            Button(FMCopy.cancelButtonLabel, role: .cancel) {}
        } message: {
            Text(FMCopy.householdLeaveConfirmMessage)
        }
        .confirmationDialog(
            FMCopy.householdRemoveActionLabel,
            isPresented: Binding(
                get: { memberPendingRemoval != nil },
                set: { isPresented in
                    if !isPresented { memberPendingRemoval = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let member = memberPendingRemoval {
                Button(FMCopy.householdRemoveConfirmButton, role: .destructive) {
                    let target = member
                    memberPendingRemoval = nil
                    Task { await viewModel.removeMember(target) }
                }
                Button(FMCopy.cancelButtonLabel, role: .cancel) {
                    memberPendingRemoval = nil
                }
            }
        } message: {
            if let member = memberPendingRemoval {
                Text(FMCopy.householdRemoveConfirmMessage(member.displayName ?? FMCopy.householdUnnamedMember))
            }
        }
        // Alert com TextField (iOS 16+/macOS 13+, dentro dos targets de deployment) em vez
        // de uma folha própria — edição de um único campo curto não justifica uma sheet.
        .alert(FMCopy.householdEditNameTitle, isPresented: $isEditNamePresented) {
            TextField(FMCopy.householdEditNameFieldPlaceholder, text: $editNameDraft)
            Button(FMCopy.householdEditNameSaveButton) {
                let draft = editNameDraft
                Task { await viewModel.updateDisplayName(draft) }
            }
            Button(FMCopy.cancelButtonLabel, role: .cancel) {}
        }
        }
    }

    /// 3 linhas de esqueleto em `jkCardSurface` durante a carga inicial (01-UI-SPEC.md
    /// "loading | member-list").
    private var loadingSkeleton: some View {
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: FMLayout.cardCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .frame(height: FMLayout.memberRowMinHeight)
                .plainRow()
        }
    }

    @ViewBuilder
    private func loadedContent(household: HouseholdDTO, members: [MemberDTO]) -> some View {
        householdHeader(household: household, members: members)
            .plainRow()

        ForEach(members, id: \.id) { member in
            memberRow(member)
                .plainRow()
                .swipeActions(edge: .trailing) {
                    if viewModel.canRemove(member) {
                        removeActionButton(for: member)
                    }
                }
                .contextMenu {
                    if viewModel.canRemove(member) {
                        removeActionButton(for: member)
                    }
                }
        }

        // Linha "Arquivados" (D-15, plano 02-12) — exatamente o mesmo gate visual do botão
        // Convidar acima: esconder é conveniência, a defesa real é o 403 do middleware de
        // papel no servidor para as duas rotas de arquivados (plano 02-11). Não-admin não
        // vê linha nenhuma: nem desabilitada, nem com texto explicativo (convenção de
        // silêncio na ausência).
        if household.myRole == .admin {
            NavigationLink {
                ArchivedRecadosView()
            } label: {
                Label(FMCopy.householdArchivedRowLabel, systemImage: "archivebox")
                    .font(FMTypography.body)
                    .frame(minHeight: FMLayout.memberRowMinHeight)
            }
            .plainRow()
        }
    }

    /// Nome da casa + botão Convidar (admin-only) + contagem/estado de único membro — tudo
    /// junto numa única linha de `List`, já que nenhum destes elementos precisa de
    /// `swipeActions`/`contextMenu` individual.
    @ViewBuilder
    private func householdHeader(household: HouseholdDTO, members: [MemberDTO]) -> some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(household.name)
                    .font(FMTypography.display)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Conveniência de UI (T-09-02): esconder o botão não é a linha de defesa — o
                // 403 do `RequireRoleMiddleware` no servidor é (plano 01-06). `myRole`
                // sempre vem do que o servidor devolveu, nunca inferido no cliente.
                if household.myRole == .admin {
                    Button {
                        isInviteSheetPresented = true
                    } label: {
                        Label(FMCopy.householdInviteCTA, systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FMColor.jkAccent)
                }
            }

            // Zero-one-many (01-UI-SPEC.md "zero-one-many | member-list"): singular só com 1
            // membro, plural cobre 2–10 sem mudar de cópia na fronteira de 10.
            Text(members.count == 1 ? FMCopy.householdMemberCountSingular : FMCopy.householdMemberCountPlural(members.count))
                .font(FMTypography.label)
                .foregroundStyle(.secondary)

            // n=1: cópia no singular em vez de um estado vazio genérico (01-UI-SPEC.md
            // "zero-one-many | member-list") — a casa recém-criada sempre tem o criador como
            // único membro nesta fatia.
            if members.count <= 1 {
                VStack(alignment: .leading, spacing: FMSpacing.xs) {
                    Text(FMCopy.householdSingleMemberHeading)
                        .font(FMTypography.heading)
                    Text(FMCopy.householdSingleMemberBody)
                        .font(FMTypography.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Avatar de monograma, nome (uma linha, truncado por reticências) e `FMRoleBadge`, com
    /// altura mínima de 56pt (01-UI-SPEC.md § Spacing Scale exceptions). Na própria linha
    /// (`isSelf`), um lápis discreto abre a edição de nome — a Apple só entrega o nome na
    /// primeira autorização, então sem este ponto de edição quem perde esse momento fica
    /// "Sem nome" para sempre (vale também para Google/Microsoft sem nome no perfil).
    private func memberRow(_ member: MemberDTO) -> some View {
        FMCard {
            HStack(spacing: FMSpacing.sm) {
                monogram(for: member.displayName)

                Text(member.displayName ?? FMCopy.householdUnnamedMember)
                    .font(FMTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if member.isSelf {
                    editNameButton(currentName: member.displayName)
                }

                Spacer()

                FMRoleBadge(role: member.role.asHouseholdRole)
            }
            .frame(minHeight: FMLayout.memberRowMinHeight)
        }
    }

    private func editNameButton(currentName: String?) -> some View {
        Button {
            editNameDraft = currentName ?? ""
            isEditNamePresented = true
        } label: {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .frame(minWidth: FMLayout.minTapTarget, minHeight: FMLayout.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FMCopy.householdEditNameAction)
    }

    /// Compartilhado por `swipeActions` e `contextMenu` — mesma ação, dois pontos de entrada
    /// (01-UI-SPEC.md "the ação de remover aparece por swipeActions ... e também no
    /// contextMenu, para o macOS onde não há swipe").
    private func removeActionButton(for member: MemberDTO) -> some View {
        Button(role: .destructive) {
            memberPendingRemoval = member
        } label: {
            Label(FMCopy.householdRemoveActionLabel, systemImage: "person.badge.minus")
        }
    }

    private func monogram(for displayName: String?) -> some View {
        let initial = displayName?.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"
        return Text(initial)
            .font(FMTypography.body.weight(.semibold))
            .frame(width: FMLayout.memberRowMinHeight - FMSpacing.md, height: FMLayout.memberRowMinHeight - FMSpacing.md)
            .background(FMColor.jkCardSurfaceBase, in: Circle())
    }

    /// Erro de carga com Tentar de novo inline — preserva a última lista boa (nome +
    /// membros) quando uma já existia, em vez de trocar a tela inteira por um banner de
    /// erro (01-UI-SPEC.md "error | member-list"). A lista de última-boa fica só leitura
    /// (sem swipe/contextMenu — `canRemove(_:)` já devolve falso fora de `.loaded`, dado que
    /// os dados podem estar desatualizados durante o erro).
    @ViewBuilder
    private func errorContent(
        message: String,
        lastGood: (household: HouseholdDTO, members: [MemberDTO])?
    ) -> some View {
        if let lastGood {
            loadedContent(household: lastGood.household, members: lastGood.members)
        }

        VStack(spacing: FMSpacing.sm) {
            Text(message)
                .font(FMTypography.label)
                .foregroundStyle(FMColor.jkDestructive)

            Button(FMCopy.retryButtonLabel) {
                Task { await viewModel.load() }
            }
            .font(FMTypography.body)
        }
        .plainRow()
    }
}

private extension MemberRole {
    /// Ponte para o SF Symbol/rótulo de `FMRoleBadge` (plano 01-03) — `MemberRole` (contrato
    /// de rede) e `FMHouseholdRole` (só apresentação) são tipos deliberadamente separados;
    /// esta é a única tradução entre os dois.
    var asHouseholdRole: FMHouseholdRole {
        switch self {
        case .admin: .admin
        case .adulto: .adult
        case .crianca: .child
        }
    }
}

private extension View {
    /// Esconde o chrome padrão de linha de `List` (separador + fundo) — cada linha desta
    /// tela já traz o próprio fundo (`FMCard`/Material) ou é um bloco de texto solto sobre o
    /// `jkGlassBackground()` da tela inteira.
    func plainRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    HouseholdView()
        .environment(SessionStore())
}

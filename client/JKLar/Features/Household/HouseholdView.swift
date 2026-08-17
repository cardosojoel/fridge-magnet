import JKLarShared
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
struct HouseholdView: View {
    @State private var viewModel = HouseholdViewModel()
    @State private var isInviteSheetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JKSpacing.md) {
                switch viewModel.state {
                case .loading:
                    loadingSkeleton
                case .loaded(let household, let members):
                    loadedContent(household: household, members: members)
                case .error(let message, let lastGood):
                    errorContent(message: message, lastGood: lastGood)
                }
            }
            .padding(JKSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .jkGlassBackground()
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isInviteSheetPresented) {
            InviteSheet()
        }
    }

    /// 3 linhas de esqueleto em `jkCardSurface` durante a carga inicial (01-UI-SPEC.md
    /// "loading | member-list").
    private var loadingSkeleton: some View {
        VStack(spacing: JKSpacing.sm) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: JKLayout.cardCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(height: JKLayout.memberRowMinHeight)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(household: HouseholdDTO, members: [MemberDTO]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(household.name)
                .font(JKTypography.display)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Conveniência de UI (T-09-02): esconder o botão não é a linha de defesa — o
            // 403 do `RequireRoleMiddleware` no servidor é (plano 01-06). `myRole` sempre
            // vem do que o servidor devolveu, nunca inferido no cliente.
            if household.myRole == .admin {
                Button {
                    isInviteSheetPresented = true
                } label: {
                    Label(JKCopy.householdInviteCTA, systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(JKColor.jkAccent)
            }
        }

        // Zero-one-many (01-UI-SPEC.md "zero-one-many | member-list"): singular só com 1
        // membro, plural cobre 2–10 sem mudar de cópia na fronteira de 10.
        Text(members.count == 1 ? JKCopy.householdMemberCountSingular : JKCopy.householdMemberCountPlural(members.count))
            .font(JKTypography.label)
            .foregroundStyle(.secondary)

        // n=1: cópia no singular em vez de um estado vazio genérico (01-UI-SPEC.md
        // "zero-one-many | member-list") — a casa recém-criada sempre tem o criador como
        // único membro nesta fatia.
        if members.count <= 1 {
            VStack(alignment: .leading, spacing: JKSpacing.xs) {
                Text(JKCopy.householdSingleMemberHeading)
                    .font(JKTypography.heading)
                Text(JKCopy.householdSingleMemberBody)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            }
        }

        VStack(spacing: JKSpacing.sm) {
            ForEach(members, id: \.id) { member in
                memberRow(member)
            }
        }
    }

    /// Avatar de monograma, nome (uma linha, truncado por reticências) e `JKRoleBadge`, com
    /// altura mínima de 56pt (01-UI-SPEC.md § Spacing Scale exceptions).
    private func memberRow(_ member: MemberDTO) -> some View {
        JKCard {
            HStack(spacing: JKSpacing.sm) {
                monogram(for: member.displayName)

                Text(member.displayName ?? JKCopy.householdUnnamedMember)
                    .font(JKTypography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                JKRoleBadge(role: member.role.asHouseholdRole)
            }
            .frame(minHeight: JKLayout.memberRowMinHeight)
        }
    }

    private func monogram(for displayName: String?) -> some View {
        let initial = displayName?.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"
        return Text(initial)
            .font(JKTypography.body.weight(.semibold))
            .frame(width: JKLayout.memberRowMinHeight - JKSpacing.md, height: JKLayout.memberRowMinHeight - JKSpacing.md)
            .background(JKColor.jkCardSurfaceBase, in: Circle())
    }

    /// Erro de carga com Tentar de novo inline — preserva a última lista boa (nome +
    /// membros) quando uma já existia, em vez de trocar a tela inteira por um banner de
    /// erro (01-UI-SPEC.md "error | member-list").
    @ViewBuilder
    private func errorContent(
        message: String,
        lastGood: (household: HouseholdDTO, members: [MemberDTO])?
    ) -> some View {
        if let lastGood {
            loadedContent(household: lastGood.household, members: lastGood.members)
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
}

private extension MemberRole {
    /// Ponte para o SF Symbol/rótulo de `JKRoleBadge` (plano 01-03) — `MemberRole` (contrato
    /// de rede) e `JKHouseholdRole` (só apresentação) são tipos deliberadamente separados;
    /// esta é a única tradução entre os dois.
    var asHouseholdRole: JKHouseholdRole {
        switch self {
        case .admin: .admin
        case .adulto: .adult
        case .crianca: .child
        }
    }
}

#Preview {
    HouseholdView()
}

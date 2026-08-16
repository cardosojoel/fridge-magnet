import JKLarShared
import SwiftUI

/// Tela da casa — nome e lista de membros (IDENT-03), com os três estados obrigatórios do
/// 01-UI-SPEC.md: carregando (esqueleto), carregado (cópia no singular quando há 1 membro,
/// nunca um estado vazio genérico) e erro (Tentar de novo inline, preservando a última lista
/// boa quando houver uma).
///
/// Nesta fatia a lista sempre tem exatamente 1 membro — o criador, com o selo de admin. A
/// listagem real de 2 a 10 pessoas chega no plano 01-09, que herda esta view sem trocar a
/// chamada de rede (`HouseholdViewModel` já busca a lista real de
/// `GET /households/current/members`).
struct HouseholdView: View {
    @State private var viewModel = HouseholdViewModel()

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
        Text(household.name)
            .font(JKTypography.display)
            .lineLimit(1)
            .truncationMode(.tail)

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

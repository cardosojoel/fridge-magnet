import FridgeMagnetShared
import SwiftUI

/// Tela Arquivados do admin (D-15, plano 02-12) — alcançada pela linha de navegação da aba
/// Casa (`HouseholdView`), que só renderiza para admin; a defesa real é o 403 do servidor
/// nas duas rotas (plano 02-11). Mora em `Features/Mural/` junto do resto do domínio de
/// recado (`<planner_assumptions>` item 2 do plano): quem for mexer no cartão de recado
/// encontra as duas renderizações lado a lado.
///
/// Quatro estados do contrato (`02-UI-SPEC.md` § Addendum 2, `archived-list`): carregando
/// (3 esqueletos), vazio, populado (cartões simplificados, do mais recentemente arquivado
/// para o mais antigo — ordem do servidor), e erro com tentar de novo inline preservando a
/// última lista boa.
///
/// O **cartão simplificado** leva, nesta ordem: cabeçalho do autor (nome + horário
/// relativo, igual ao do feed), carrossel de foto quando há foto (mesmo componente, mesma
/// proporção quadrada e mesmo recorte de cantos do cartão do feed), texto cortado em 5
/// linhas **sem** botão de expandir (é superfície de contexto para decidir, não superfície
/// de leitura), e um único botão de ação — Desarquivar, em cor de destaque (a única adição
/// à lista de usos reservados de accent deste adendo: é o único CTA da tela). Ficam
/// deliberadamente de fora: barra de reações, prévia de comentários, chips de menção e menu
/// de overflow.
struct ArchivedRecadosView: View {
    @State private var viewModel = ArchivedRecadosViewModel()

    var body: some View {
        List {
            titleRow

            switch viewModel.state {
            case .loading:
                loadingSkeleton
            case .loaded(let items):
                if items.isEmpty {
                    emptyState
                } else {
                    loadedContent(items: items)
                }
            case .error(let message, let lastGood):
                errorContent(message: message, lastGood: lastGood)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Animação padrão de remoção da lista ao desarquivar — mesma técnica do feed:
        // declarada na view, atrelada à contagem de itens, sem o view-model depender do
        // framework de interface.
        .animation(.default, value: loadedCount)
        .jkGlassBackground()
        .task {
            await viewModel.load()
        }
    }

    /// Contagem usada só como gatilho da animação de remoção.
    private var loadedCount: Int {
        if case .loaded(let items) = viewModel.state {
            return items.count
        }
        return 0
    }

    /// Título da tela no papel tipográfico de cabeçalho, mesma convenção do feed.
    private var titleRow: some View {
        Text(FMCopy.muralArchivedTitle)
            .font(FMTypography.heading)
            .plainRow()
    }

    /// 3 cartões vazios com o modificador de esqueleto — mesma convenção do feed
    /// (`02-UI-SPEC.md` "loading | archived-list").
    private var loadingSkeleton: some View {
        ForEach(0..<3, id: \.self) { _ in
            FMCard {
                Color.clear.frame(height: FMLayout.memberRowMinHeight)
            }
            .jkShimmerPlaceholder(isActive: true)
            .plainRow()
        }
    }

    /// `02-UI-SPEC.md` "empty | archived-list" — título e corpo do estado vazio.
    private var emptyState: some View {
        VStack(spacing: FMSpacing.sm) {
            Text(FMCopy.muralArchivedEmptyHeading)
                .font(FMTypography.heading)
            Text(FMCopy.muralArchivedEmptyBody)
                .font(FMTypography.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FMSpacing.xxl)
        .plainRow()
    }

    @ViewBuilder
    private func loadedContent(items: [RecadoDTO]) -> some View {
        ForEach(items, id: \.id) { recado in
            archivedCard(recado)
                .plainRow()
        }
    }

    /// `02-UI-SPEC.md` "error | archived-list" — mensagem + tentar de novo inline,
    /// preservando a última lista boa quando havia uma; nunca navega para fora da tela.
    @ViewBuilder
    private func errorContent(message: String, lastGood: [RecadoDTO]?) -> some View {
        if let lastGood, !lastGood.isEmpty {
            loadedContent(items: lastGood)
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
        .frame(maxWidth: .infinity)
        .plainRow()
    }

    // MARK: - Cartão simplificado

    private func archivedCard(_ recado: RecadoDTO) -> some View {
        FMCard {
            VStack(alignment: .leading, spacing: FMSpacing.sm) {
                cardHeader(recado)

                if !recado.photos.isEmpty {
                    photoCarousel(recado)
                }

                if let text = recado.text, !text.isEmpty {
                    Text(text)
                        .font(FMTypography.body)
                        .lineLimit(5)
                }

                unarchiveButton(recado)
                    .padding(.top, FMSpacing.xs)

                if viewModel.actionErrorRecadoID == recado.id, let actionErrorMessage = viewModel.actionErrorMessage {
                    Text(actionErrorMessage)
                        .font(FMTypography.label)
                        .foregroundStyle(FMColor.jkDestructive)
                }
            }
        }
    }

    /// Cabeçalho do autor — nome e horário relativo, igual ao do cartão do feed. Sem menu
    /// de overflow: o único ponto de ação do cartão é o botão de desarquivar abaixo.
    private func cardHeader(_ recado: RecadoDTO) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(recado.authorDisplayName ?? FMCopy.householdUnnamedMember)
                .font(FMTypography.body.weight(.semibold))
                .lineLimit(1)

            Text(recado.createdAt, style: .relative)
                .font(FMTypography.label)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    /// Único botão de ação por cartão — a cópia de desarquivar com o glifo de retorno, em
    /// cor de destaque (a única adição à lista de usos reservados de accent deste adendo:
    /// CTA solitário da tela, critério da própria lista).
    private func unarchiveButton(_ recado: RecadoDTO) -> some View {
        Button {
            Task { await viewModel.unarchive(recadoID: recado.id) }
        } label: {
            Label(FMCopy.muralArchivedUnarchiveCTA, systemImage: "arrow.uturn.backward")
                .font(FMTypography.body)
                .foregroundStyle(FMColor.jkAccent)
                .frame(minHeight: FMLayout.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Mesmo componente, mesma proporção quadrada e mesmo recorte de cantos do cartão do
    /// feed — borda a borda dentro do `FMCard`, compensando o padding interno.
    private func photoCarousel(_ recado: RecadoDTO) -> some View {
        FMPhotoCarousel(items: viewModel.photoURLs(for: recado.id)) { photo in
            AsyncImage(url: photo.downloadURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Color.clear.jkShimmerPlaceholder(isActive: true)
                case .failure:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(
            .rect(
                topLeadingRadius: FMLayout.cardCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: FMLayout.cardCornerRadius
            )
        )
        .padding(.top, -FMSpacing.md)
        .padding(.horizontal, -FMSpacing.md)
    }
}

private extension View {
    /// Esconde o chrome padrão de linha de `List` — mesmo helper das outras telas,
    /// redeclarado aqui porque `private extension` é escopado por arquivo.
    func plainRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    ArchivedRecadosView()
}

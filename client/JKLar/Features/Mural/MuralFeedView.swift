import JKLarShared
import SwiftUI

/// Feed do mural (MURAL-05) — os seis estados de lista do `02-UI-SPEC.md`: carregando
/// (esqueleto), vazio, erro (preservando a última lista boa), populado, carregando-mais e
/// falha-ao-carregar-mais. `List`, nunca a dupla scroll-container+pilha do plano 01-10 (mesmo
/// motivo: pull-to-refresh e o gatilho de rolagem infinita só existem nativos em `List`).
///
/// FAB de compose (modo novo) e menu de overflow de `RecadoCard` (Editar → modo edição,
/// Apagar → `deleteRecado` seguido de `reloadFromTop()`) ligados à folha real de
/// `ComposeRecadoView` desde a Task 3 do plano 02-05.
struct MuralFeedView: View {
    @State private var viewModel = MuralFeedViewModel()
    @State private var isComposePresented = false
    @State private var editingRecado: RecadoDTO?
    /// Recado aberto no detalhe (plano 02-07 Task 3) — `.sheet(item:)` em vez de um par
    /// `Bool`+recado guardado à parte, já que `RecadoDTO` ganhou `Identifiable` aditivo
    /// (`RecadoCard.swift`). Ao fechar, `viewModel.reloadFromTop()` roda pra contagem de
    /// comentários e resumo de reação do cartão refletirem o que foi feito no detalhe.
    @State private var selectedRecado: RecadoDTO?
    /// Só a ação "Apagar" do menu de overflow passa por aqui — `MuralFeedViewModel` não
    /// expõe um método de apagar (fora do `<files>` da Task 3 do plano, que não volta a
    /// tocar `MuralFeedViewModel.swift`), então a chamada mora nesta view, sempre seguida de
    /// `viewModel.reloadFromTop()` em caso de sucesso.
    private let apiClient = APIClient()

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
        .jkGlassBackground()
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.reloadFromTop()
        }
        .overlay(alignment: .bottomTrailing) {
            composeFAB
        }
        .sheet(isPresented: $isComposePresented) {
            composeSheet
        }
        .sheet(item: $selectedRecado, onDismiss: {
            Task { await viewModel.reloadFromTop() }
        }) { recado in
            RecadoDetailView(recado: recado, photoURLs: viewModel.photoURLs(for: recado.id), apiClient: apiClient)
        }
    }

    /// Modo novo quando `editingRecado` é `nil` (FAB), modo edição quando não é (item
    /// "Editar" do menu de overflow, com o texto atual pré-preenchido). No sucesso: modo
    /// novo insere localmente o recado no topo do feed sem recarregar; modo edição recarrega
    /// a primeira página, já que o cartão editado pode não ser mais o primeiro.
    @ViewBuilder
    private var composeSheet: some View {
        if let editingRecado {
            ComposeRecadoView(mode: .editing(recadoID: editingRecado.id), initialText: editingRecado.text ?? "") { _ in
                Task { await viewModel.reloadFromTop() }
            }
        } else {
            ComposeRecadoView(mode: .new) { recado in
                viewModel.insertLocally(recado)
            }
        }
    }

    /// "Mural" — papel de `Heading` na tabela de Tipografia do `02-UI-SPEC.md` (título de
    /// tela), não `Display` (reservado para hero moments, que esta tela não tem).
    private var titleRow: some View {
        Text(JKCopy.muralFeedTitle)
            .font(JKTypography.heading)
            .plainRow()
    }

    /// 3 `JKCard` vazios com o esqueleto de carregamento (`02-UI-SPEC.md` "loading | feed").
    private var loadingSkeleton: some View {
        ForEach(0..<3, id: \.self) { _ in
            JKCard {
                Color.clear.frame(height: JKLayout.memberRowMinHeight)
            }
            .jkShimmerPlaceholder(isActive: true)
            .plainRow()
        }
    }

    /// `02-UI-SPEC.md` "empty | feed" — heading + corpo, `JKSpacing.xxl` acima. Idêntico em
    /// qualquer contagem que chegue a zero, seja carga inicial ou depois de apagar o último
    /// recado.
    private var emptyState: some View {
        VStack(spacing: JKSpacing.sm) {
            Text(JKCopy.muralFeedEmptyHeading)
                .font(JKTypography.heading)
            Text(JKCopy.muralFeedEmptyBody)
                .font(JKTypography.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, JKSpacing.xxl)
        .plainRow()
    }

    /// `02-UI-SPEC.md` "populated | feed" + "partial | feed (load-more in flight/failed)" —
    /// cada linha dispara `loadNextPage()` quando é a última carregada (gatilho de rolagem
    /// infinita, `shouldTriggerNextPage(after:)` decide isso no view model, não aqui).
    @ViewBuilder
    private func loadedContent(items: [RecadoDTO]) -> some View {
        ForEach(items, id: \.id) { recado in
            RecadoCard(
                recado: recado,
                photoURLs: viewModel.photoURLs(for: recado.id),
                onEdit: { editingRecado = $0; isComposePresented = true },
                onDelete: handleDelete,
                onReact: { kind in
                    Task { await viewModel.toggleReaction(recadoID: recado.id, kind: kind) }
                },
                // Task 1 do plano 02-12: closures vazias de propósito — os métodos reais do
                // view-model (pin/unpin/archive) nascem na Task 2, que substitui estas
                // ligações pela real.
                onPin: { _ in },
                onUnpin: { _ in },
                onArchive: { _ in },
                inlineErrorMessage: viewModel.actionErrorRecadoID == recado.id ? viewModel.actionErrorMessage : nil,
                onOpenDetail: { selectedRecado = recado }
            )
            .plainRow()
            .task {
                if viewModel.shouldTriggerNextPage(after: recado.id) {
                    await viewModel.loadNextPage()
                }
            }
        }

        pageStateFooter
    }

    @ViewBuilder
    private var pageStateFooter: some View {
        switch viewModel.pageState {
        case .loadingMore:
            ProgressView()
                .frame(maxWidth: .infinity)
                .plainRow()
        case .failed(let message):
            VStack(spacing: JKSpacing.sm) {
                Text(message)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
                Button(JKCopy.retryButtonLabel) {
                    Task { await viewModel.retryNextPage() }
                }
                .font(JKTypography.body)
            }
            .frame(maxWidth: .infinity)
            .plainRow()
        case .idle, .exhausted:
            EmptyView()
        }
    }

    /// `02-UI-SPEC.md` "error | feed" — mensagem + "Tentar de novo" inline; quando
    /// `lastGood` não é nulo, mostra a lista preservada abaixo em vez de uma tela vazia
    /// (nunca navega para fora da tela).
    @ViewBuilder
    private func errorContent(message: String, lastGood: [RecadoDTO]?) -> some View {
        if let lastGood, !lastGood.isEmpty {
            loadedContent(items: lastGood)
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
        .frame(maxWidth: .infinity)
        .plainRow()
    }

    private var composeFAB: some View {
        Button {
            editingRecado = nil
            isComposePresented = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .resizable()
                .frame(width: JKLayout.minTapTarget, height: JKLayout.minTapTarget)
                .foregroundStyle(JKColor.jkAccent)
        }
        .accessibilityLabel(JKCopy.muralComposeAccessibilityLabel)
        .padding(JKSpacing.lg)
    }

    private func handleDelete(_ recado: RecadoDTO) {
        Task {
            do {
                try await apiClient.deleteRecado(id: recado.id)
                await viewModel.reloadFromTop()
            } catch {
                // O 02-UI-SPEC.md não define uma mensagem própria para "apagar falhou" fora
                // do compose — falha silenciosa aqui, o recado continua visível no feed
                // (reloadFromTop() só roda em caso de sucesso).
            }
        }
    }
}

private extension View {
    /// Esconde o chrome padrão de linha de `List` — mesmo helper de `HouseholdView.swift`,
    /// redeclarado aqui porque `private extension` é escopado por arquivo.
    func plainRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview {
    MuralFeedView()
}

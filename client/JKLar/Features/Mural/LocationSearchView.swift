import MapKit
import SwiftUI

/// Folha de busca de endereço por texto digitado (D-12, plano 02-10) — mesmo molde visual da
/// folha do seletor de membros: material espesso, raio de canto de folha, título no papel de
/// cabeçalho, e linhas de resultado com a mesma altura mínima de linha. Nenhum indicador de
/// carregamento é desenhado de propósito: os resultados do completador chegam por atualização
/// a cada tecla (02-UI-SPEC.md, linha "loading | location-search", backstop confirmado pela
/// verificação humana desta onda). Tocar numa linha resolve a escolha em nome + coordenada;
/// no sucesso a folha se fecha devolvendo o lugar por closure; uma falha de resolução mostra
/// a mesma mensagem de erro de busca e mantém a folha aberta.
struct LocationSearchView: View {
    @State private var searchService = LocationSearchService()
    @State private var query = ""
    /// Falha ao resolver uma escolha (distinta da falha de busca do completador) — exibida
    /// com a mesma cópia de erro, inline, e limpa na próxima tecla digitada.
    @State private var resolutionFailed = false
    @Environment(\.dismiss) private var dismiss

    /// Chamado só quando uma escolha resolve com sucesso — devolve o lugar (nome editável +
    /// coordenada instantânea) ao compose; o dismiss por cancelar/gesto não devolve nada.
    let onPick: (ResolvedLocation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: JKSpacing.lg) {
            Text(JKCopy.muralLocationSearchTitle)
                .font(JKTypography.heading)

            searchField

            if let message = displayedErrorMessage {
                Text(message)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
            } else if showsNoResults {
                Text(JKCopy.muralLocationSearchNoResults)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            }

            resultsArea

            Button(JKCopy.cancelButtonLabel) {
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(JKSpacing.lg)
        .background(.thickMaterial)
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
    }

    private var searchField: some View {
        HStack(spacing: JKSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(JKCopy.muralLocationSearchPlaceholder, text: $query)
                .font(JKTypography.body)
                .onChange(of: query) { _, newValue in
                    resolutionFailed = false
                    searchService.updateQuery(newValue)
                }
        }
    }

    /// A área de resultados está sempre presente (mesmo vazia): nada digitado ainda → vazia,
    /// sem gráfico ou texto extra (o placeholder do campo já carrega a orientação); erro →
    /// vazia, com a mensagem inline acima; populada → uma linha por completion, visualmente
    /// idêntica a uma linha do seletor de membros na mesma superfície: pino em círculo neutro
    /// + título no papel de corpo + subtítulo no papel de rótulo, altura mínima igual à do
    /// seletor (§Spacing Scale — nenhum valor novo).
    private var resultsArea: some View {
        List(displayedResults, id: \.self) { completion in
            Button {
                Task { await pick(completion) }
            } label: {
                HStack(spacing: JKSpacing.sm) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: JKSpacing.xs) {
                        Text(completion.title)
                            .font(JKTypography.body)
                            .lineLimit(1)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(JKTypography.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .frame(minHeight: JKLayout.memberRowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var displayedErrorMessage: String? {
        if let message = searchService.errorMessage { return message }
        return resolutionFailed ? JKCopy.muralLocationSearchError : nil
    }

    /// Com erro visível a área de lista fica presente e vazia (02-UI-SPEC.md, linha
    /// "error | location-search") — as linhas velhas não ficam atrás da mensagem.
    private var displayedResults: [MKLocalSearchCompletion] {
        displayedErrorMessage == nil ? searchService.results : []
    }

    private var showsNoResults: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchService.results.isEmpty
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        do {
            let resolved = try await searchService.resolve(completion)
            onPick(resolved)
            dismiss()
        } catch {
            resolutionFailed = true
        }
    }
}

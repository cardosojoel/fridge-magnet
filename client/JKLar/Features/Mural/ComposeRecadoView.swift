import JKLarShared
import SwiftUI

/// Folha de compose no caminho de texto — apresentada por `MuralFeedView` a partir do FAB
/// (modo novo) ou do item "Editar" do menu de overflow de `RecadoCard` (modo edição).
///
/// `.thickMaterial` + `JKLayout.sheetShape`, mesmo precedente visual de
/// `InviteSheet` (Fase 1). Pontos de extensão do plano 02-06 marcados em comentário, na
/// posição que o `02-UI-SPEC.md` descreve: botão de adicionar fotos com o contador "{n}/10",
/// e o gatilho do seletor de menção com a linha de chips.
struct ComposeRecadoView: View {
    @State private var viewModel: ComposeRecadoViewModel
    @Environment(\.dismiss) private var dismiss

    /// Chamado com o `RecadoDTO` criado/atualizado depois de um `submit()` bem-sucedido —
    /// quem apresenta a folha decide o que fazer (inserir no topo do feed, recarregar).
    let onSuccess: (RecadoDTO) -> Void

    init(
        mode: ComposeRecadoViewModel.Mode,
        initialText: String = "",
        onSuccess: @escaping (RecadoDTO) -> Void
    ) {
        _viewModel = State(initialValue: ComposeRecadoViewModel(mode: mode, initialText: initialText))
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JKSpacing.lg) {
            Text(title)
                .font(JKTypography.heading)

            // `axis: .vertical` + `lineLimit(1...10)`: o campo cresce com o texto e passa a
            // rolar internamente depois de ~10 linhas visíveis, para a folha não crescer sem
            // limite (02-UI-SPEC.md § Copywriting Contract, "Compose text field placeholder").
            TextField(JKCopy.muralComposeTextPlaceholder, text: $viewModel.text, axis: .vertical)
                .font(JKTypography.body)
                .lineLimit(1...10)
                .disabled(viewModel.isSubmitting)

            // MARK: - Ponto de extensão: botão "Adicionar fotos" + contador "{n}/10" (plano 02-06)
            // MARK: - Ponto de extensão: gatilho do seletor de menção + linha de chips (plano 02-06)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
            }

            submitButton

            Button(JKCopy.cancelButtonLabel) {
                dismiss()
            }
            .disabled(viewModel.isSubmitting)
            .frame(maxWidth: .infinity)
        }
        .padding(JKSpacing.lg)
        .background(.thickMaterial)
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
    }

    private var submitButton: some View {
        Button {
            Task {
                await viewModel.submit { recado in
                    onSuccess(recado)
                    dismiss()
                }
            }
        } label: {
            if viewModel.isSubmitting {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            } else {
                Text(ctaLabel)
            }
        }
        .buttonStyle(.jkPrimary)
        .disabled(!viewModel.canSubmit)
    }

    private var title: String {
        switch viewModel.mode {
        case .new: JKCopy.muralComposeTitleNew
        case .editing: JKCopy.muralComposeTitleEditing
        }
    }

    private var ctaLabel: String {
        switch viewModel.mode {
        case .new: JKCopy.muralComposeSubmitCTANew
        case .editing: JKCopy.muralComposeSubmitCTAEditing
        }
    }
}

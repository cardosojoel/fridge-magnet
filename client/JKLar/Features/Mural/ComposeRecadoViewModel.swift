import Foundation
import JKLarShared
import Observation

/// Formulário de compose no caminho de texto (plano 02-05 Task 3) — modela tanto a criação
/// de um recado novo quanto a edição do próprio, no molde de ação de
/// `HouseholdViewModel.removeMember` (ramo de erro tipado específico + genérico).
@MainActor
@Observable
final class ComposeRecadoViewModel {
    /// Decide título, rótulo do CTA e qual rota do `APIClient` chamar.
    enum Mode: Equatable {
        case new
        case editing(recadoID: UUID)
    }

    let mode: Mode
    var text: String
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    private let apiClient: APIClient

    /// A regra completa de D-01 é "texto não vazio **ou** ao menos uma foto anexada" — só a
    /// metade de texto está implementada aqui. O plano 02-06 estende esta mesma propriedade
    /// computada com a condição de foto; registrado aqui para quem ler este arquivo não
    /// interpretar a regra atual como a regra final.
    var canSubmit: Bool {
        !isSubmitting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(mode: Mode = .new, initialText: String = "", apiClient: APIClient = APIClient()) {
        self.mode = mode
        self.text = initialText
        self.apiClient = apiClient
    }

    /// Guarda de "já em voo" (mesma disciplina de `MuralFeedViewModel.loadNextPage()`):
    /// `submit()` chamado duas vezes em concorrência dispara exatamente uma chamada de rede.
    /// Nunca limpa `text` num erro — a pessoa não perde o que digitou.
    func submit(onSuccess: (RecadoDTO) -> Void) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let recado: RecadoDTO
            switch mode {
            case .new:
                recado = try await apiClient.createRecado(CreateRecadoRequest(text: text))
            case .editing(let recadoID):
                recado = try await apiClient.updateRecado(id: recadoID, UpdateRecadoRequest(text: text))
            }
            onSuccess(recado)
        } catch APIClientError.apiError(.notAuthor) {
            errorMessage = JKCopy.muralComposeNotAuthorError
        } catch {
            errorMessage = JKCopy.muralComposeGenericPublishError
        }
    }
}

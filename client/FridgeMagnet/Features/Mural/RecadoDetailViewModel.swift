import Foundation
import FridgeMagnetShared
import Observation

/// Alternância otimista de reação (D-07/D-07b) — pura e sem estado, reusada por
/// `MuralFeedViewModel.toggleReaction` (linha do feed) e `RecadoDetailViewModel.toggleReaction`
/// (detalhe do recado) para as duas telas nunca divergirem na semântica: tocar no emoji já
/// ativo limpa; tocar num diferente substitui (nunca acumula, D-07b).
enum ReactionOptimism {
    /// Aplica localmente a alternância — decrementa/remove a contagem do emoji que sai,
    /// incrementa/cria a do que entra. Não fala com a rede; quem chama decide o que fazer com
    /// o resultado (aplicar no estado local, e depois substituir pelo resumo real do servidor
    /// ou reverter a esta mesma entrada em caso de falha).
    static func applyToggle(
        reactions: [ReactionCountDTO], myReaction: ReactionKind?, tapped kind: ReactionKind
    ) -> (reactions: [ReactionCountDTO], myReaction: ReactionKind?) {
        var reactions = reactions
        if myReaction == kind {
            decrementCount(for: kind, in: &reactions)
            return (reactions, nil)
        } else {
            if let myReaction {
                decrementCount(for: myReaction, in: &reactions)
            }
            incrementCount(for: kind, in: &reactions)
            return (reactions, kind)
        }
    }

    /// Chama a rota de definir ou de remover, conforme `previousMyReaction` já era `kind` ou
    /// não — a mesma decisão que `applyToggle` faz localmente, agora contra o servidor.
    /// `DELETE` sem corpo (204) normaliza para um resumo vazio, nunca `nil` solto pro chamador
    /// tratar.
    static func resolve(
        recadoID: UUID, kind: ReactionKind, previousMyReaction: ReactionKind?, apiClient: APIClient
    ) async throws -> RecadoReactionSummaryDTO {
        if previousMyReaction == kind {
            let summary = try await apiClient.clearReaction(recadoID: recadoID)
            return summary ?? RecadoReactionSummaryDTO(reactions: [], myReaction: nil)
        } else {
            return try await apiClient.setReaction(recadoID: recadoID, kind: kind)
        }
    }

    private static func decrementCount(for kind: ReactionKind, in reactions: inout [ReactionCountDTO]) {
        guard let idx = reactions.firstIndex(where: { $0.kind == kind }) else { return }
        reactions[idx].count = max(0, reactions[idx].count - 1)
        if reactions[idx].count == 0 {
            reactions.remove(at: idx)
        }
    }

    private static func incrementCount(for kind: ReactionKind, in reactions: inout [ReactionCountDTO]) {
        if let idx = reactions.firstIndex(where: { $0.kind == kind }) {
            reactions[idx].count += 1
        } else {
            reactions.append(ReactionCountDTO(kind: kind, count: 1))
        }
    }
}

/// Detalhe de um recado (plano 02-07) — molde de `HouseholdViewModel`: `LoadState` de três
/// casos com `lastGood`, carrega a lista plana e cronológica de comentários (D-08). A reação
/// completa vive junto (`recado`/`toggleReaction`), reusando `ReactionOptimism` acima, para o
/// detalhe e o cartão do feed nunca divergirem na semântica de D-07b.
@MainActor
@Observable
final class RecadoDetailViewModel {
    enum LoadState {
        case loading
        case loaded(comments: [CommentDTO])
        case error(message: String, lastGood: [CommentDTO]?)
    }

    private(set) var state: LoadState = .loading
    /// Recado que a folha exibe — `private(set)`, só `toggleReaction` muda `reactions`/
    /// `myReaction`; o resto do recado (texto, autor, fotos, menções) é fixo pela vida da
    /// folha.
    private(set) var recado: RecadoDTO
    var commentText: String = ""
    private(set) var isSubmittingComment = false
    /// Erro inline de uma ação que falhou (reação ou envio de comentário) — nunca troca
    /// `state`, mesmo papel de `HouseholdViewModel.actionErrorMessage`.
    private(set) var actionErrorMessage: String?
    private(set) var selectedMentions: [MentionDTO] = []

    private let apiClient: APIClient
    /// Guarda de concorrência: `submitComment()` chamado duas vezes ao mesmo tempo dispara
    /// exatamente uma chamada de rede — mesmo raciocínio de `MuralFeedViewModel.isLoadingPage`.
    private var isSubmitting = false

    /// Falso com o campo vazio ou só espaços, ou enquanto um envio já está em voo — nunca
    /// dois envios concorrentes pelo mesmo botão.
    var canSubmitComment: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmittingComment
    }

    init(recado: RecadoDTO, apiClient: APIClient = APIClient()) {
        self.recado = recado
        self.apiClient = apiClient
    }

    /// Carga inicial (ou "Tentar de novo" depois de um erro) — sempre preserva a última lista
    /// boa antes de tentar de novo, mesmo padrão de `HouseholdViewModel.load()`. Uma resposta
    /// vazia é o estado vazio (D-08's "seja o primeiro a comentar"), nunca erro.
    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            let comments = try await apiClient.comments(recadoID: recado.id)
            state = .loaded(comments: comments)
        } catch {
            state = .error(message: FMCopy.muralCommentLoadError, lastGood: previousGood)
        }
    }

    /// Devolvido pelo `MentionPickerView` (reuso verbatim do plano 02-06) — substitui a
    /// seleção inteira, mesmo contrato de `ComposeRecadoViewModel.setMentions`.
    func setMentions(_ mentions: [MentionDTO]) {
        selectedMentions = mentions
    }

    /// `POST .../comments` — sucesso acrescenta ao FIM da lista (D-08: cronológica crescente,
    /// o comentário novo é sempre o mais recente) e limpa o campo/seleção; falha põe a cópia
    /// genérica de erro sem limpar nada, pra pessoa não perder o que escreveu nem quem marcou.
    func submitComment() async {
        guard canSubmitComment, !isSubmitting else { return }
        isSubmitting = true
        isSubmittingComment = true
        actionErrorMessage = nil
        defer {
            isSubmitting = false
            isSubmittingComment = false
        }

        let text = commentText
        let mentionedUserIDs = selectedMentions.map(\.userID)

        do {
            let comment = try await apiClient.createComment(
                recadoID: recado.id, CreateCommentRequest(text: text, mentionedUserIDs: mentionedUserIDs)
            )
            if case .loaded(var comments) = state {
                comments.append(comment)
                state = .loaded(comments: comments)
            } else {
                state = .loaded(comments: [comment])
            }
            commentText = ""
            selectedMentions = []
        } catch {
            actionErrorMessage = FMCopy.muralCommentGenericPostError
        }
    }

    /// Repassa para `ReactionOptimism` (topo do arquivo) — mesma alternância otimista,
    /// substituição em vez de acúmulo, e reversão fiel em falha que `MuralFeedViewModel`
    /// aplica na linha do feed, agora sobre `recado` (um único item, não uma lista indexada).
    func toggleReaction(kind: ReactionKind) async {
        actionErrorMessage = nil
        let previousReactions = recado.reactions
        let previousMyReaction = recado.myReaction

        let optimistic = ReactionOptimism.applyToggle(
            reactions: previousReactions, myReaction: previousMyReaction, tapped: kind
        )
        recado.reactions = optimistic.reactions
        recado.myReaction = optimistic.myReaction

        do {
            let summary = try await ReactionOptimism.resolve(
                recadoID: recado.id, kind: kind, previousMyReaction: previousMyReaction, apiClient: apiClient
            )
            recado.reactions = summary.reactions
            recado.myReaction = summary.myReaction
        } catch {
            recado.reactions = previousReactions
            recado.myReaction = previousMyReaction
            actionErrorMessage = FMCopy.muralReactionErrorMessage
        }
    }

    private var currentGood: [CommentDTO]? {
        switch state {
        case .loading:
            return nil
        case .loaded(let comments):
            return comments
        case .error(_, let lastGood):
            return lastGood
        }
    }
}

import Foundation
import JKLarShared
import Observation

/// Carga do feed do mural — os seis estados de lista do 02-UI-SPEC.md (MURAL-05), no molde
/// de `HouseholdViewModel` (Fase 1).
///
/// `LoadState` cobre a tela inteira (carregando/carregado/erro, com a mesma disciplina de
/// "preserva a última lista boa" de `HouseholdViewModel`). `PageState` é a quarta linha de
/// estado que `LoadState` sozinho não cobre: a carga da próxima página nunca pode trocar o
/// estado da lista inteira, senão os itens já carregados desapareceriam da tela enquanto a
/// próxima página carrega ou falha.
///
/// `nextCursor` é guardado exatamente como o servidor devolveu em `RecadoFeedPage.nextCursor`
/// e reenviado sem transformação — o cliente nunca calcula posição nem deslocamento
/// (02-RESEARCH.md Pitfall 2).
@MainActor
@Observable
final class MuralFeedViewModel {
    enum LoadState {
        case loading
        case loaded(items: [RecadoDTO])
        case error(message: String, lastGood: [RecadoDTO]?)
    }

    enum PageState: Equatable {
        case idle
        case loadingMore
        case failed(message: String)
        case exhausted
    }

    private(set) var state: LoadState = .loading
    private(set) var pageState: PageState = .idle
    private(set) var items: [RecadoDTO] = []
    /// Bloco de fixados (D-14, plano 02-12) — FORA da paginação por cursor: preenchido só
    /// pela primeira página (`load()`), nunca tocado por `loadNextPage()`, descartado e
    /// repopulado por `reloadFromTop()`. Não participa de `LoadState`: o bloco chega junto
    /// com a primeira página e os estados de carregando/erro do feed já o cobrem.
    private(set) var pinnedItems: [RecadoDTO] = []
    /// URLs de leitura por recado (plano 02-06 Task 3) — mapa **só de memória**: URL
    /// assinada é credencial temporária de leitura (validade curta), então não pode
    /// sobreviver a um refresh nem ser gravada em disco, preferências ou qualquer cache
    /// persistente.
    private(set) var photoURLsByRecado: [UUID: [PhotoDownloadDTO]] = [:]
    /// Erro inline de uma ação que falhou (toque de reação) — nunca troca `state`, mesmo
    /// papel de `HouseholdViewModel.actionErrorMessage`: uma reação que falhou não pode
    /// esvaziar a lista de recados da tela.
    private(set) var actionErrorMessage: String?
    /// Qual recado `actionErrorMessage` descreve (Rule 2 — funcionalidade crítica ausente do
    /// texto do plano): sem isto, `RecadoCard` não teria como saber SE a mensagem é sobre o
    /// próprio cartão ou sobre outro, e mostraria "Não foi possível reagir" pendurado embaixo
    /// de todos os cartões da lista ao mesmo tempo em vez de só naquele que o toque errou.
    private(set) var actionErrorRecadoID: UUID?

    private var nextCursor: Int64?
    /// Guarda de concorrência: `loadNextPage()` chamado duas vezes ao mesmo tempo dispara
    /// exatamente uma chamada de rede — a segunda chamada encontra `isLoadingPage == true`
    /// (já `true` antes do primeiro `await`, sem ponto de suspensão entre a checagem e a
    /// atribuição) e retorna sem fazer nada.
    private var isLoadingPage = false

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Carga inicial (ou "Tentar de novo" depois de um erro) — sempre busca a primeira
    /// página (`cursor: nil`), substituindo a lista inteira. Preserva a última lista boa
    /// antes de tentar, mesmo padrão de `HouseholdViewModel.load()`.
    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            let page = try await apiClient.feed(cursor: nil)
            items = page.items
            // Bloco de fixados (D-14): o servidor exclui os fixados de `items`, então
            // nenhum recado aparece nas duas listas ao mesmo tempo.
            pinnedItems = page.pinned
            nextCursor = page.nextCursor
            pageState = page.nextCursor == nil ? .exhausted : .idle
            state = .loaded(items: items)
            // União do fluxo e do bloco numa ÚNICA chamada em lote. Consequência de
            // esquecer a união: todo cartão fixado com foto renderiza carrossel vazio,
            // porque o mapa de URLs é indexado por recado e o recado fixado nunca teria
            // entrado na chamada em lote.
            await fetchPhotoURLs(for: items + pinnedItems)
        } catch {
            state = .error(message: JKCopy.muralFeedLoadError, lastGood: previousGood)
        }
    }

    /// Pull-to-refresh: descarta o cursor guardado, **o mapa de URLs de foto** (validade
    /// curta, não pode sobreviver a um refresh) **e o bloco de fixados** — `load()`
    /// repopula os três a partir da primeira página nova. Recarrega substituindo — nunca
    /// soma com o que já estava carregado.
    func reloadFromTop() async {
        nextCursor = nil
        photoURLsByRecado = [:]
        pinnedItems = []
        await load()
    }

    /// URLs de leitura de um recado — vazio quando o recado não tem foto, ou quando a busca
    /// em lote ainda não resolveu/falhou para ele.
    func photoURLs(for recadoID: UUID) -> [PhotoDownloadDTO] {
        photoURLsByRecado[recadoID] ?? []
    }

    /// Busca em lote (uma única chamada) as URLs de leitura dos recados de `pageItems` que
    /// têm foto — nunca uma chamada por recado. Uma falha aqui nunca põe o feed em `.error`:
    /// os recados continuam visíveis com o texto, só o carrossel daquele recado fica sem
    /// imagem (uma imagem faltando não é motivo para esvaziar a tela).
    private func fetchPhotoURLs(for pageItems: [RecadoDTO]) async {
        let recadoIDsWithPhotos = pageItems.filter { !$0.photos.isEmpty }.map(\.id)
        guard !recadoIDsWithPhotos.isEmpty else { return }
        do {
            let response = try await apiClient.photoDownloadURLs(recadoIDs: recadoIDsWithPhotos)
            for entry in response.recados {
                photoURLsByRecado[entry.recadoID] = entry.photos
            }
        } catch {
            // Falha silenciosa de propósito: a lista de recados continua visível, só falta
            // a imagem daquele carrossel.
        }
    }

    /// Rolagem infinita: acrescenta a próxima página ao fim da lista, sem remover os itens
    /// já carregados e sem duplicar nenhum id (defesa extra além da garantia de cursor do
    /// servidor — 02-RESEARCH.md Pitfall 2). Não faz nenhuma chamada de rede quando não há
    /// próxima página (`nextCursor == nil`).
    ///
    /// Nunca toca o bloco de fixados: o servidor manda bloco vazio a partir da segunda
    /// página, e atribuir esse vazio apagaria o bloco no meio da rolagem (D-14, plano
    /// 02-12 — gate de aceitação garante que este método não referencia o bloco).
    func loadNextPage() async {
        guard !isLoadingPage else { return }
        guard let cursor = nextCursor else { return }

        isLoadingPage = true
        pageState = .loadingMore
        defer { isLoadingPage = false }

        do {
            let page = try await apiClient.feed(cursor: cursor)
            let existingIDs = Set(items.map(\.id))
            let newItems = page.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: newItems)
            nextCursor = page.nextCursor
            pageState = page.nextCursor == nil ? .exhausted : .idle
            state = .loaded(items: items)
            // Só os recados da página nova — os já carregados já têm (ou já tentaram) sua
            // busca de URLs, refazer a chamada pra eles seria trabalho repetido.
            await fetchPhotoURLs(for: newItems)
        } catch {
            pageState = .failed(message: JKCopy.muralFeedLoadMoreError)
        }
    }

    /// Refaz a chamada de `loadNextPage()` com o mesmo cursor — `nextCursor` só muda em
    /// sucesso, então uma falha anterior deixa o cursor intacto para a retentativa.
    func retryNextPage() async {
        await loadNextPage()
    }

    /// Usado pelo compose (`ComposeRecadoView`, plano 02-05 Task 3): põe o recado recém-
    /// publicado na primeira posição sem refazer nenhuma chamada de rede.
    func insertLocally(_ recado: RecadoDTO) {
        items.insert(recado, at: 0)
        state = .loaded(items: items)
    }

    /// A view chama isto no `.task` da própria linha, comparando com o id recebido — a
    /// lógica de "é a última linha carregada?" mora aqui, não na view.
    func shouldTriggerNextPage(after id: UUID) -> Bool {
        items.last?.id == id
    }

    /// Alternância otimista de reação (D-07/D-07b, plano 02-07) — repassa para `ReactionOptimism`
    /// (declarado em `RecadoDetailViewModel.swift`, reusado por ambos), para o detalhe e o
    /// feed nunca divergirem na semântica de substituição. Aplica o otimismo local ANTES da
    /// chamada de rede resolver, substitui o resumo local pelo do servidor no sucesso, e
    /// reverte à cópia guardada na falha — nunca deixa a interface mostrando um estado que o
    /// servidor recusou.
    func toggleReaction(recadoID: UUID, kind: ReactionKind) async {
        actionErrorMessage = nil
        actionErrorRecadoID = nil
        // Localizador nas DUAS listas: um recado do bloco de fixados não está em `items`,
        // e procurar só lá tornaria o toque num cartão fixado um não-op silencioso.
        guard let location = locate(recadoID: recadoID) else { return }
        let previous = recado(at: location)
        let previousReactions = previous.reactions
        let previousMyReaction = previous.myReaction

        let optimistic = ReactionOptimism.applyToggle(
            reactions: previousReactions, myReaction: previousMyReaction, tapped: kind
        )
        applySummary(reactions: optimistic.reactions, myReaction: optimistic.myReaction, at: location)

        do {
            let summary = try await ReactionOptimism.resolve(
                recadoID: recadoID, kind: kind, previousMyReaction: previousMyReaction, apiClient: apiClient
            )
            applyReactionSummary(summary, toRecadoID: recadoID)
        } catch {
            // Re-localiza: as listas podem ter mudado enquanto a chamada estava em voo.
            guard let revertLocation = locate(recadoID: recadoID) else { return }
            applySummary(reactions: previousReactions, myReaction: previousMyReaction, at: revertLocation)
            actionErrorMessage = JKCopy.muralReactionErrorMessage
            actionErrorRecadoID = recadoID
        }
    }

    /// Substitui `reactions`/`myReaction` do item pelo resumo real do servidor — chamado no
    /// sucesso de `toggleReaction` e, quando o detalhe fecha, para o resumo de reação do
    /// cartão do feed refletir o que foi feito no detalhe (plano 02-07 Task 3). Passa pelo
    /// localizador: um recado fixado aberto no detalhe também precisa refletir o resumo.
    func applyReactionSummary(_ summary: RecadoReactionSummaryDTO, toRecadoID recadoID: UUID) {
        guard let location = locate(recadoID: recadoID) else { return }
        applySummary(reactions: summary.reactions, myReaction: summary.myReaction, at: location)
    }

    // MARK: - Ações de menu (D-14/D-15, plano 02-12)

    /// `PUT .../pin` — no sucesso recarrega do topo: é o que faz o cartão visivelmente
    /// entrar no bloco de fixados (contrato do Adendo 2). Na falha, mensagem compartilhada
    /// de erro de ação apontando o recado afetado — nunca troca o estado da tela, mesmo
    /// molde de `toggleReaction`.
    func pin(recadoID: UUID) async {
        actionErrorMessage = nil
        actionErrorRecadoID = nil
        do {
            _ = try await apiClient.pinRecado(id: recadoID)
            await reloadFromTop()
        } catch {
            actionErrorMessage = JKCopy.muralMenuActionErrorMessage
            actionErrorRecadoID = recadoID
        }
    }

    /// `DELETE .../pin` — exatamente o mesmo par sucesso/falha de `pin(recadoID:)`; a
    /// recarga é o que devolve o cartão à posição cronológica dele no fluxo.
    func unpin(recadoID: UUID) async {
        actionErrorMessage = nil
        actionErrorRecadoID = nil
        do {
            _ = try await apiClient.unpinRecado(id: recadoID)
            await reloadFromTop()
        } catch {
            actionErrorMessage = JKCopy.muralMenuActionErrorMessage
            actionErrorRecadoID = recadoID
        }
    }

    /// `PUT .../archive` — no sucesso remove o recado da lista em que ele estava (pelo
    /// localizador) e então recarrega do topo. A remoção local antes da recarga existe para
    /// a animação de remoção acontecer no momento do toque, e não só quando a resposta da
    /// recarga chegar. Na falha, não remove nada e põe a mensagem compartilhada apontando o
    /// recado afetado.
    func archive(recadoID: UUID) async {
        actionErrorMessage = nil
        actionErrorRecadoID = nil
        do {
            _ = try await apiClient.archiveRecado(id: recadoID)
            if let location = locate(recadoID: recadoID) {
                switch location {
                case .stream(let index):
                    items.remove(at: index)
                    state = .loaded(items: items)
                case .pinned(let index):
                    pinnedItems.remove(at: index)
                }
            }
            await reloadFromTop()
        } catch {
            actionErrorMessage = JKCopy.muralMenuActionErrorMessage
            actionErrorRecadoID = recadoID
        }
    }

    // MARK: - Localizador (plano 02-12)

    /// Em qual das duas listas um recado está (fluxo paginado ou bloco de fixados) e em que
    /// posição.
    private enum RecadoLocation {
        case stream(index: Int)
        case pinned(index: Int)
    }

    /// Localizador que procura nas DUAS listas — `toggleReaction`, `applyReactionSummary` e
    /// a remoção ao arquivar passam TODOS por aqui. Sem ele, qualquer interação num cartão
    /// do bloco de fixados seria silenciosamente ignorada, porque esses métodos procuravam
    /// só na lista paginada (a regressão mais provável desta onda — tem caso de teste
    /// nomeado próprio).
    private func locate(recadoID: UUID) -> RecadoLocation? {
        if let index = items.firstIndex(where: { $0.id == recadoID }) {
            return .stream(index: index)
        }
        if let index = pinnedItems.firstIndex(where: { $0.id == recadoID }) {
            return .pinned(index: index)
        }
        return nil
    }

    private func recado(at location: RecadoLocation) -> RecadoDTO {
        switch location {
        case .stream(let index): items[index]
        case .pinned(let index): pinnedItems[index]
        }
    }

    /// Ao mutar um item do fluxo, reatribui o estado de carga (mesma disciplina de sempre);
    /// a lista de fixados não participa de `LoadState` e não precisa disso.
    private func applySummary(reactions: [ReactionCountDTO], myReaction: ReactionKind?, at location: RecadoLocation) {
        switch location {
        case .stream(let index):
            items[index].reactions = reactions
            items[index].myReaction = myReaction
            state = .loaded(items: items)
        case .pinned(let index):
            pinnedItems[index].reactions = reactions
            pinnedItems[index].myReaction = myReaction
        }
    }

    private var currentGood: [RecadoDTO]? {
        switch state {
        case .loading:
            return nil
        case .loaded(let items):
            return items
        case .error(_, let lastGood):
            return lastGood
        }
    }
}

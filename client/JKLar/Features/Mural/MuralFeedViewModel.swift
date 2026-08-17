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
    /// URLs de leitura por recado (plano 02-06 Task 3) — mapa **só de memória**: URL
    /// assinada é credencial temporária de leitura (validade curta), então não pode
    /// sobreviver a um refresh nem ser gravada em disco, preferências ou qualquer cache
    /// persistente.
    private(set) var photoURLsByRecado: [UUID: [PhotoDownloadDTO]] = [:]
    /// Erro inline de uma ação que falhou (toque de reação) — nunca troca `state`, mesmo
    /// papel de `HouseholdViewModel.actionErrorMessage`: uma reação que falhou não pode
    /// esvaziar a lista de recados da tela.
    private(set) var actionErrorMessage: String?

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
            nextCursor = page.nextCursor
            pageState = page.nextCursor == nil ? .exhausted : .idle
            state = .loaded(items: items)
            await fetchPhotoURLs(for: items)
        } catch {
            state = .error(message: JKCopy.muralFeedLoadError, lastGood: previousGood)
        }
    }

    /// Pull-to-refresh: descarta o cursor guardado **e o mapa de URLs de foto** (validade
    /// curta, não pode sobreviver a um refresh) e recarrega a primeira página, substituindo
    /// a lista — nunca soma com o que já estava carregado.
    func reloadFromTop() async {
        nextCursor = nil
        photoURLsByRecado = [:]
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
        guard let index = items.firstIndex(where: { $0.id == recadoID }) else { return }
        let previousReactions = items[index].reactions
        let previousMyReaction = items[index].myReaction

        let optimistic = ReactionOptimism.applyToggle(
            reactions: previousReactions, myReaction: previousMyReaction, tapped: kind
        )
        items[index].reactions = optimistic.reactions
        items[index].myReaction = optimistic.myReaction
        state = .loaded(items: items)

        do {
            let summary = try await ReactionOptimism.resolve(
                recadoID: recadoID, kind: kind, previousMyReaction: previousMyReaction, apiClient: apiClient
            )
            applyReactionSummary(summary, toRecadoID: recadoID)
        } catch {
            guard let revertIndex = items.firstIndex(where: { $0.id == recadoID }) else { return }
            items[revertIndex].reactions = previousReactions
            items[revertIndex].myReaction = previousMyReaction
            state = .loaded(items: items)
            actionErrorMessage = JKCopy.muralReactionErrorMessage
        }
    }

    /// Substitui `reactions`/`myReaction` do item pelo resumo real do servidor — chamado no
    /// sucesso de `toggleReaction` e, quando o detalhe fecha, para o resumo de reação do
    /// cartão do feed refletir o que foi feito no detalhe (plano 02-07 Task 3).
    func applyReactionSummary(_ summary: RecadoReactionSummaryDTO, toRecadoID recadoID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == recadoID }) else { return }
        items[index].reactions = summary.reactions
        items[index].myReaction = summary.myReaction
        state = .loaded(items: items)
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

import Foundation
import JKLarShared
import Observation

/// Carga do painel de arquivados do admin (D-15, plano 02-12) — molde de
/// `HouseholdViewModel`: `LoadState` de três casos com a última lista boa preservada,
/// `load()` sempre substituindo, e erro de ação inline que nunca troca o estado da tela.
///
/// Nenhuma checagem de papel neste arquivo, de propósito: a rota inteira é negada pelo
/// servidor (403 do middleware de papel, plano 02-11) para quem não é admin, e repetir a
/// regra aqui criaria uma segunda fonte de verdade a divergir — a linha escondida na aba
/// Casa é conveniência de interface, nunca a defesa (zero-trust, `.claude/CLAUDE.md`).
@MainActor
@Observable
final class ArchivedRecadosViewModel {
    enum LoadState {
        case loading
        case loaded(items: [RecadoDTO])
        case error(message: String, lastGood: [RecadoDTO]?)
    }

    private(set) var state: LoadState = .loading
    /// URLs de leitura por recado — mapa **só de memória**, exatamente como o do feed
    /// (plano 02-06): URL assinada é credencial temporária de leitura (validade curta) e
    /// nunca é gravada em disco, preferências ou qualquer cache persistente. A tela é
    /// descartada ao sair e o mapa vai junto (T-02-76).
    private(set) var photoURLsByRecado: [UUID: [PhotoDownloadDTO]] = [:]
    /// Erro inline de um desarquivamento que falhou — nunca troca `state`, mesmo papel de
    /// `MuralFeedViewModel.actionErrorMessage`.
    private(set) var actionErrorMessage: String?
    /// Qual cartão `actionErrorMessage` descreve — sem isto a mensagem apareceria pendurada
    /// embaixo de todos os cartões da lista ao mesmo tempo.
    private(set) var actionErrorRecadoID: UUID?
    /// Guarda de "já em voo" por recado (T-02-75): toques repetidos em Desarquivar no mesmo
    /// cartão disparam exatamente uma chamada de rede — a segunda encontra o id no conjunto
    /// (inserido antes de qualquer ponto de suspensão) e retorna sem fazer nada.
    private var unarchivesInFlight: Set<UUID> = []

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Carga da listagem (ou "Tentar de novo" depois de um erro) — a ordem é a que o
    /// servidor devolveu (mais recentemente arquivado primeiro), o cliente nunca reordena.
    /// Depois da lista, resolve as URLs de foto em **uma** chamada em lote para os itens
    /// que têm foto, com o mesmo tratamento silencioso de falha do feed (uma imagem
    /// faltando não é motivo para esvaziar a tela).
    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            let items = try await apiClient.archivedRecados()
            state = .loaded(items: items)
            await fetchPhotoURLs(for: items)
        } catch {
            state = .error(message: JKCopy.muralArchivedLoadError, lastGood: previousGood)
        }
    }

    /// URLs de leitura de um recado — vazio quando o recado não tem foto, ou quando a busca
    /// em lote ainda não resolveu/falhou para ele. Mesmo formato do feed.
    func photoURLs(for recadoID: UUID) -> [PhotoDownloadDTO] {
        photoURLsByRecado[recadoID] ?? []
    }

    /// `DELETE .../archive` — no sucesso remove aquele item da lista; na falha põe a
    /// mensagem compartilhada de erro de ação apontando o recado. A lista NÃO é recarregada
    /// no sucesso: a remoção local já é o resultado correto e uma recarga faria a tela
    /// piscar para chegar ao mesmo estado.
    func unarchive(recadoID: UUID) async {
        guard !unarchivesInFlight.contains(recadoID) else { return }
        unarchivesInFlight.insert(recadoID)
        defer { unarchivesInFlight.remove(recadoID) }

        actionErrorMessage = nil
        actionErrorRecadoID = nil
        do {
            _ = try await apiClient.unarchiveRecado(id: recadoID)
            guard case .loaded(var items) = state else { return }
            items.removeAll { $0.id == recadoID }
            state = .loaded(items: items)
        } catch {
            actionErrorMessage = JKCopy.muralMenuActionErrorMessage
            actionErrorRecadoID = recadoID
        }
    }

    /// Busca em lote (uma única chamada) — mesma disciplina de
    /// `MuralFeedViewModel.fetchPhotoURLs(for:)`: falha silenciosa de propósito, os cartões
    /// continuam visíveis com o texto e só o carrossel daquele recado fica sem imagem.
    private func fetchPhotoURLs(for items: [RecadoDTO]) async {
        let recadoIDsWithPhotos = items.filter { !$0.photos.isEmpty }.map(\.id)
        guard !recadoIDsWithPhotos.isEmpty else { return }
        do {
            let response = try await apiClient.photoDownloadURLs(recadoIDs: recadoIDsWithPhotos)
            for entry in response.recados {
                photoURLsByRecado[entry.recadoID] = entry.photos
            }
        } catch {
            // Falha silenciosa de propósito — ver doc-comment.
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

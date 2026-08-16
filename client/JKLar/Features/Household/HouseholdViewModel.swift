import Foundation
import JKLarShared
import Observation

/// Carga da casa e da lista de membros — os três estados obrigatórios do 01-UI-SPEC.md
/// (carregando, carregado, erro).
///
/// Nenhuma decisão de acesso é tomada aqui: o papel exibido no selo é o `myRole`/`role` que
/// o servidor devolveu, nunca uma inferência do cliente (T-07-02). A lista de membros vem de
/// `GET /api/v1/households/current/members` (exposta ao cliente pela primeira vez neste
/// plano) — nesta fatia ela sempre tem exatamente 1 elemento (o criador), mas o mesmo método
/// já é a listagem real que o plano 01-09 estende para 2–10 membros, sem trocar a chamada de
/// rede.
@MainActor
@Observable
final class HouseholdViewModel {
    enum LoadState {
        case loading
        case loaded(household: HouseholdDTO, members: [MemberDTO])
        case error(message: String, lastGood: (household: HouseholdDTO, members: [MemberDTO])?)
    }

    private(set) var state: LoadState = .loading

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Chamado no `.task` de `HouseholdView` e de novo pelo botão "Tentar de novo" — sempre
    /// preserva a última lista boa se uma já existia, antes de tentar de novo (01-UI-SPEC.md
    /// "error | member-list").
    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            guard let household = try await apiClient.currentHousehold() else {
                state = .error(message: JKCopy.householdLoadErrorMessage, lastGood: previousGood)
                return
            }
            let members = try await apiClient.members()
            state = .loaded(household: household, members: members)
        } catch {
            state = .error(message: JKCopy.householdLoadErrorMessage, lastGood: previousGood)
        }
    }

    private var currentGood: (household: HouseholdDTO, members: [MemberDTO])? {
        switch state {
        case .loading:
            return nil
        case .loaded(let household, let members):
            return (household, members)
        case .error(_, let lastGood):
            return lastGood
        }
    }
}

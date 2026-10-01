import Foundation
import FridgeMagnetShared
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
    /// Mensagem inline de uma ação destrutiva que falhou com `lastAdmin` — nunca troca
    /// `state`, a lista fica exatamente como estava (01-UI-SPEC.md "Destructive —
    /// last-admin block": "shown inline after the dialog dismisses, list stays put, user is
    /// not navigated away").
    private(set) var actionErrorMessage: String?

    private let apiClient: APIClient
    /// Injetado por `HouseholdView` via `.task` (a `@Environment(SessionStore.self)` só
    /// existe depois que a view aparece, não no `init` de um `@State`) — `nil` só antes desse
    /// primeiro `.task` rodar, ou em testes que não exercitam `leaveHousehold()`.
    var sessionStore: SessionStore?

    init(apiClient: APIClient = APIClient(), sessionStore: SessionStore? = nil) {
        self.apiClient = apiClient
        self.sessionStore = sessionStore
    }

    /// Chamado no `.task` de `HouseholdView` e de novo pelo botão "Tentar de novo" — sempre
    /// preserva a última lista boa se uma já existia, antes de tentar de novo (01-UI-SPEC.md
    /// "error | member-list").
    func load() async {
        let previousGood = currentGood
        state = .loading
        do {
            guard let household = try await apiClient.currentHousehold() else {
                state = .error(message: FMCopy.householdLoadErrorMessage, lastGood: previousGood)
                return
            }
            let members = try await apiClient.members()
            state = .loaded(household: household, members: members)
        } catch {
            state = .error(message: FMCopy.householdLoadErrorMessage, lastGood: previousGood)
        }
    }

    /// Falso para a própria linha (`member.isSelf`, sempre computado no servidor — plano
    /// 01-10) e para toda linha quando o requisitante não é admin; verdadeiro para as demais
    /// linhas quando o requisitante é admin. Conveniência de UI (T-10-07): a linha de defesa
    /// real é o 403/409 do servidor, esconder o botão aqui não substitui isso.
    func canRemove(_ member: MemberDTO) -> Bool {
        guard case .loaded(let household, _) = state, household.myRole == .admin else {
            return false
        }
        return !member.isSelf
    }

    /// `DELETE .../members/:memberID` — admin-only no servidor. Sucesso recarrega a lista
    /// (`load()`); `lastAdmin` (defesa contra corrida ou um estado que `canRemove(_:)` não
    /// previu) mostra a mensagem inline sem descartar a lista atual.
    func removeMember(_ member: MemberDTO) async {
        actionErrorMessage = nil
        do {
            try await apiClient.removeMember(id: member.id)
            await load()
        } catch APIClientError.apiError(.lastAdmin) {
            actionErrorMessage = FMCopy.householdLastAdminBlockMessage
        } catch {
            actionErrorMessage = FMCopy.onboardingCreateGenericError
        }
    }

    /// `PATCH /auth/profile` com só o nome — sucesso recarrega a lista (o nome novo tem de
    /// vir do servidor, nunca de uma edição otimista da linha: mesma disciplina de
    /// `removeMember`); falha mostra a mensagem inline sem descartar a lista atual. O corte
    /// no cliente (trim/vazio) é conforto — a validação real é o `.validation` do servidor.
    func updateDisplayName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actionErrorMessage = nil
        do {
            try await apiClient.updateProfile(displayName: trimmed)
            await load()
        } catch {
            actionErrorMessage = FMCopy.householdEditNameError
        }
    }

    /// `DELETE .../membership` — auto-serviço. Sucesso limpa a casa em cache no
    /// `SessionStore` (`refreshHouseholdState()`) e `RootView` reage voltando para
    /// `.needsHousehold` (D-02), sem navegação imperativa. `lastAdmin` mostra a mensagem
    /// inline e deixa a lista exatamente como estava.
    func leaveHousehold() async {
        actionErrorMessage = nil
        do {
            try await apiClient.leaveHousehold()
            await sessionStore?.refreshHouseholdState()
        } catch APIClientError.apiError(.lastAdmin) {
            actionErrorMessage = FMCopy.householdLastAdminBlockMessage
        } catch {
            actionErrorMessage = FMCopy.onboardingCreateGenericError
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

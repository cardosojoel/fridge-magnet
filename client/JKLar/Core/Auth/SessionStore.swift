import Foundation
import JKLarShared
import Observation

/// Estado observável de sessão, hidratado do Keychain no lançamento do app. `RootView` só
/// reflete `state` — nenhuma decisão de acesso é tomada aqui: casa e papel vêm sempre do que
/// o servidor respondeu (`GET /api/v1/households/current`), nunca de um valor assumido
/// localmente (T-05-06).
@MainActor
@Observable
final class SessionStore {
    private(set) var state: JKAppState = .loading
    private(set) var currentUser: UserDTO?
    private(set) var household: HouseholdDTO?

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
        let client = apiClient
        // O closure registrado em `APIClient` (um `actor`) vive tanto quanto ele — precisa
        // capturar `self` fraco para não criar um ciclo de retenção com `SessionStore`, que
        // por sua vez guarda `apiClient` forte.
        Task {
            await client.setSessionExpiredHandler { [weak self] in
                await self?.handleSessionExpired()
            }
        }
    }

    /// Chamado uma vez, no `.task` de `RootView`. Sem sessão salva → `.signedOut` direto,
    /// sem tocar a rede. Com sessão salva, reconfirma casa/papel no servidor — se o access
    /// token estiver vencido, `APIClient` renova sozinho (D-09); se a renovação falhar,
    /// `handleSessionExpired()` já foi chamado por dentro dessa chamada, e o `guard` abaixo
    /// não sobrescreve o `.signedOut` que ela já deixou.
    func hydrate() async {
        guard KeychainTokenStore.read() != nil else {
            state = .signedOut
            return
        }
        await resolveHouseholdState(fallbackHadHousehold: false)
    }

    /// Chamado por `LoginView` após `AppleSignInService` devolver um identity token válido.
    /// Lança para a view decidir a mensagem de erro — `SessionStore` não sabe de `JKCopy`.
    func signIn(provider: AuthProvider, identityToken: String, displayName: String?, gender: Gender?) async throws {
        let response = try await apiClient.createSession(
            provider: provider,
            identityToken: identityToken,
            displayName: displayName,
            gender: gender
        )
        currentUser = response.user
        await resolveHouseholdState(fallbackHadHousehold: response.household != nil)
    }

    /// D-11: o servidor decide o logout. Localmente só refletimos o resultado.
    func signOut() async {
        await apiClient.logout()
        await handleSessionExpired()
    }

    /// Sinalizado por `APIClient` quando uma renovação de 401 falha (refresh ausente,
    /// expirado ou revogado) — a única forma de `.signedOut` acontecer depois do app já ter
    /// mostrado uma tela autenticada.
    func handleSessionExpired() async {
        currentUser = nil
        household = nil
        state = .signedOut
    }

    /// Chamado por `HouseholdViewModel.leaveHousehold()` depois que o servidor confirma a
    /// saída (204) — reconfirma o estado da casa no mesmo caminho que `hydrate()`/`signIn()`
    /// usam (`GET /households/current`, agora sem casa) e deriva `.needsHousehold` a partir
    /// disso. Sem navegação imperativa: `RootView` só reflete `state`, o mesmo estado
    /// derivado estabelecido no plano 01-07 (D-02).
    func refreshHouseholdState() async {
        await resolveHouseholdState(fallbackHadHousehold: false)
    }

    private func resolveHouseholdState(fallbackHadHousehold: Bool) async {
        do {
            if let household = try await apiClient.currentHousehold() {
                self.household = household
                state = .inHousehold
            } else {
                self.household = nil
                state = .needsHousehold
            }
        } catch APIClientError.sessionExpired {
            // Já tratado por `handleSessionExpired()`, chamado de dentro de `APIClient`
            // antes deste erro subir — não sobrescrever o `.signedOut` que ela já deixou.
            return
        } catch {
            // Falha de rede transitória ao reconfirmar (não é sessão encerrada): cai para o
            // que o login acabou de informar, sem travar em `.loading` para sempre.
            state = fallbackHadHousehold ? .inHousehold : .needsHousehold
        }
    }
}

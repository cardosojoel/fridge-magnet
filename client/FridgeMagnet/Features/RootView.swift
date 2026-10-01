import SwiftUI

/// Estado de navegação de nível superior do app inteiro.
///
/// Os quatro casos são declarados desde já (plano 01-03) — declarar o enum completo, em vez
/// de só os casos que já tinham tela nas fatias anteriores, é o que impede que uma fase
/// futura invente navegação imperativa em cima de um roteador incompleto. Desde o plano
/// 01-07, os quatro casos têm destino real (D-02: `.needsHousehold` tem exatamente uma
/// saída, o gate de criar-ou-entrar).
enum FMAppState: Equatable {
    /// Resolvendo a sessão local no lançamento do app.
    case loading
    /// Nenhuma sessão válida encontrada — mostra `LoginView`.
    case signedOut
    /// Sessão válida, mas o usuário ainda não pertence a nenhuma casa — mostra
    /// `OnboardingView` (D-02, plano 01-07).
    case needsHousehold
    /// Sessão válida e o usuário já pertence a uma casa — mostra `HouseholdView` (plano
    /// 01-07).
    case inHousehold
}

/// Roteador de estado do app inteiro. `FridgeMagnetApp` injeta esta view na `WindowGroup`.
///
/// `SessionStore` (plano 01-05) é a única fonte do estado — `RootView` nunca decide
/// navegação por conta própria, só reflete `sessionStore.state`. Ao lançar, hidrata a sessão
/// do Keychain (`.loading` → `.signedOut`/`.needsHousehold`/`.inHousehold`, conforme o que o
/// servidor confirmar).
struct RootView: View {
    @State private var sessionStore: SessionStore
    /// Plano 01-12 (D-15) — construído sobre o mesmo `APIClient` de `sessionStore` (ver
    /// `init` abaixo), para o hook de reregistro em login/renovação
    /// (`APIClient.setSessionEstablishedHandler`) observar a sessão de verdade em vez de um
    /// `APIClient` desconectado.
    @State private var pushRegistrationService: PushRegistrationService
    /// D-13: o primer de notificação nasce exatamente na transição para `.inHousehold`
    /// (`.onChange` abaixo), nunca antes de haver casa. `PushRegistrationService.hasShownPrimer`
    /// (persistido, D-14) é o que impede o sheet de reabrir depois de concedido ou recusado —
    /// este `@State` só controla a apresentação da instância atual do app.
    @State private var isNotificationPrimerPresented = false

    init(pushRegistrationService: PushRegistrationService = PushRegistrationService(apiClient: APIClient())) {
        _pushRegistrationService = State(initialValue: pushRegistrationService)
        _sessionStore = State(initialValue: SessionStore(apiClient: pushRegistrationService.apiClient))
    }

    var body: some View {
        Group {
            switch sessionStore.state {
            case .loading:
                ProgressView()
            case .signedOut:
                LoginView()
            case .needsHousehold:
                // Gate obrigatório de casa (D-02) — .needsHousehold tem exatamente esta
                // saída, nenhum caminho leva o app para a tela da casa sem casa.
                OnboardingView()
            case .inHousehold:
                InHouseholdView()
            }
        }
        .environment(sessionStore)
        .environment(pushRegistrationService)
        .task {
            await sessionStore.hydrate()
        }
        .onChange(of: sessionStore.state) { _, newState in
            // Ancorado no roteador (nunca numa tela específica) — vale igualmente para quem
            // criou a casa (plano 01-07) e para quem entrou por convite (plano 01-09), sem
            // duplicar a apresentação em duas telas que poderiam divergir (D-13).
            if newState == .inHousehold, !pushRegistrationService.hasShownPrimer {
                isNotificationPrimerPresented = true
            }
        }
        .sheet(isPresented: $isNotificationPrimerPresented) {
            NotificationPrimerView(pushRegistrationService: pushRegistrationService)
        }
    }
}

/// Destino de `.inHousehold` desde o plano 02-05 — assunção do planejador registrada em
/// `<planner_assumptions>` do plano (o `02-UI-SPEC.md` fixa o título/FAB do feed, mas não
/// diz como o mural e a tela da casa convivem): duas abas, Mural primeiro (tela de uso
/// diário) e Casa depois (administração). Rótulos de `FMCopy`, confirmados no checkpoint de
/// verificação humana do plano.
private struct InHouseholdView: View {
    var body: some View {
        TabView {
            MuralFeedView()
                .tabItem {
                    Label(FMCopy.muralTabLabel, systemImage: "rectangle.stack")
                }

            HouseholdView()
                .tabItem {
                    Label(FMCopy.householdTabLabel, systemImage: "house.fill")
                }
        }
    }
}

#Preview {
    RootView()
}

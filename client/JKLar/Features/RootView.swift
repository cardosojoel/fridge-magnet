import SwiftUI

/// Estado de navegação de nível superior do app inteiro.
///
/// Os quatro casos são declarados desde já (plano 01-03) — declarar o enum completo, em vez
/// de só os casos que já tinham tela nas fatias anteriores, é o que impede que uma fase
/// futura invente navegação imperativa em cima de um roteador incompleto. Desde o plano
/// 01-07, os quatro casos têm destino real (D-02: `.needsHousehold` tem exatamente uma
/// saída, o gate de criar-ou-entrar).
enum JKAppState: Equatable {
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

/// Roteador de estado do app inteiro. `JKLarApp` injeta esta view na `WindowGroup`.
///
/// `SessionStore` (plano 01-05) é a única fonte do estado — `RootView` nunca decide
/// navegação por conta própria, só reflete `sessionStore.state`. Ao lançar, hidrata a sessão
/// do Keychain (`.loading` → `.signedOut`/`.needsHousehold`/`.inHousehold`, conforme o que o
/// servidor confirmar).
struct RootView: View {
    @State private var sessionStore = SessionStore()

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
                HouseholdView()
            }
        }
        .environment(sessionStore)
        .task {
            await sessionStore.hydrate()
        }
    }
}

#Preview {
    RootView()
}

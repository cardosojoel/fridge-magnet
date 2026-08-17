import SwiftUI

/// Estado do link `jklar://join/<CODE>` (plano 01-09, D-02/D-05) — guardado enquanto o
/// login acontece, para nunca furar a exigência de sessão nem o gate de casa: o código só
/// chega a `OnboardingView` depois que `RootView` chega em `.needsHousehold` de verdade,
/// nunca antes.
///
/// `@Observable` para `OnboardingView` reagir a um link aberto com o app já rodando
/// (comportamento #6 do `<behavior>` da Task 1 do plano 01-09), sem precisar de um segundo
/// mecanismo de navegação imperativa.
@MainActor
@Observable
final class DeepLinkRouter {
    private(set) var pendingJoinCode: String?

    /// Só reconhece o formato `jklar://join/<CODE>` — URLs de outro formato (ex.: os
    /// esquemas de retorno OAuth do GoogleSignIn/MSAL, plano 01-08) são ignoradas aqui de
    /// propósito, nunca tratadas como um código de convite.
    func handle(url: URL) {
        guard url.scheme == "jklar", url.host == "join" else { return }
        let code = url.pathComponents.last(where: { $0 != "/" })
        guard let code, !code.isEmpty else { return }
        pendingJoinCode = code
    }

    /// Consumido uma única vez por `OnboardingView` — evita reaplicar o mesmo código depois
    /// que o formulário já foi preenchido a partir dele.
    func consumePendingJoinCode() -> String? {
        defer { pendingJoinCode = nil }
        return pendingJoinCode
    }
}

/// Ponto de entrada único do app multiplataforma (iOS + macOS Tahoe).
///
/// Uma só `WindowGroup`, uma só cena — não existe divergência de lifecycle entre as duas
/// plataformas nesta fatia. `RootView` é o roteador de estado injetado aqui; qualquer
/// divergência real de plataforma (ex.: HealthKit, que não existe no macOS) vai morar em
/// `#if os(iOS)` dentro de arquivos específicos, nunca em uma segunda cena ou target.
///
/// O handler do link `jklar://` (plano 01-09) só guarda o código extraído em
/// `DeepLinkRouter` — nunca decide navegação sozinho. `RootView`/`OnboardingView` continuam
/// sendo os únicos dois pontos que decidem navegação (mesmo invariante do plano 01-07).
@main
struct JKLarApp: App {
    @State private var deepLinkRouter = DeepLinkRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(deepLinkRouter)
                .onOpenURL { url in
                    deepLinkRouter.handle(url: url)
                }
        }
    }
}

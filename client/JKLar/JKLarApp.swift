import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Ponte entre o delegate de app do SO (única forma de receber
/// `didRegisterForRemoteNotificationsWithDeviceToken`/
/// `didFailToRegisterForRemoteNotificationsWithError`, plano 01-12, D-15) e
/// `PushRegistrationService`. Dona da única instância de `PushRegistrationService`/
/// `APIClient` do app inteiro — `JKLarApp`/`RootView` leem a mesma instância via
/// `@UIApplicationDelegateAdaptor`/`@NSApplicationDelegateAdaptor` (`appDelegate.pushRegistrationService`),
/// nunca criam uma segunda. Sem isto, `RootView` teria seu próprio `APIClient` desconectado
/// e o hook de reregistro em login/renovação (`APIClient.setSessionEstablishedHandler`)
/// nunca veria os logins de verdade.
@MainActor
final class AppDelegate: NSObject {
    let pushRegistrationService = PushRegistrationService(apiClient: APIClient())
    /// Agendador de lembrete local (D-16, plano 02-15) — instância própria, como todo
    /// consumidor (o agendador não guarda estado; o estado vive nas requisições
    /// pendentes do sistema). O delegate precisa dele para o registro de categoria no
    /// arranque e para tratar as respostas de ação de adiar.
    let reminderScheduler = RecadoReminderScheduler()

}

/// Conformidade ao delegate do centro de notificações — declarada UMA vez, fora dos ramos
/// de plataforma (`UserNotifications` é multiplataforma; nada aqui diverge entre iOS e
/// macOS). Dois papéis: entrega em primeiro plano com banner e som (um lembrete invisível
/// porque a pessoa estava com o app aberto perde a única função dele — contrato do
/// `02-UI-SPEC.md` § Addendum 3) e encaminhamento das respostas de ação para o agendador.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extrai só valores primitivos (Sendable) da resposta antes de saltar para o
        // MainActor — o agendador decide sozinho se o identificador de ação é um adiar
        // válido (lista fechada; toque padrão e identificadores desconhecidos são
        // ignorados sem efeito, T-02-89).
        let actionIdentifier = response.actionIdentifier
        let requestIdentifier = response.notification.request.identifier
        let title = response.notification.request.content.title
        let userInfo = response.notification.request.content.userInfo
        let recadoID = userInfo[RecadoReminderScheduler.userInfoRecadoIDKey] as? String
        let eventAtSeconds = userInfo[RecadoReminderScheduler.userInfoEventAtKey] as? TimeInterval
        await reminderScheduler.handleActionResponse(
            actionIdentifier: actionIdentifier,
            requestIdentifier: requestIdentifier,
            title: title,
            recadoID: recadoID,
            eventAtSeconds: eventAtSeconds
        )
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // D-16 (plano 02-15), nesta ordem e ANTES de qualquer outra coisa do lançamento:
        // (1) a porta de permissão aponta para a instância viva de PushRegistrationService
        // — o caminho de permissão continua sendo UM só, o da Fase 1; (2) o delegate do
        // centro é atribuído já — um app aberto pela resposta a uma notificação entrega
        // essa resposta imediatamente depois do lançamento, e um delegate atribuído tarde
        // a perde; (3) a categoria é registrada no arranque, e não na hora de agendar:
        // uma requisição agendada com categoria não registrada aparece SEM as quatro
        // ações de adiar, e a falha é invisível até alguém receber um lembrete de verdade.
        NotificationAuthorizationGateway.attach(pushRegistrationService)
        UNUserNotificationCenter.current().delegate = self
        reminderScheduler.registerCategories()
        Task { await pushRegistrationService.resumePendingRegistrationIfNeeded() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await pushRegistrationService.registerDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushRegistrationService.didFailToRegister(error: error)
    }
}
#elseif os(macOS)
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // D-16 (plano 02-15) — mesma sequência e mesmo motivo do ramo iOS acima: porta de
        // permissão → delegate do centro → categoria registrada, tudo antes de qualquer
        // outra coisa do lançamento.
        NotificationAuthorizationGateway.attach(pushRegistrationService)
        UNUserNotificationCenter.current().delegate = self
        reminderScheduler.registerCategories()
        Task { await pushRegistrationService.resumePendingRegistrationIfNeeded() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await pushRegistrationService.registerDeviceToken(deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushRegistrationService.didFailToRegister(error: error)
    }
}
#endif

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

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            // `pushRegistrationService` passado explicitamente (plano 01-12, Task 2) — é o
            // que faz `RootView` construir `SessionStore` sobre o mesmo `APIClient` desta
            // instância, para o hook de D-15 (login/renovação disparando reregistro)
            // observar a sessão de verdade em vez de um `APIClient` desconectado.
            RootView(pushRegistrationService: appDelegate.pushRegistrationService)
                .environment(deepLinkRouter)
                .onOpenURL { url in
                    deepLinkRouter.handle(url: url)
                }
        }
    }
}

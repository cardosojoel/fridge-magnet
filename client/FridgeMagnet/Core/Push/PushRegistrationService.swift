import Foundation
import FridgeMagnetShared
import Observation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Abstração testável sobre `UNUserNotificationCenter.requestAuthorization(options:)` — o
/// método real dispara o prompt do sistema, que não tem como ser exercitado em
/// `PushRegistrationServiceTests` (nenhum teste toca UI do SO). `UNUserNotificationCenter`
/// já satisfaz esta assinatura, então não precisa de nenhum wrapper em produção.
protocol PushAuthorizationRequesting: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UNUserNotificationCenter: @retroactive @unchecked Sendable {}
extension UNUserNotificationCenter: PushAuthorizationRequesting {}

/// Espera entre tentativas de registro — injetável para `PushRegistrationServiceTests` não
/// esperarem segundos de verdade (2s/8s reais tornariam a suíte lenta e não é isso que o
/// teste quer provar; o que importa é a contagem exata de tentativas, não o tempo real).
protocol PushBackoffSleeping: Sendable {
    func sleep(seconds: Double) async
}

struct RealPushBackoffSleeper: PushBackoffSleeping {
    func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Último device token conhecido pelo dispositivo, persistido entre relançamentos (D-15).
/// `UserDefaults`, não Keychain: o device token não é uma credencial de acesso (T-12-04,
/// `<threat_model>` do plano 01-12) — só um identificador de entrega, e o Keychain fica
/// reservado à sessão (D-10, `KeychainTokenStore`).
enum PushDeviceTokenStore {
    private static let key = "com.fridgemagnet.push.lastKnownApnsTokenHex"

    static func save(_ hexToken: String) {
        UserDefaults.standard.set(hexToken, forKey: key)
    }

    static func read() -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}

/// Marca se o primer de notificação (plano 01-12, `NotificationPrimerView`) já foi
/// apresentado nesta instalação — D-13/D-14 exigem que ele apareça uma única vez, nunca
/// reaparecendo depois de concedido nem depois de recusado.
enum PushPrimerFlag {
    private static let key = "com.fridgemagnet.push.primerShown"

    static var hasShown: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Concentra todo o fluxo de push do dispositivo (plano 01-12): pedido de permissão,
/// obtenção do device token pelo delegate do SO, registro no backend com backoff, retomada
/// de um registro pendente no próximo lançamento, e reregistro a cada login/renovação de
/// sessão (D-15). `@MainActor`/`@Observable` — todo o fluxo de UI (`NotificationPrimerView`)
/// e o `AppDelegate`/`NSApplicationDelegateAdaptor` conversam com a mesma instância.
///
/// Zero-trust do `.claude/CLAUDE.md`: este arquivo manda um device token e recebe sucesso ou
/// falha — nenhuma decisão de autorização é tomada aqui (o servidor resolve `userId`/
/// `householdId` sozinho, `DeviceRegistrationRequest` nem carrega esses campos).
@MainActor
@Observable
final class PushRegistrationService {
    /// Exposto (não `private`) para `RootView` (plano 01-12, Task 2) construir `SessionStore`
    /// sobre o mesmo `APIClient` desta instância — só assim o hook de D-15
    /// (`setSessionEstablishedHandler`) observa de verdade o login/renovação que `SessionStore`
    /// dispara, em vez de um segundo `APIClient` desconectado.
    let apiClient: APIClient

    private let notificationCenter: any PushAuthorizationRequesting
    private let sleeper: PushBackoffSleeping

    /// "Nem 1, nem infinitas" (must_have do plano 01-12) — exatamente 3 tentativas por
    /// invocação de registro.
    private let maxAttempts = 3
    /// Backoff exponencial (por exemplo 2s, 8s do `<action>` do plano) entre as 3 tentativas
    /// — 2 intervalos para 3 tentativas.
    private let backoffSeconds: [Double] = [2, 8]

    init(
        apiClient: APIClient,
        notificationCenter: any PushAuthorizationRequesting = UNUserNotificationCenter.current(),
        sleeper: PushBackoffSleeping = RealPushBackoffSleeper()
    ) {
        self.apiClient = apiClient
        self.notificationCenter = notificationCenter
        self.sleeper = sleeper

        // Mesmo padrão já estabelecido por `SessionStore.init` para `setSessionExpiredHandler`
        // — o `actor` só aceita a gravação do handler de dentro de um contexto assíncrono.
        let client = apiClient
        Task { [weak self] in
            await client.setSessionEstablishedHandler { [weak self] in
                await self?.reregisterKnownDeviceTokenIfAny()
            }
        }
    }

    // MARK: - Primer (D-13/D-14, consumido por `NotificationPrimerView`)

    var hasShownPrimer: Bool { PushPrimerFlag.hasShown }

    /// Chamado pelo primer, nos dois caminhos de recusa (botão "Agora não" e prompt do
    /// sistema negado) — nunca reabre o primer depois disso (D-14).
    func markPrimerShown() {
        PushPrimerFlag.hasShown = true
    }

    // MARK: - Fluxo de permissão (chamado pelo primer)

    /// Pede a autorização do sistema (`.alert`, `.badge`, `.sound`) e, se concedida, dispara
    /// o registro remoto (`registerForRemoteNotifications()`), que devolve o device token de
    /// verdade pelo delegate. Uma falha ou recusa aqui nunca lança — quem chamou só lê o
    /// `Bool` devolvido (D-14: negar não pode virar um estado degradado).
    @discardableResult
    func requestAuthorization() async -> Bool {
        markPrimerShown()
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                beginRemoteRegistration()
            }
            return granted
        } catch {
            return false
        }
    }

    private func beginRemoteRegistration() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    // MARK: - Delegate hooks (`AppDelegate`/`NSApplicationDelegateAdaptor`, `FridgeMagnetApp.swift`)

    /// Chamado por `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Os
    /// bytes viram hexadecimal, o token é persistido (D-15, sobrevive a relançamento) e o
    /// registro no backend começa.
    func registerDeviceToken(_ tokenData: Data) async {
        let hexToken = Self.hexString(from: tokenData)
        PushDeviceTokenStore.save(hexToken)
        await performRegistration(hexToken: hexToken)
    }

    /// Chamado por `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Nenhum caminho de push pode derrubar o app (T-12-02/D-14) — não há nada além de log a
    /// fazer aqui; o app continua totalmente utilizável.
    func didFailToRegister(error: Error) {
        // Sem-op intencional além de log futuro (Fase 10 decide a política de logging,
        // `<threat_model>` T-12-04) — nenhum estado do app muda por causa de uma falha do SO.
    }

    // MARK: - Retomada no próximo lançamento (D-15)

    /// Chamado por `applicationDidFinishLaunching`/`application(_:didFinishLaunchingWithOptions:)`.
    /// Se um device token já é conhecido (de um registro anterior, com sucesso ou não), tenta
    /// registrá-lo de novo — cobre tanto "a última tentativa esgotou as 3 tentativas" quanto
    /// "o processo foi encerrado no meio do backoff".
    func resumePendingRegistrationIfNeeded() async {
        guard let hexToken = PushDeviceTokenStore.read() else { return }
        await performRegistration(hexToken: hexToken)
    }

    /// Handler registrado em `APIClient.setSessionEstablishedHandler` — dispara a cada login
    /// (`createSession`) e a cada renovação de sessão (`doRefresh`) bem-sucedidos (D-15). Sem
    /// device token conhecido ainda (ex.: permissão nunca concedida), não há nada a reenviar.
    private func reregisterKnownDeviceTokenIfAny() async {
        guard let hexToken = PushDeviceTokenStore.read() else { return }
        await performRegistration(hexToken: hexToken)
    }

    // MARK: - Registro com retry

    private func performRegistration(hexToken: String) async {
        var attempt = 1
        while attempt <= maxAttempts {
            do {
                try await apiClient.registerDevice(
                    DeviceRegistrationRequest(
                        apnsToken: hexToken,
                        platform: Self.currentPlatform,
                        environment: Self.currentEnvironment
                    )
                )
                return
            } catch {
                guard attempt < maxAttempts else {
                    // As 3 tentativas se esgotaram — o token já está persistido
                    // (`PushDeviceTokenStore`), então `resumePendingRegistrationIfNeeded()`
                    // no próximo lançamento (ou o próximo login/renovação) tenta de novo.
                    return
                }
                await sleeper.sleep(seconds: backoffSeconds[attempt - 1])
                attempt += 1
            }
        }
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static var currentPlatform: DevicePlatform {
        #if os(iOS)
        .ios
        #elseif os(macOS)
        .macos
        #endif
    }

    /// D-16 opção c (híbrido, aprovada no `checkpoint:decision` do plano 01-11): o cliente
    /// informa o próprio build (`#if DEBUG` → sandbox, senão produção); o backend corrige o
    /// ambiente gravado na linha uma única vez, no primeiro `BadDeviceToken`
    /// (`PushService.send`, `backend/Sources/App/Push/PushClient.swift`). Nunca inferido dos
    /// bytes do próprio token.
    private static var currentEnvironment: APNSEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

import Foundation
import JKLarShared
import UserNotifications

/// Abstração testável sobre o centro de notificações do sistema (D-16, plano 02-15) — o
/// centro real não funciona em teste unitário (agendar de verdade, listar pendentes de
/// verdade e ler autorização de verdade dependem do SO), então a fronteira é um protocolo,
/// não a classe do sistema — exatamente o mesmo motivo já registrado na Fase 1 para
/// `PushAuthorizationRequesting` (`Core/Push/PushRegistrationService.swift`).
///
/// Os nomes dos métodos são **deliberadamente distintos** dos nomes do centro real
/// (`add`, `pendingNotificationRequests`, `removePendingNotificationRequests`,
/// `setNotificationCategories`): o centro já tem métodos parecidos, e uma assinatura que
/// colide faz a conformidade ser satisfeita por acidente pelo método errado — a extensão
/// abaixo encaminha cada operação explicitamente, e o encaminhamento é visível.
///
/// `@MainActor` de propósito: o agendador, o delegate de app e os view-models que o
/// consomem já vivem no MainActor, e um protocolo isolado no mesmo ator elimina qualquer
/// travessia de fronteira com os tipos não-Sendable do framework de notificação
/// (`UNNotificationRequest`/`UNNotificationCategory`).
@MainActor
protocol LocalNotificationScheduling {
    func scheduleRequest(_ request: UNNotificationRequest) async throws
    func listPendingRequests() async -> [UNNotificationRequest]
    func removePending(identifiers: [String])
    func replaceCategories(_ categories: Set<UNNotificationCategory>)
    func readAuthorizationStatus() async -> UNAuthorizationStatus
}

/// Encaminhamento do centro real para o protocolo — cada operação mapeia para a API
/// correspondente do sistema. **Não redeclara** a conformidade de envio seguro sobre o
/// centro: ela já existe em `Core/Push/PushRegistrationService.swift` (Fase 1), e uma
/// segunda declaração não compila.
extension UNUserNotificationCenter: LocalNotificationScheduling {
    func scheduleRequest(_ request: UNNotificationRequest) async throws {
        try await add(request)
    }

    func listPendingRequests() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }

    func removePending(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        setNotificationCategories(categories)
    }

    func readAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Pedido de autorização de notificação visto pelo agendador — UMA operação, sem opções:
/// quem decide as opções do prompt é a entrada da Fase 1
/// (`PushRegistrationService.requestAuthorization()`), nunca este arquivo. A conformidade
/// de `PushRegistrationService` é **vazia** de propósito: a assinatura da Fase 1 já
/// satisfaz o protocolo sem nenhuma edição em `Core/Push/`.
@MainActor
protocol ReminderAuthorizationRequesting: AnyObject {
    func requestAuthorization() async -> Bool
}

extension PushRegistrationService: ReminderAuthorizationRequesting {}

/// A ÚNICA porta de permissão de notificação do app (`<planner_assumptions>` item 3 do
/// plano 02-15): o `AppDelegate` aponta a referência para a instância viva de
/// `PushRegistrationService` no arranque, e todo pedido de autorização do agendador passa
/// por aqui. O agendador **nunca** conversa com a API de autorização do sistema
/// diretamente — notificação local e remota compartilham a mesma autorização, então um
/// pedido próprio seria o mesmo prompt do sistema saindo de um segundo lugar, que é
/// precisamente o que o contrato de D-16 proíbe ("no second primer"). Referência fraca:
/// a porta nunca prolonga a vida do serviço da Fase 1 — o dono continua sendo o
/// `AppDelegate`.
@MainActor
enum NotificationAuthorizationGateway {
    private(set) static weak var requester: (any ReminderAuthorizationRequesting)?

    static func attach(_ requester: any ReminderAuthorizationRequesting) {
        self.requester = requester
    }

    /// Sem pedinte apontado (só possível antes do arranque completar), a resposta é
    /// "não concedido" — nunca um prompt improvisado.
    static func requestAuthorization() async -> Bool {
        guard let requester else { return false }
        return await requester.requestAuthorization()
    }
}

/// Valor padrão injetável do agendador — a porta em si é um tipo estático sem instância,
/// então este encaminhador-instância existe só para ela poder ocupar a posição de
/// dependência padrão do inicializador.
@MainActor
final class NotificationAuthorizationGatewayRequester: ReminderAuthorizationRequesting {
    func requestAuthorization() async -> Bool {
        await NotificationAuthorizationGateway.requestAuthorization()
    }
}

/// Agendador de lembrete local de recado (D-16, plano 02-15) — cada aparelho da casa
/// agenda sozinho a notificação local ao ver o recado no mural, incluindo o do autor.
///
/// **Sem estado próprio** (`<planner_assumptions>` item 2): todo o estado vive nas
/// requisições pendentes do próprio sistema, que sobrevivem ao app fechado — cada
/// consumidor pode construir a própria instância (mesmo padrão de `APIClient()` como
/// valor padrão em todo view-model), sem singleton e sem injeção por ambiente. O único
/// estado global é a porta de permissão acima, global exatamente porque tem de ser única.
///
/// Nenhuma falha deste arquivo pode derrubar o app: agendar é uma operação que pode
/// lançar, e o tratamento é registrar e seguir — mesma disciplina já escrita na Fase 1
/// para falha de registro de push ("nenhum caminho de notificação derruba o app").
@MainActor
final class RecadoReminderScheduler {
    // MARK: - Constantes de identificador (não são cópia — cópia visível vive em `JKCopy`)

    /// Identificador da categoria do banner — literal do `02-UI-SPEC.md` § Addendum 3
    /// ("category `RECADO_REMINDER`").
    static let categoryIdentifier = "RECADO_REMINDER"

    /// Lista fechada de minutos de adiar (D-16) — as quatro ações do banner, na ordem de
    /// exibição. Qualquer identificador de ação fora desta lista é ignorado sem efeito
    /// (T-02-89: entrada de resposta tratada com lista fechada, nunca interpretada
    /// livremente).
    static let snoozeMinutes = [5, 10, 15, 20]

    /// Identificador de uma ação de adiar — formato `RECADO_REMINDER_SNOOZE_{minutos}` do
    /// `02-UI-SPEC.md`. Montado por função para agendar (registro da categoria) e comparar
    /// (resposta recebida) nunca divergirem sobre a string.
    /// Nível de interrupção de TODA notificação de lembrete — a original e a adiada, numa
    /// constante só para as duas nunca divergirem (um adiamento de consulta médica não é
    /// menos urgente que o aviso original).
    ///
    /// `.timeSensitive` (decisão do Joel, 2026-08-19): o banner persiste na tela em vez dos
    /// ~5 s do nível `.active` e atravessa o modo Foco, que é o modo de falha real do uso
    /// pretendido — compromisso de saúde perdido porque o aviso passou despercebido. Exige o
    /// entitlement `com.apple.developer.usernotifications.time-sensitive` (client/project.yml):
    /// sem ele o SO rebaixa para `.active` em silêncio, sem erro em tempo de compilação nem
    /// de execução. O usuário mantém o controle final (Ajustes → Notificações → JK Lar →
    /// Avisos urgentes), como manda a HIG.
    static let reminderInterruptionLevel: UNNotificationInterruptionLevel = .timeSensitive

    static func snoozeActionIdentifier(minutes: Int) -> String {
        "RECADO_REMINDER_SNOOZE_\(minutes)"
    }

    /// O identificador determinístico `recado-<id>-reminder` — o ÚNICO ponto do app que
    /// monta essa string: agendar e cancelar montando o identificador em lugares
    /// diferentes é a forma clássica de o cancelamento silenciosamente não cancelar nada
    /// (a falha nem aparece — a requisição órfã só toca no futuro).
    static func requestIdentifier(for recadoID: UUID) -> String {
        "recado-\(recadoID.uuidString)-reminder"
    }

    /// Teto NOSSO de requisições pendentes (`<planner_assumptions>` item 4): o sistema
    /// descarta em silêncio requisições locais além do limite dele por app (64), e o
    /// descarte silencioso é o pior comportamento possível para um lembrete. Bem abaixo
    /// do limite do sistema de propósito — o módulo de remédios vai disputar o mesmo
    /// orçamento de pendentes. Política declarada: com o teto cheio, o lembrete que
    /// dispara mais cedo é o que fica (ver `reconcile`).
    static let maxPendingRequests = 24

    /// Chaves do `userInfo` — só tipos de property list entram ali (um `Date` ou `UUID`
    /// cru é falha em tempo de execução, não de compilação): o id do recado viaja como
    /// texto e o instante do evento como segundos desde a época. O id é o que torna o
    /// roteamento por toque uma extensão puramente aditiva no futuro (02-UI-SPEC.md,
    /// "Tap behavior" — extensão declarada, **nenhum roteamento é construído aqui**).
    /// `nonisolated`: o delegate de app lê estas chaves num contexto não-isolado (a
    /// extração de valores primitivos da resposta acontece antes do salto pro MainActor).
    nonisolated static let userInfoRecadoIDKey = "recadoID"
    nonisolated static let userInfoEventAtKey = "eventAt"

    // MARK: - Dependências

    private let center: any LocalNotificationScheduling
    private let authorizationRequester: any ReminderAuthorizationRequesting

    init(
        center: any LocalNotificationScheduling = UNUserNotificationCenter.current(),
        authorizationRequester: any ReminderAuthorizationRequesting = NotificationAuthorizationGatewayRequester()
    ) {
        self.center = center
        self.authorizationRequester = authorizationRequester
    }

    // MARK: - Registro de categoria (arranque)

    /// Monta a categoria com as quatro ações de adiar — todas em segundo plano (nenhuma
    /// abre o app), títulos de `JKCopy` — e substitui o conjunto de categorias do centro.
    /// Chamada uma vez, no arranque do app (`AppDelegate.didFinishLaunching`), **antes**
    /// de qualquer agendamento: uma requisição agendada com categoria não registrada
    /// aparece SEM as quatro ações, e a falha é invisível até alguém receber um lembrete
    /// de verdade.
    func registerCategories() {
        let actions = Self.snoozeMinutes.map { minutes in
            UNNotificationAction(
                identifier: Self.snoozeActionIdentifier(minutes: minutes),
                title: JKCopy.muralReminderSnoozeAction(minutes: minutes),
                options: []
            )
        }
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        center.replaceCategories([category])
    }

    // MARK: - Reconciliação (as quatro entradas de dado do mural)

    /// Reconcilia um lote de recados com as requisições pendentes deste aparelho. As
    /// regras, item a item:
    ///
    /// - disparo (evento − antecedência) no passado é **pulo silencioso**: não agenda
    ///   (nunca uma notificação atrasada, nunca reagendar o que já tocou) e não remove —
    ///   é o que preserva um lembrete adiado, cuja requisição pendente vive sob o mesmo
    ///   identificador com o disparo original já vencido (T-02-94);
    /// - recado do lote SEM lembrete com requisição pendente correspondente → removida;
    /// - recado com disparo futuro cuja pendente já dispara no mesmo instante → deixada
    ///   em paz (zero churn no lembrete inalterado);
    /// - qualquer outro caso → agendado (agendar com o mesmo identificador substitui,
    ///   sem varrer a lista de pendentes);
    /// - recados que **não** vieram no lote nunca são tocados: a paginação mostra só
    ///   parte do mural, e remover "tudo que não vi agora" apagaria os lembretes do
    ///   resto da casa (T-02-93 — a regressão mais provável desta onda).
    ///
    /// Teto (`maxPendingRequests`): com o número de pendentes no limite, só entra um
    /// lembrete que dispare antes do pendente mais distante — e nesse caso o mais
    /// distante sai. Um adiamento vivo (gatilho por intervalo, sem data extraível) nunca
    /// é candidato à remoção pelo teto.
    ///
    /// `now` é parâmetro com valor padrão para os testes fixarem o relógio — um teste
    /// que dependa do relógio real fica intermitente na virada da hora.
    func reconcile(_ recados: [RecadoDTO], now: Date = Date()) async {
        guard await resolveAuthorization() else { return }

        let pending = await center.listPendingRequests()
        var pendingIDs = Set(pending.map(\.identifier))
        var pendingFireDates: [String: Date] = [:]
        for request in pending {
            if let fireDate = Self.pendingFireDate(of: request) {
                pendingFireDates[request.identifier] = fireDate
            }
        }

        for recado in recados {
            let identifier = Self.requestIdentifier(for: recado.id)

            guard let eventAt = recado.eventAt,
                  let offsetSeconds = recado.remindOffsetSeconds,
                  let offset = ReminderOffset(rawValue: offsetSeconds) else {
                // Sem lembrete (ou par fora do conjunto fechado, que o servidor nem
                // deveria emitir): a pendente correspondente, se existir, é removida —
                // é o caminho do "removeu o lembrete na edição" visto pelos OUTROS
                // aparelhos (T-02-95).
                if pendingIDs.contains(identifier) {
                    center.removePending(identifiers: [identifier])
                    pendingIDs.remove(identifier)
                    pendingFireDates[identifier] = nil
                }
                continue
            }

            let fireDate = eventAt.addingTimeInterval(-TimeInterval(offset.rawValue))
            guard fireDate > now else { continue }

            if let existingFire = pendingFireDates[identifier],
               abs(existingFire.timeIntervalSince(fireDate)) < 1 {
                continue
            }

            if !pendingIDs.contains(identifier), pendingIDs.count >= Self.maxPendingRequests {
                guard let farthest = pendingFireDates.max(by: { $0.value < $1.value }),
                      fireDate < farthest.value else {
                    continue
                }
                center.removePending(identifiers: [farthest.key])
                pendingIDs.remove(farthest.key)
                pendingFireDates[farthest.key] = nil
            }

            await schedule(recado: recado, eventAt: eventAt, offset: offset, fireDate: fireDate, identifier: identifier)
            pendingIDs.insert(identifier)
            pendingFireDates[identifier] = fireDate
        }
    }

    // MARK: - Cancelamento (arquivar, apagar, remover na edição)

    /// Remove a requisição pendente daquele recado neste aparelho — usada por arquivar
    /// (`MuralFeedViewModel.archive`), apagar (`MuralFeedView.handleDelete`) e, nos
    /// outros aparelhos, pela reconciliação do recado que voltou sem lembrete.
    func cancelReminder(recadoID: UUID) {
        center.removePending(identifiers: [Self.requestIdentifier(for: recadoID)])
    }

    // MARK: - Resposta de ação (adiar)

    /// Trata a resposta a uma ação do banner. Só a lista fechada de adiar tem efeito:
    /// qualquer outro identificador — inclusive o de toque padrão do sistema e um
    /// identificador forjado por um build alterado (T-02-89) — é ignorado sem agendar
    /// nem remover nada. Adiar reagenda sob o **mesmo** identificador, com disparo por
    /// intervalo a partir de AGORA (nunca do disparo original), preservando o título
    /// recebido e trocando o corpo pela variante de adiado; a categoria continua a
    /// mesma, então adiar de novo continua possível — cada vez a partir de agora.
    ///
    /// Recebe pedaços primitivos (e não `UNNotificationResponse`) de propósito: uma
    /// resposta real não é construível em teste unitário, e o delegate de app extrai
    /// exatamente estes valores antes de chamar.
    func handleActionResponse(
        actionIdentifier: String,
        requestIdentifier: String,
        title: String,
        recadoID: String?,
        eventAtSeconds: TimeInterval?
    ) async {
        guard let minutes = Self.snoozeMinutes.first(where: {
            Self.snoozeActionIdentifier(minutes: $0) == actionIdentifier
        }) else { return }
        guard let recadoID, let eventAtSeconds else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = JKCopy.muralReminderSnoozedNotificationBody(
            eventAt: Date(timeIntervalSince1970: eventAtSeconds)
        )
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = Self.reminderInterruptionLevel
        content.userInfo = [
            Self.userInfoRecadoIDKey: recadoID,
            Self.userInfoEventAtKey: eventAtSeconds,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(minutes) * 60,
            repeats: false
        )
        let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: trigger)
        do {
            try await center.scheduleRequest(request)
        } catch {
            // Registrar e seguir — nenhum caminho de notificação derruba o app.
        }
    }

    // MARK: - Estado de autorização (consumido pelo compose)

    /// Leitura crua do estado — o compose mostra o aviso discreto SÓ no estado negado
    /// (indeterminado não mostra nada, por contrato do `02-UI-SPEC.md`).
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.readAuthorizationStatus()
    }

    // MARK: - Privados

    /// Negado encerra sem fazer nada (e sem pedir de novo — nenhum segundo prompt existe
    /// fora do primer da Fase 1); indeterminado aciona a porta de permissão UMA única vez
    /// e segue conforme o resultado; qualquer estado concedido segue direto.
    private func resolveAuthorization() async -> Bool {
        switch await center.readAuthorizationStatus() {
        case .denied:
            return false
        case .notDetermined:
            return await authorizationRequester.requestAuthorization()
        default:
            return true
        }
    }

    private func schedule(
        recado: RecadoDTO,
        eventAt: Date,
        offset: ReminderOffset,
        fireDate: Date,
        identifier: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = JKCopy.muralReminderNotificationTitle(
            text: recado.text,
            autor: recado.authorDisplayName
        )
        content.body = JKCopy.muralReminderNotificationBody(eventAt: eventAt, offset: offset)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = Self.reminderInterruptionLevel
        content.userInfo = [
            Self.userInfoRecadoIDKey: recado.id.uuidString,
            Self.userInfoEventAtKey: eventAt.timeIntervalSince1970,
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.scheduleRequest(request)
        } catch {
            // Registrar e seguir — nenhum caminho de notificação derruba o app (mesma
            // disciplina de `PushRegistrationService.didFailToRegister`).
        }
    }

    /// Instante de disparo de uma requisição pendente — extraído dos componentes do
    /// gatilho de calendário. Um gatilho por intervalo (lembrete adiado) não tem data
    /// extraível e devolve nulo de propósito: um adiamento vivo nunca entra na comparação
    /// de "mesmo instante" (o pulo silencioso já o protege) nem na eleição de "mais
    /// distante" do teto.
    private static func pendingFireDate(of request: UNNotificationRequest) -> Date? {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        return Calendar.current.date(from: trigger.dateComponents)
    }
}

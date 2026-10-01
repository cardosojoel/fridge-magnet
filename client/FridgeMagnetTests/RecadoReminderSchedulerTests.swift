import XCTest
import FridgeMagnetShared
import UserNotifications
@testable import FridgeMagnet

/// Centro de notificações falso — o centro real não funciona em teste unitário (mesmo
/// motivo do `FakeAuthorizationRequester` da Fase 1). Registra requisições agendadas,
/// identificadores removidos e categorias definidas; lista de pendentes e estado de
/// autorização são programáveis. `@MainActor` como o protocolo — nenhuma travessia de
/// ator com os tipos não-Sendable do framework.
@MainActor
private final class FakeNotificationCenter: LocalNotificationScheduling {
    private(set) var scheduledRequests: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var replacedCategorySets: [Set<UNNotificationCategory>] = []
    var pendingRequests: [UNNotificationRequest] = []
    var authorizationStatus: UNAuthorizationStatus = .authorized

    func scheduleRequest(_ request: UNNotificationRequest) async throws {
        scheduledRequests.append(request)
        // Agendar com o mesmo identificador substitui — mesmo comportamento do centro real.
        pendingRequests.removeAll { $0.identifier == request.identifier }
        pendingRequests.append(request)
    }

    func listPendingRequests() async -> [UNNotificationRequest] {
        pendingRequests
    }

    func removePending(identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        replacedCategorySets.append(categories)
    }

    func readAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }
}

/// Pedinte de autorização falso — conta chamadas, resultado programável. Nenhum teste
/// jamais aciona a porta de permissão real (`NotificationAuthorizationGateway`).
@MainActor
private final class FakeReminderAuthorizationRequester: ReminderAuthorizationRequesting {
    private(set) var requestCount = 0
    var result = true

    func requestAuthorization() async -> Bool {
        requestCount += 1
        return result
    }
}

@MainActor
final class RecadoReminderSchedulerTests: XCTestCase {
    /// Instante corrente FIXO de todos os casos — um teste que dependa do relógio real
    /// fica intermitente na virada da hora. Valor inteiro de segundos de propósito: o
    /// gatilho de calendário só carrega precisão de segundo.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeScheduler(
        center: FakeNotificationCenter,
        requester: FakeReminderAuthorizationRequester = FakeReminderAuthorizationRequester()
    ) -> RecadoReminderScheduler {
        RecadoReminderScheduler(center: center, authorizationRequester: requester)
    }

    private func makeRecado(
        id: UUID = UUID(),
        text: String? = "Consulta no consultório",
        eventAt: Date? = nil,
        remindOffsetSeconds: Int? = nil
    ) -> RecadoDTO {
        RecadoDTO(
            id: id,
            authorID: UUID(),
            authorDisplayName: "Alguém",
            isMine: false,
            text: text,
            sequence: 1,
            createdAt: now,
            updatedAt: now,
            photos: [],
            mentions: [],
            reactions: [],
            myReaction: nil,
            commentCount: 0,
            latestComments: [],
            eventAt: eventAt,
            remindOffsetSeconds: remindOffsetSeconds
        )
    }

    /// Requisição pendente com gatilho de calendário num instante conhecido — o cenário
    /// de "já agendado antes".
    private func pendingCalendarRequest(identifier: String, fireDate: Date) -> UNNotificationRequest {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: trigger)
    }

    /// Requisição pendente com gatilho por intervalo — a forma exata de um lembrete
    /// ADIADO vivo (é o que `handleActionResponse` agenda).
    private func pendingSnoozedRequest(identifier: String) -> UNNotificationRequest {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: trigger)
    }

    private func fireDate(of request: UNNotificationRequest) -> Date? {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        return Calendar.current.date(from: trigger.dateComponents)
    }

    // MARK: - Agendamento e identificador determinístico

    func testReconcileFutureReminderSchedulesExactlyOneRequestWithDeterministicIdentifierAndFireDate() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let eventAt = now.addingTimeInterval(3600)
        let recado = makeRecado(eventAt: eventAt, remindOffsetSeconds: 900)

        await sut.reconcile([recado], now: now)

        XCTAssertEqual(center.scheduledRequests.count, 1)
        let request = center.scheduledRequests[0]
        XCTAssertEqual(request.identifier, RecadoReminderScheduler.requestIdentifier(for: recado.id))
        XCTAssertEqual(fireDate(of: request), now.addingTimeInterval(2700), "disparo = evento − antecedência")
        XCTAssertEqual(request.content.categoryIdentifier, RecadoReminderScheduler.categoryIdentifier)
        XCTAssertEqual(
            request.content.userInfo[RecadoReminderScheduler.userInfoRecadoIDKey] as? String,
            recado.id.uuidString
        )
        XCTAssertEqual(
            request.content.userInfo[RecadoReminderScheduler.userInfoEventAtKey] as? TimeInterval,
            eventAt.timeIntervalSince1970
        )
        XCTAssertEqual(request.content.title, FMCopy.muralReminderNotificationTitle(text: recado.text, autor: "Alguém"))
        XCTAssertEqual(
            request.content.body,
            FMCopy.muralReminderNotificationBody(eventAt: eventAt, offset: .fifteenMinutes)
        )
    }

    func testReconcileSameBatchAgainDoesNotScheduleNorRemoveAnything() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recado = makeRecado(eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900)

        await sut.reconcile([recado], now: now)
        XCTAssertEqual(center.scheduledRequests.count, 1, "pré-condição: primeira reconciliação agendou")

        await sut.reconcile([recado], now: now)

        XCTAssertEqual(center.scheduledRequests.count, 1, "lembrete inalterado não é reagendado — zero churn")
        XCTAssertTrue(center.removedIdentifiers.isEmpty, "lembrete inalterado não é removido")
    }

    func testReconcileChangedEventDateReschedulesUnderSameIdentifierExactlyOnce() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recadoID = UUID()
        let original = makeRecado(id: recadoID, eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900)
        await sut.reconcile([original], now: now)

        let edited = makeRecado(id: recadoID, eventAt: now.addingTimeInterval(7200), remindOffsetSeconds: 900)
        await sut.reconcile([edited], now: now)

        XCTAssertEqual(center.scheduledRequests.count, 2, "a data mudou — reagendado exatamente uma vez")
        XCTAssertEqual(
            center.scheduledRequests.map(\.identifier),
            Array(repeating: RecadoReminderScheduler.requestIdentifier(for: recadoID), count: 2),
            "mesmo identificador — agendar substitui, nunca duplica"
        )
        XCTAssertTrue(center.removedIdentifiers.isEmpty, "substituição por identificador, sem remoção explícita")
        XCTAssertEqual(center.pendingRequests.count, 1)
        XCTAssertEqual(fireDate(of: center.pendingRequests[0]), now.addingTimeInterval(6300))
    }

    // MARK: - Pulo silencioso do passado (preserva adiamento vivo)

    func testReconcilePastFireDateWithPendingSnoozeSchedulesNothingAndRemovesNothing() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recadoID = UUID()
        let identifier = RecadoReminderScheduler.requestIdentifier(for: recadoID)
        // O cenário completo do adiamento vivo: requisição pendente sob aquele
        // identificador (o adiado, gatilho por intervalo) MAIS o recado cujo disparo
        // original já passou. Sem a pendente no cenário, este caso viraria só um teste
        // de "não agenda passado" e a regressão real — a reconciliação matando um
        // adiamento vivo (T-02-94) — passaria despercebida.
        center.pendingRequests = [pendingSnoozedRequest(identifier: identifier)]
        let recado = makeRecado(id: recadoID, eventAt: now.addingTimeInterval(-600), remindOffsetSeconds: 300)

        await sut.reconcile([recado], now: now)

        XCTAssertTrue(center.scheduledRequests.isEmpty, "disparo no passado nunca reagenda o que já tocou")
        XCTAssertTrue(center.removedIdentifiers.isEmpty, "o adiamento vivo sobrevive à reconciliação")
        XCTAssertEqual(center.pendingRequests.map(\.identifier), [identifier])
    }

    func testReconcilePastFireDateWithoutPendingSchedulesNothing() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recado = makeRecado(eventAt: now.addingTimeInterval(-3600), remindOffsetSeconds: 0)

        await sut.reconcile([recado], now: now)

        XCTAssertTrue(center.scheduledRequests.isEmpty, "nunca uma notificação atrasada")
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
    }

    // MARK: - Remoção pelo lote (recado sem lembrete) e proteção do que não veio

    func testReconcileRecadoWithoutReminderRemovesItsPendingRequest() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recadoID = UUID()
        let identifier = RecadoReminderScheduler.requestIdentifier(for: recadoID)
        center.pendingRequests = [
            pendingCalendarRequest(identifier: identifier, fireDate: now.addingTimeInterval(3600))
        ]
        let recado = makeRecado(id: recadoID, eventAt: nil, remindOffsetSeconds: nil)

        await sut.reconcile([recado], now: now)

        XCTAssertEqual(center.removedIdentifiers, [identifier], "recado do lote sem lembrete remove a pendente dele")
        XCTAssertTrue(center.pendingRequests.isEmpty)
        XCTAssertTrue(center.scheduledRequests.isEmpty)
    }

    func testReconcileNeverRemovesPendingRequestOfRecadoAbsentFromBatch() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let absentRecadoID = UUID()
        let absentIdentifier = RecadoReminderScheduler.requestIdentifier(for: absentRecadoID)
        center.pendingRequests = [
            pendingCalendarRequest(identifier: absentIdentifier, fireDate: now.addingTimeInterval(3600))
        ]
        // O lote traz OUTRO recado (uma página do meio do mural) — o recado da pendente
        // não veio. Remover "tudo que não vi agora" apagaria os lembretes do resto da
        // casa (T-02-93 — a regressão mais provável desta onda).
        let pageRecado = makeRecado(eventAt: now.addingTimeInterval(7200), remindOffsetSeconds: 300)

        await sut.reconcile([pageRecado], now: now)

        XCTAssertTrue(center.removedIdentifiers.isEmpty, "recado ausente do lote nunca é tocado")
        XCTAssertTrue(center.pendingRequests.map(\.identifier).contains(absentIdentifier))
    }

    // MARK: - Cancelamento por id

    func testCancelReminderRemovesExactlyThatRecadosRequestAndNoOther() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let targetID = UUID()
        let otherID = UUID()
        let targetIdentifier = RecadoReminderScheduler.requestIdentifier(for: targetID)
        let otherIdentifier = RecadoReminderScheduler.requestIdentifier(for: otherID)
        center.pendingRequests = [
            pendingCalendarRequest(identifier: targetIdentifier, fireDate: now.addingTimeInterval(600)),
            pendingCalendarRequest(identifier: otherIdentifier, fireDate: now.addingTimeInterval(1200)),
        ]

        sut.cancelReminder(recadoID: targetID)

        XCTAssertEqual(center.removedIdentifiers, [targetIdentifier])
        XCTAssertEqual(center.pendingRequests.map(\.identifier), [otherIdentifier], "nenhuma outra requisição é tocada")
    }

    // MARK: - Teto de pendentes (as duas direções)

    private func fillPendingToCeiling(_ center: FakeNotificationCenter, farthestFireDate: Date) -> String {
        let farthestIdentifier = RecadoReminderScheduler.requestIdentifier(for: UUID())
        for index in 0..<(RecadoReminderScheduler.maxPendingRequests - 1) {
            center.pendingRequests.append(pendingCalendarRequest(
                identifier: RecadoReminderScheduler.requestIdentifier(for: UUID()),
                fireDate: now.addingTimeInterval(TimeInterval(600 + index * 60))
            ))
        }
        center.pendingRequests.append(
            pendingCalendarRequest(identifier: farthestIdentifier, fireDate: farthestFireDate)
        )
        return farthestIdentifier
    }

    func testCeilingReachedIgnoresReminderFiringAfterFarthestPending() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let farthestFireDate = now.addingTimeInterval(100_000)
        _ = fillPendingToCeiling(center, farthestFireDate: farthestFireDate)
        let lateRecado = makeRecado(eventAt: now.addingTimeInterval(200_000), remindOffsetSeconds: 0)

        await sut.reconcile([lateRecado], now: now)

        XCTAssertTrue(center.scheduledRequests.isEmpty, "dispara depois do mais distante — ignorado")
        XCTAssertTrue(center.removedIdentifiers.isEmpty)
        XCTAssertEqual(center.pendingRequests.count, RecadoReminderScheduler.maxPendingRequests)
    }

    func testCeilingReachedEvictsFarthestWhenNewReminderFiresEarlier() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let farthestFireDate = now.addingTimeInterval(100_000)
        let farthestIdentifier = fillPendingToCeiling(center, farthestFireDate: farthestFireDate)
        let earlyRecado = makeRecado(eventAt: now.addingTimeInterval(300), remindOffsetSeconds: 0)

        await sut.reconcile([earlyRecado], now: now)

        XCTAssertEqual(center.removedIdentifiers, [farthestIdentifier], "o mais distante sai")
        XCTAssertEqual(center.scheduledRequests.map(\.identifier), [RecadoReminderScheduler.requestIdentifier(for: earlyRecado.id)], "o que dispara mais cedo entra")
        XCTAssertEqual(center.pendingRequests.count, RecadoReminderScheduler.maxPendingRequests, "o teto nunca é ultrapassado")
    }

    // MARK: - Resposta de ação (adiar)

    func testSnoozeActionReschedulesFromNowUnderSameIdentifierWithSnoozedBodyAndSameCategory() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recadoID = UUID()
        let identifier = RecadoReminderScheduler.requestIdentifier(for: recadoID)
        let eventAtSeconds = now.addingTimeInterval(600).timeIntervalSince1970

        await sut.handleActionResponse(
            actionIdentifier: RecadoReminderScheduler.snoozeActionIdentifier(minutes: 5),
            requestIdentifier: identifier,
            title: "Consulta no consultório",
            recadoID: recadoID.uuidString,
            eventAtSeconds: eventAtSeconds
        )

        XCTAssertEqual(center.scheduledRequests.count, 1)
        let request = center.scheduledRequests[0]
        XCTAssertEqual(request.identifier, identifier, "adiar reagenda sob o MESMO identificador")
        let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval, 300, "disparo por intervalo a partir de AGORA (+5 min)")
        XCTAssertEqual(request.content.title, "Consulta no consultório", "o título recebido é preservado")
        XCTAssertEqual(
            request.content.body,
            FMCopy.muralReminderSnoozedNotificationBody(eventAt: Date(timeIntervalSince1970: eventAtSeconds)),
            "corpo troca para a variante de adiado, sem a frase de antecedência"
        )
        XCTAssertEqual(
            request.content.categoryIdentifier,
            RecadoReminderScheduler.categoryIdentifier,
            "a categoria continua a mesma — adiar de novo continua possível"
        )
    }

    func testUnknownActionIdentifierSchedulesNothingAndRemovesNothing() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)

        await sut.handleActionResponse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: RecadoReminderScheduler.requestIdentifier(for: UUID()),
            title: "Qualquer",
            recadoID: UUID().uuidString,
            eventAtSeconds: now.timeIntervalSince1970
        )
        await sut.handleActionResponse(
            actionIdentifier: "IDENTIFICADOR_FORJADO",
            requestIdentifier: RecadoReminderScheduler.requestIdentifier(for: UUID()),
            title: "Qualquer",
            recadoID: UUID().uuidString,
            eventAtSeconds: now.timeIntervalSince1970
        )

        XCTAssertTrue(center.scheduledRequests.isEmpty, "fora da lista fechada de adiar, nada é agendado (T-02-89)")
        XCTAssertTrue(center.removedIdentifiers.isEmpty, "e nada é removido")
    }

    // MARK: - Autorização

    func testDeniedAuthorizationSchedulesNothingAndNeverRequestsPermission() async {
        let center = FakeNotificationCenter()
        center.authorizationStatus = .denied
        let requester = FakeReminderAuthorizationRequester()
        let sut = makeScheduler(center: center, requester: requester)
        let recado = makeRecado(eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900)

        await sut.reconcile([recado], now: now)

        XCTAssertTrue(center.scheduledRequests.isEmpty, "negado: nada é agendado")
        XCTAssertEqual(requester.requestCount, 0, "e nenhum pedido de permissão é feito fora do primer da Fase 1")
    }

    func testNotDeterminedAuthorizationTriggersPhase1GateExactlyOnceBeforeFirstScheduling() async {
        let center = FakeNotificationCenter()
        center.authorizationStatus = .notDetermined
        let requester = FakeReminderAuthorizationRequester()
        requester.result = true
        let sut = makeScheduler(center: center, requester: requester)
        let recados = [
            makeRecado(eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900),
            makeRecado(eventAt: now.addingTimeInterval(7200), remindOffsetSeconds: 300),
        ]

        await sut.reconcile(recados, now: now)

        XCTAssertEqual(requester.requestCount, 1, "a porta da Fase 1 é acionada exatamente uma vez, não uma por recado")
        XCTAssertEqual(center.scheduledRequests.count, 2, "concedido: o agendamento segue")
    }

    func testNotDeterminedAuthorizationDeniedByGateSchedulesNothing() async {
        let center = FakeNotificationCenter()
        center.authorizationStatus = .notDetermined
        let requester = FakeReminderAuthorizationRequester()
        requester.result = false
        let sut = makeScheduler(center: center, requester: requester)
        let recado = makeRecado(eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900)

        await sut.reconcile([recado], now: now)

        XCTAssertEqual(requester.requestCount, 1)
        XCTAssertTrue(center.scheduledRequests.isEmpty, "a porta negou — segue conforme o resultado")
    }

    // MARK: - Categoria

    func testRegisterCategoriesReplacesSetWithFourBackgroundSnoozeActions() {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)

        sut.registerCategories()

        XCTAssertEqual(center.replacedCategorySets.count, 1)
        guard let category = center.replacedCategorySets[0].first(
            where: { $0.identifier == RecadoReminderScheduler.categoryIdentifier }
        ) else {
            return XCTFail("categoria RECADO_REMINDER não registrada")
        }
        XCTAssertEqual(
            category.actions.map(\.identifier),
            RecadoReminderScheduler.snoozeMinutes.map { RecadoReminderScheduler.snoozeActionIdentifier(minutes: $0) },
            "exatamente as quatro ações de adiar, na ordem — e nenhum quinto botão"
        )
        XCTAssertEqual(
            category.actions.map(\.title),
            RecadoReminderScheduler.snoozeMinutes.map { FMCopy.muralReminderSnoozeAction(minutes: $0) }
        )
        for action in category.actions {
            XCTAssertFalse(action.options.contains(.foreground), "todas em segundo plano — nenhuma abre o app")
        }
    }

    // MARK: Nível de interrupção (Time Sensitive, decisão do Joel 2026-08-19)

    /// O lembrete original precisa nascer `.timeSensitive`: no nível padrão (`.active`) o
    /// banner dura ~5 s e o modo Foco o suprime — o modo de falha real do uso pretendido
    /// (compromisso de saúde perdido porque o aviso passou despercebido).
    func testScheduledReminderCarriesTimeSensitiveInterruptionLevel() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recado = makeRecado(eventAt: now.addingTimeInterval(3600), remindOffsetSeconds: 900)

        await sut.reconcile([recado], now: now)

        XCTAssertEqual(center.scheduledRequests.count, 1)
        XCTAssertEqual(center.scheduledRequests[0].content.interruptionLevel, .timeSensitive)
    }

    /// O lembrete ADIADO carrega o mesmo nível — um adiamento de consulta médica não é menos
    /// urgente que o aviso original, e a constante única existe para os dois nunca divergirem.
    func testSnoozedReminderCarriesTimeSensitiveInterruptionLevel() async {
        let center = FakeNotificationCenter()
        let sut = makeScheduler(center: center)
        let recadoID = UUID()
        let eventAt = now.addingTimeInterval(3600)

        await sut.handleActionResponse(
            actionIdentifier: RecadoReminderScheduler.snoozeActionIdentifier(minutes: 10),
            requestIdentifier: RecadoReminderScheduler.requestIdentifier(for: recadoID),
            title: "Consulta",
            recadoID: recadoID.uuidString,
            eventAtSeconds: eventAt.timeIntervalSince1970
        )

        XCTAssertEqual(center.scheduledRequests.count, 1)
        XCTAssertEqual(center.scheduledRequests[0].content.interruptionLevel, .timeSensitive)
    }

    // NOTA: o entitlement `com.apple.developer.usernotifications.time-sensitive`
    // (client/project.yml) é a outra metade deste recurso — sem ele o SO rebaixa `.timeSensitive`
    // para `.active` em silêncio. Não há caso automatizado para ele de propósito: o entitlement
    // só é assinável com a capability habilitada no App ID e, quando ela falta, o sintoma não é
    // um teste vermelho — é o app inteiro não lançar, o que a suíte acusa de forma muito mais
    // barulhenta que uma asserção. Os dois casos acima cobrem o que é do app (o nível pedido nos
    // dois caminhos de conteúdo); persistência do banner e travessia do modo Foco só são
    // observáveis a olho nu (WINDOWS.md item 15).
}

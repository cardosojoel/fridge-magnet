import APNS
import APNSCore
import Fluent
import FridgeMagnetShared
import Vapor
import VaporAPNS

/// Abstração sobre o envio de um único push via APNs — o único motivo de existir é permitir
/// um cliente falso em `DeviceTokenTests` (nenhum teste fala com o APNs de verdade,
/// acceptance_criteria do plano 01-11).
protocol PushClient: Sendable {
    func sendAlertNotification(
        deviceToken: String,
        environment: FridgeMagnetShared.APNSEnvironment,
        title: String,
        body: String
    ) async throws
}

/// Erro estruturado equivalente ao `BadDeviceToken` do APNs (`APNSError.reason ==
/// .badDeviceToken`) — o único caso que `PushService` reconhece para disparar a correção da
/// opção c aprovada em D-16.
struct BadDeviceTokenError: Error {}

/// Cliente real — encaminha para `app.apns` (vapor/apns 5.x), escolhendo o container
/// `.production`/`.development` a partir do `APNSEnvironment` gravado na linha do
/// dispositivo. Nunca tenta inferir o ambiente a partir dos bytes do próprio token
/// (01-RESEARCH.md Pitfall 1).
struct VaporAPNSPushClient: PushClient {
    let application: Application
    let topic: String

    func sendAlertNotification(
        deviceToken: String,
        environment: FridgeMagnetShared.APNSEnvironment,
        title: String,
        body: String
    ) async throws {
        let containerID: APNSContainers.ID = environment == .production ? .production : .development
        let notification = APNSAlertNotification(
            alert: .init(title: .raw(title), body: .raw(body)),
            expiration: .immediately,
            priority: .immediately,
            topic: topic
        )
        do {
            try await application.apns.client(containerID)
                .sendAlertNotification(notification, deviceToken: deviceToken)
        } catch let error as APNSError where error.reason == .badDeviceToken {
            throw BadDeviceTokenError()
        }
    }
}

/// Cliente-nulo usado como valor-padrão do getter de `Application.pushService` — nunca
/// realmente invocado em operação normal, porque `configure.swift` sempre define
/// `app.pushService` explicitamente (`NoopPushClient` fora de `.testing` só existiria se
/// alguém pulasse `configure(_:)`, o que já quebraria o resto do boot antes disso). Existe só
/// para o getter nunca precisar de um `fatalError` de "esqueceram de configurar".
struct NoopPushClient: PushClient {
    func sendAlertNotification(
        deviceToken: String,
        environment: FridgeMagnetShared.APNSEnvironment,
        title: String,
        body: String
    ) async throws {}
}

/// Orquestra o envio de um push para um `DeviceToken`, aplicando a correção de ambiente da
/// opção c aprovada no `checkpoint:decision` da Task 1 do plano 01-11 (D-16, "híbrido:
/// cliente informa, backend corrige"): o cliente informa o próprio ambiente no registro
/// (`#if DEBUG` → sandbox); se o primeiro envio falhar com `BadDeviceToken`, o backend grava
/// o ambiente oposto na linha e reenvia uma única vez. O retry não recaptura
/// `BadDeviceTokenError` — essa ausência de um segundo `catch` é a própria garantia
/// estrutural contra alternância infinita entre sandbox e produção, sem precisar de uma
/// coluna extra de "já corrigido".
struct PushService: Sendable {
    let client: any PushClient

    func send(to token: DeviceToken, title: String, body: String, on database: any Database) async throws {
        let declaredEnvironment = FridgeMagnetShared.APNSEnvironment(rawValue: token.environment) ?? .production
        do {
            try await client.sendAlertNotification(
                deviceToken: token.apnsToken,
                environment: declaredEnvironment,
                title: title,
                body: body
            )
        } catch is BadDeviceTokenError {
            let corrected: FridgeMagnetShared.APNSEnvironment = declaredEnvironment == .production ? .sandbox : .production
            token.environment = corrected.rawValue
            try await token.save(on: database)
            try await client.sendAlertNotification(
                deviceToken: token.apnsToken,
                environment: corrected,
                title: title,
                body: body
            )
        }
    }
}

private struct PushServiceStorageKey: StorageKey {
    typealias Value = PushService
}

extension Application {
    var pushService: PushService {
        get { self.storage[PushServiceStorageKey.self] ?? PushService(client: NoopPushClient()) }
        set { self.storage[PushServiceStorageKey.self] = newValue }
    }
}

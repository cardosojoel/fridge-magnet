import Fluent
import FluentSQL
import Foundation
import FridgeMagnetShared
import Vapor

/// Um push de @menção enfileirado pelo handler (`RecadoController.enqueueMentionPushes`),
/// ainda não enviado — só carrega o `deviceTokenID` (não o `DeviceToken` inteiro: a linha
/// pode não existir mais quando o middleware recarrega, e o token de verdade só é lido de
/// novo, sob RLS, depois do commit).
struct PendingMentionPush: Sendable {
    var deviceTokenID: UUID
    var title: String
    var body: String
}

private struct PendingMentionPushesStorageKey: StorageKey {
    typealias Value = [PendingMentionPush]
}

extension Request {
    /// Fila de pushes de @menção pendentes desta request — populada por
    /// `RecadoController.enqueueMentionPushes` dentro do handler, consumida por
    /// `MentionPushDispatchMiddleware` depois que a resposta já foi produzida.
    var pendingMentionPushes: [PendingMentionPush] {
        get { self.storage[PendingMentionPushesStorageKey.self] ?? [] }
        set { self.storage[PendingMentionPushesStorageKey.self] = newValue }
    }
}

/// Despacha os pushes de @menção enfileirados durante o handler — DEPOIS que a resposta já
/// foi produzida e, portanto, depois que a transação aberta por `HouseholdContextMiddleware`
/// já fechou (commit ou rollback).
///
/// Por que um middleware e não um trecho no handler: `HouseholdContextMiddleware` envolve o
/// handler inteiro numa transação (`req.db.transaction { ... }`), então qualquer envio de
/// push feito de dentro do handler sairia ANTES do commit — uma resposta de erro depois desse
/// envio deixaria push enviado para um recado que nunca chegou a existir (T-02-13,
/// 02-RESEARCH.md Anti-Patterns "Sending push before the DB transaction commits"). Registrar
/// este middleware ANTES de `HouseholdContextMiddleware` no `.grouped(...)` de
/// `RecadoController.boot` (nesta ordem: o primeiro é o mais externo) coloca o `respond`
/// deste middleware por FORA daquela transação — o `next.respond(to:)` abaixo só retorna
/// depois que a transação interna já fechou.
struct MentionPushDispatchMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: req)

        let pending = req.pendingMentionPushes
        guard !pending.isEmpty, (200...299).contains(Int(response.status.code)) else {
            // Vazio: nada para enviar (recado sem menção, D-10). Fora de 2xx: a request
            // falhou (ex.: 422 notHouseholdMember) — nenhum push pode sair para uma escrita
            // que não aconteceu.
            return response
        }

        guard let userID = try? req.auth.require(User.self).requireID(),
              let householdID = req.householdContext?.householdID
        else {
            req.logger.error("MentionPushDispatchMiddleware: contexto de casa/usuário ausente após resposta 2xx")
            return response
        }

        do {
            try await req.db.transaction { transactionDB in
                // Reaplica o contexto de tenant NUMA TRANSAÇÃO NOVA — a de
                // HouseholdContextMiddleware já fechou, e `SET LOCAL`/`set_config(..., true)`
                // não sobrevive fora da transação que o aplicou. Sem isto, a RLS de
                // device_tokens devolve zero linhas e nenhum push sai.
                try await HouseholdContextMiddleware.applyCurrentUserContext(userID: userID, on: transactionDB)
                try await HouseholdContextMiddleware.applyCurrentHouseholdContext(
                    householdID: householdID, on: transactionDB
                )

                let deviceTokenIDs = pending.map(\.deviceTokenID)
                let tokens = try await DeviceToken.query(on: transactionDB)
                    .filter(\.$id ~~ deviceTokenIDs)
                    .all()
                var tokensByID: [UUID: DeviceToken] = [:]
                for token in tokens {
                    guard let tokenID = token.id else { continue }
                    tokensByID[tokenID] = token
                }

                // Grupo de tarefas NÃO-cancelável: um token morto nunca pode impedir a
                // entrega aos outros destinatários do mesmo recado (02-RESEARCH.md
                // Pitfall 1) — a variante que propaga erro cancelaria todas as filhas
                // restantes no primeiro erro lançado (proibida aqui por isso).
                await withTaskGroup(of: Void.self) { group in
                    for item in pending {
                        guard let token = tokensByID[item.deviceTokenID] else { continue }
                        group.addTask {
                            do {
                                try await req.application.pushService.send(
                                    to: token, title: item.title, body: item.body, on: transactionDB
                                )
                            } catch {
                                req.logger.error(
                                    "push de @menção falhou para device token \(token.id?.uuidString ?? "?"): \(error)"
                                )
                            }
                        }
                    }
                }
            }
        } catch {
            req.logger.error("MentionPushDispatchMiddleware: falha ao reaplicar contexto de casa: \(error)")
        }

        return response
    }
}

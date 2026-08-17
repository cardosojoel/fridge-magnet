@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Prova o fan-out de push por @menção do plano 02-02 (MURAL-03), incluindo o caso
/// não-cancelável do `02-RESEARCH.md` Pitfall 1 — nenhum teste fala com o APNs de verdade,
/// tudo contra `FakePushClient` (definido em `DeviceTokenTests.swift`, plano 01-11).
final class RecadoMentionPushTests: XCTestCase {
    // MARK: Helpers de request (mesmo padrão de RecadoControllerTests/DeviceTokenTests)

    private static func postRecado(
        app: Application,
        bearer: String,
        text: String?,
        mentionedUserIDs: [UUID] = []
    ) async throws -> (status: HTTPStatus, dto: RecadoDTO?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTO: RecadoDTO?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(
                    CreateRecadoRequest(text: text, mentionedUserIDs: mentionedUserIDs), as: .json
                )
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTO = try res.content.decode(RecadoDTO.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTO, capturedError)
    }

    private static func patchRecado(
        app: Application,
        bearer: String,
        recadoID: UUID,
        text: String?,
        mentionedUserIDs: [UUID]
    ) async throws -> HTTPStatus {
        var capturedStatus: HTTPStatus = .internalServerError
        try await app.testable().test(
            .PATCH, "/api/v1/recados/\(recadoID.uuidString)",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(UpdateRecadoRequest(text: text, mentionedUserIDs: mentionedUserIDs), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
            }
        )
        return capturedStatus
    }

    private static func registerDevice(
        app: Application,
        bearer: String,
        apnsToken: String
    ) async throws {
        try await app.testable().test(
            .POST, "/api/v1/devices",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(
                    DeviceRegistrationRequest(apnsToken: apnsToken, platform: .ios, environment: .sandbox), as: .json
                )
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
            }
        )
    }

    // MARK: <behavior>

    func testMentioningThreeMembersEachWithOneDeviceSendsThreeNotifications() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 4)
            let admin = members[0]
            let mentioned = [members[1], members[2], members[3]]
            for (index, member) in mentioned.enumerated() {
                try await Self.registerDevice(app: app, bearer: member.token, apnsToken: "token-\(index)")
            }

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "reunião hoje",
                mentionedUserIDs: mentioned.map(\.userID)
            )
            XCTAssertEqual(posted.status, .created)

            let sent = await fakeClient.sentNotifications
            XCTAssertEqual(sent.count, 3)
            XCTAssertTrue(sent.allSatisfy { $0.title == "Você foi mencionado" })
            XCTAssertTrue(sent.allSatisfy { $0.body.contains("reunião hoje") })
        }
    }

    func testMemberWithTwoDevicesReceivesTwoNotifications() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            try await Self.registerDevice(app: app, bearer: adult.token, apnsToken: "device-1")
            try await Self.registerDevice(app: app, bearer: adult.token, apnsToken: "device-2")

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado", mentionedUserIDs: [adult.userID]
            )
            XCTAssertEqual(posted.status, .created)

            let sent = await fakeClient.sentNotifications
            XCTAssertEqual(sent.count, 2, "um membro com 2 device tokens recebe 2 envios, um por aparelho")
        }
    }

    func testNonMentionedMemberWithDeviceReceivesNothing() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            try await Self.registerDevice(app: app, bearer: adult.token, apnsToken: "device-not-mentioned")

            let posted = try await Self.postRecado(app: app, bearer: admin.token, text: "recado sem menção")
            XCTAssertEqual(posted.status, .created)

            let sent = await fakeClient.sentNotifications
            XCTAssertTrue(sent.isEmpty, "D-10: sem menção, sem push, mesmo com token registrado")
        }
    }

    func testRecadoWithoutMentionsSendsNothingEvenWithAllMembersRegistered() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 3)
            for (index, member) in members.enumerated() {
                try await Self.registerDevice(app: app, bearer: member.token, apnsToken: "device-\(index)")
            }

            let posted = try await Self.postRecado(app: app, bearer: members[0].token, text: "sem marcação")
            XCTAssertEqual(posted.status, .created)

            let sent = await fakeClient.sentNotifications
            XCTAssertTrue(sent.isEmpty, "D-10: nenhuma marcação, nenhum envio")
        }
    }

    func testDeadTokenOfFirstMentionedDoesNotBlockDeliveryToOthers() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 4)
            let admin = members[0]
            let mentioned = [members[1], members[2], members[3]]
            try await Self.registerDevice(app: app, bearer: mentioned[0].token, apnsToken: "dead-token")
            try await Self.registerDevice(app: app, bearer: mentioned[1].token, apnsToken: "ok-token-1")
            try await Self.registerDevice(app: app, bearer: mentioned[2].token, apnsToken: "ok-token-2")
            await fakeClient.failAlways(forDeviceToken: "dead-token")

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado com token morto",
                mentionedUserIDs: mentioned.map(\.userID)
            )
            XCTAssertEqual(posted.status, .created)

            let sent = await fakeClient.sentNotifications
            let sentTokens = Set(sent.map(\.token))
            XCTAssertEqual(
                sentTokens, ["ok-token-1", "ok-token-2"],
                "os outros dois destinatários recebem apesar do token morto do primeiro (Pitfall 1)"
            )
        }
    }

    func testMentioningSelfProducesNoPushToAuthor() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            try await Self.registerDevice(app: app, bearer: admin.token, apnsToken: "self-token")

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "marquei a mim mesmo", mentionedUserIDs: [admin.userID]
            )
            XCTAssertEqual(posted.status, .created)
            XCTAssertEqual(posted.dto?.mentions.count, 1, "a marcação é gravada mesmo sendo a si mesmo")

            let sent = await fakeClient.sentNotifications
            XCTAssertTrue(sent.isEmpty, "marcar a si mesmo nunca produz push para o próprio autor")
        }
    }

    func testFailedRequestProducesNoPush() async throws {
        try await TestSupport.withApp { app in
            let fakeClient = FakePushClient()
            app.pushService = PushService(client: fakeClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let admin = members[0]
            try await Self.registerDevice(app: app, bearer: admin.token, apnsToken: "some-token")

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "recado inválido", mentionedUserIDs: [UUID()]
            )
            XCTAssertEqual(posted.status, .unprocessableEntity)
            XCTAssertEqual(posted.error?.code, .notHouseholdMember)

            let sent = await fakeClient.sentNotifications
            XCTAssertTrue(sent.isEmpty, "uma requisição que termina em erro não deixa push para trás")
        }
    }

    func testPatchAddingOneMemberToExistingMentionsSendsOnlyToTheAddedMember() async throws {
        try await TestSupport.withApp { app in
            let creationClient = FakePushClient()
            app.pushService = PushService(client: creationClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 4)
            let admin = members[0]
            let alreadyMentioned = [members[1], members[2]]
            let addedMember = members[3]
            for member in [alreadyMentioned[0], alreadyMentioned[1], addedMember] {
                try await Self.registerDevice(app: app, bearer: member.token, apnsToken: "device-\(member.userID)")
            }

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: "original",
                mentionedUserIDs: alreadyMentioned.map(\.userID)
            )
            let recadoID = try XCTUnwrap(posted.dto?.id)

            // Cliente novo para o PATCH — isola os envios da criação (já provados pelos
            // testes acima) dos envios do PATCH, sem depender de um método de "resetar".
            let patchClient = FakePushClient()
            app.pushService = PushService(client: patchClient)

            let patchedStatus = try await Self.patchRecado(
                app: app, bearer: admin.token, recadoID: recadoID, text: "editado",
                mentionedUserIDs: alreadyMentioned.map(\.userID) + [addedMember.userID]
            )
            XCTAssertEqual(patchedStatus, .ok)

            let sent = await patchClient.sentNotifications
            XCTAssertEqual(sent.count, 1, "só a pessoa acrescentada nesta edição recebe push")
            XCTAssertEqual(sent.first?.token, "device-\(addedMember.userID)")
        }
    }

    func testPreviewUsesPhotoPlaceholderWhenNoTextAndTruncatesLongText() async throws {
        try await TestSupport.withApp { app in
            let noTextClient = FakePushClient()
            app.pushService = PushService(client: noTextClient)

            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let admin = members[0]
            let adult = members[1]
            try await Self.registerDevice(app: app, bearer: adult.token, apnsToken: "preview-token")

            let posted = try await Self.postRecado(
                app: app, bearer: admin.token, text: nil, mentionedUserIDs: [adult.userID]
            )
            XCTAssertEqual(posted.status, .created)

            let sentWithoutText = await noTextClient.sentNotifications
            XCTAssertEqual(sentWithoutText.count, 1)
            XCTAssertTrue(
                sentWithoutText.first?.body.contains("uma foto") == true,
                "sem texto, a prévia do push é sempre \"uma foto\""
            )

            let longTextClient = FakePushClient()
            app.pushService = PushService(client: longTextClient)

            let longText = String(repeating: "a", count: 200)
            let posted2 = try await Self.postRecado(
                app: app, bearer: admin.token, text: longText, mentionedUserIDs: [adult.userID]
            )
            XCTAssertEqual(posted2.status, .created)

            let sentWithLongText = await longTextClient.sentNotifications
            XCTAssertEqual(sentWithLongText.count, 1)
            let body = try XCTUnwrap(sentWithLongText.first?.body)
            XCTAssertTrue(body.contains(String(repeating: "a", count: 80)), "os primeiros ~80 caracteres aparecem")
            XCTAssertFalse(
                body.contains(String(repeating: "a", count: 81)), "o texto é truncado, não aparece por completo"
            )
        }
    }
}

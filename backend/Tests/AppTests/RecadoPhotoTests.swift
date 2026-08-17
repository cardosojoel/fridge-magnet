@testable import App
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import XCTVapor

/// Plano 02-04 — presign/confirm/urls de foto do carrossel (MURAL-01 parte foto, D-01, D-02),
/// e a leitura testável de `R2Config`. Todo teste de foto roda contra `FakeObjectStorageClient`
/// — nenhum teste desta classe fala com R2/SotoS3 de verdade (mesmo espírito de
/// `DeviceTokenTests` contra `FakePushClient`).
final class RecadoPhotoTests: XCTestCase {
    // MARK: R2Config.fromEnvironment()

    func testR2ConfigMissingVariableFailsNamingIt() throws {
        let keys = ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET_NAME"]
        let originalValues = keys.reduce(into: [String: String?]()) { result, key in
            result[key] = ProcessInfo.processInfo.environment[key]
        }
        defer {
            for key in keys {
                if let value = originalValues[key] ?? nil {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        func setAllFourPresent() {
            setenv("R2_ACCOUNT_ID", "test-account-id", 1)
            setenv("R2_ACCESS_KEY_ID", "test-access-key-id", 1)
            setenv("R2_SECRET_ACCESS_KEY", "test-secret-access-key", 1)
            setenv("R2_BUCKET_NAME", "jklar-recado-photos-test", 1)
        }

        setAllFourPresent()
        XCTAssertNoThrow(try R2Config.fromEnvironment(), "com as quatro presentes, a config carrega sem erro")

        for missingKey in keys {
            setAllFourPresent()
            unsetenv(missingKey)

            XCTAssertThrowsError(try R2Config.fromEnvironment()) { error in
                guard case let R2Config.LoadError.missingEnvironmentVariable(name) = error else {
                    return XCTFail("esperava missingEnvironmentVariable, achou \(error)")
                }
                XCTAssertEqual(name, missingKey, "a mensagem de erro precisa nomear exatamente a variável ausente")
            }
        }
    }

    func testR2ConfigEndpointDerivedFromAccountID() throws {
        setenv("R2_ACCOUNT_ID", "abc123", 1)
        setenv("R2_ACCESS_KEY_ID", "key", 1)
        setenv("R2_SECRET_ACCESS_KEY", "secret", 1)
        setenv("R2_BUCKET_NAME", "bucket", 1)
        defer {
            unsetenv("R2_ACCOUNT_ID")
            unsetenv("R2_ACCESS_KEY_ID")
            unsetenv("R2_SECRET_ACCESS_KEY")
            unsetenv("R2_BUCKET_NAME")
        }
        let config = try R2Config.fromEnvironment()
        XCTAssertEqual(config.endpoint, "https://abc123.r2.cloudflarestorage.com")
    }

    // MARK: Task 4 — presign/confirm/urls, comportamento de RecadoPhotoController

    func testPresignThreeSlotsReturnsThreeUploadsAndWritesNoRows() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "com fotos")

            let slots = (0..<3).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let result = try await Self.postPresign(app: app, bearer: author.token, recadoID: recado.id, slots: slots)

            XCTAssertEqual(result.status, .ok)
            let uploads = try XCTUnwrap(result.response?.uploads)
            XCTAssertEqual(uploads.count, 3)

            let rows = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rows.count, 0, "presign nunca grava linha — só assina URL de PUT")
        }
    }

    func testPresignBeyondTenPhotosIsRejected() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "carrossel grande")

            let slots = (0..<11).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let result = try await Self.postPresign(app: app, bearer: author.token, recadoID: recado.id, slots: slots)

            XCTAssertEqual(result.status, .badRequest)
            XCTAssertEqual(result.error?.code, .photoLimitExceeded)
            XCTAssertNil(result.response)
            let signedCount = await fake.signedPutKeys.count
            XCTAssertEqual(signedCount, 0, "recusado antes de assinar qualquer URL")
        }
    }

    func testPresignCountsAlreadyConfirmedPhotos() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "quase cheio")
            _ = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: author.token, recadoID: recado.id, fake: fake, count: 8
            )

            let fourMoreSlots = (0..<4).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let result = try await Self.postPresign(
                app: app, bearer: author.token, recadoID: recado.id, slots: fourMoreSlots
            )

            XCTAssertEqual(result.status, .badRequest)
            XCTAssertEqual(result.error?.code, .photoLimitExceeded, "8 existentes + 4 pedidas > 10")
        }
    }

    func testPresignWithinRemainingCapacityIsAccepted() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "quase cheio")
            _ = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: author.token, recadoID: recado.id, fake: fake, count: 8
            )

            let twoMoreSlots = (0..<2).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let result = try await Self.postPresign(
                app: app, bearer: author.token, recadoID: recado.id, slots: twoMoreSlots
            )

            XCTAssertEqual(result.status, .ok, "8 existentes + 2 pedidas == 10, ainda dentro do teto")
            XCTAssertEqual(result.response?.uploads.count, 2)
        }
    }

    func testNonAuthorCannotPresignOrConfirm() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[0]
            let otherMember = members[1]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "recado do autor")

            let presignResult = try await Self.postPresign(
                app: app, bearer: otherMember.token, recadoID: recado.id,
                slots: [PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000)]
            )
            XCTAssertEqual(presignResult.status, .forbidden)
            XCTAssertEqual(presignResult.error?.code, .notAuthor)

            let confirmResult = try await Self.postConfirm(
                app: app, bearer: otherMember.token, recadoID: recado.id, objectKeys: ["qualquer-chave"]
            )
            XCTAssertEqual(confirmResult.status, .forbidden)
            XCTAssertEqual(confirmResult.error?.code, .notAuthor)
        }
    }

    func testPresignAndConfirmOnRecadoFromAnotherHouseholdReturns404() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let recadoA = try await Self.postRecado(app: app, bearer: membersA[0].token, text: "casa A")

            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)

            let presignResult = try await Self.postPresign(
                app: app, bearer: membersB[0].token, recadoID: recadoA.id,
                slots: [PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000)]
            )
            XCTAssertEqual(presignResult.status, .notFound, "recado de outra casa nunca é 403, sempre 404")

            let confirmResult = try await Self.postConfirm(
                app: app, bearer: membersB[0].token, recadoID: recadoA.id, objectKeys: ["qualquer-chave"]
            )
            XCTAssertEqual(confirmResult.status, .notFound)
        }
    }

    func testPresignIssuesDistinctUnderivableKeys() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "chaves distintas")

            let slots = (0..<2).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let result = try await Self.postPresign(app: app, bearer: author.token, recadoID: recado.id, slots: slots)
            let uploads = try XCTUnwrap(result.response?.uploads)

            XCTAssertEqual(Set(uploads.map(\.objectKey)).count, 2, "chaves da mesma requisição precisam ser distintas")
            for upload in uploads {
                XCTAssertTrue(
                    RecadoPhotoObjectKey.validate(upload.objectKey, householdID: household.id, recadoID: recado.id),
                    "cada chave precisa bater no esquema households/{id}/recados/{id}/{uuid}.{ext}"
                )
            }
        }
    }

    func testConfirmWritesRowsWithPositionContentTypeAndByteSize() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "confirmação")

            let presignResult = try await Self.postPresign(
                app: app, bearer: author.token, recadoID: recado.id,
                slots: [PhotoUploadSlotRequest(contentType: "image/png", byteSize: 2_048)]
            )
            let upload = try XCTUnwrap(presignResult.response?.uploads.first)
            await fake.markUploaded(key: upload.objectKey, contentType: "image/png", byteSize: 2_048)

            let confirmResult = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recado.id, objectKeys: [upload.objectKey]
            )
            XCTAssertEqual(confirmResult.status, .created)
            XCTAssertEqual(confirmResult.dtos?.first?.position, 0)

            let rows = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.objectKey, upload.objectKey)
            XCTAssertEqual(rows.first?.position, 0)
            XCTAssertEqual(rows.first?.contentType, "image/png")
            XCTAssertEqual(rows.first?.byteSize, 2_048)
        }
    }

    func testConfirmWithMissingObjectWritesNoRows() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "upload incompleto")

            let slots = (0..<2).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
            let presignResult = try await Self.postPresign(app: app, bearer: author.token, recadoID: recado.id, slots: slots)
            let uploads = try XCTUnwrap(presignResult.response?.uploads)

            // Só a primeira chave "chegou" ao bucket falso — a segunda nunca foi marcada como
            // enviada, simulando uma falha de rede no meio do upload.
            await fake.markUploaded(key: uploads[0].objectKey)

            let confirmResult = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recado.id, objectKeys: uploads.map(\.objectKey)
            )
            XCTAssertEqual(confirmResult.status, .conflict)
            XCTAssertEqual(confirmResult.error?.code, .photoNotUploaded)

            let rows = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rows.count, 0, "tudo ou nada — nem a chave que existia deve ficar gravada")
        }
    }

    func testConfirmWithKeyFromAnotherRecadoIsRejectedWithoutStorageCall() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recadoA = try await Self.postRecado(app: app, bearer: author.token, text: "recado A")
            let recadoB = try await Self.postRecado(app: app, bearer: author.token, text: "recado B")

            let presignResult = try await Self.postPresign(
                app: app, bearer: author.token, recadoID: recadoA.id,
                slots: [PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000)]
            )
            let keyFromRecadoA = try XCTUnwrap(presignResult.response?.uploads.first?.objectKey)

            // A chave é válida para o recado A, mas o confirm é chamado no recado B.
            let confirmResult = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recadoB.id, objectKeys: [keyFromRecadoA]
            )
            XCTAssertEqual(confirmResult.status, .badRequest)
            XCTAssertEqual(confirmResult.error?.code, .validation)

            let queriedKeys = await fake.metadataQueriedKeys
            XCTAssertFalse(
                queriedKeys.contains(keyFromRecadoA),
                "chave de outro recado nunca deve virar consulta ao armazenamento"
            )

            let rowsA = try await Self.photoRows(app: app, householdID: household.id, recadoID: recadoA.id)
            let rowsB = try await Self.photoRows(app: app, householdID: household.id, recadoID: recadoB.id)
            XCTAssertEqual(rowsA.count, 0)
            XCTAssertEqual(rowsB.count, 0)
        }
    }

    func testConfirmWithInventedKeyIsRejectedWithoutStorageCall() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "chave inventada")

            let confirmResult = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recado.id, objectKeys: ["chave-totalmente-inventada"]
            )
            XCTAssertEqual(confirmResult.status, .badRequest)
            XCTAssertEqual(confirmResult.error?.code, .validation)

            let queriedKeys = await fake.metadataQueriedKeys
            XCTAssertTrue(queriedKeys.isEmpty, "chave inventada nunca deve virar consulta ao armazenamento")
        }
    }

    func testConfirmRepeatedDoesNotDuplicateRow() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "confirm repetido")

            let presignResult = try await Self.postPresign(
                app: app, bearer: author.token, recadoID: recado.id,
                slots: [PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000)]
            )
            let key = try XCTUnwrap(presignResult.response?.uploads.first?.objectKey)
            await fake.markUploaded(key: key)

            let firstConfirm = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recado.id, objectKeys: [key]
            )
            XCTAssertEqual(firstConfirm.status, .created)

            let secondConfirm = try await Self.postConfirm(
                app: app, bearer: author.token, recadoID: recado.id, objectKeys: [key]
            )
            XCTAssertEqual(secondConfirm.status, .created, "confirm repetido não é erro, só não duplica")

            let rows = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rows.count, 1, "a mesma chave confirmada duas vezes gera uma única linha")
        }
    }

    func testDownloadURLsOmitsRecadoFromAnotherHousehold() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (_, membersA) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let recadoA = try await Self.postRecado(app: app, bearer: membersA[0].token, text: "casa A")
            let keysA = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: membersA[0].token, recadoID: recadoA.id, fake: fake, count: 1
            )

            let (_, membersB) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let recadoB = try await Self.postRecado(app: app, bearer: membersB[0].token, text: "casa B")
            _ = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: membersB[0].token, recadoID: recadoB.id, fake: fake, count: 1
            )

            // membro da casa A pede URLs para o próprio recado e, forjadamente, para o
            // recado da casa B — a resposta nunca é erro, o recado alheio só não aparece.
            let result = try await Self.postDownloadURLs(
                app: app, bearer: membersA[0].token, recadoIDs: [recadoA.id, recadoB.id]
            )
            XCTAssertEqual(result.status, .ok)
            let recados = try XCTUnwrap(result.response?.recados)
            XCTAssertEqual(recados.map(\.recadoID), [recadoA.id], "recado de outra casa não aparece, sem erro")
            XCTAssertEqual(recados.first?.photos.count, 1)
            _ = keysA
        }
    }

    func testDeletePhotoByAuthorRemovesRowAndCallsStorageDeletion() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 1)
            let author = members[0]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "com foto pra apagar")
            let keys = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: author.token, recadoID: recado.id, fake: fake, count: 1
            )

            let rowsBefore = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            let photoID = try await Self.photoID(app: app, householdID: household.id, recadoID: recado.id, objectKey: keys[0])

            let result = try await Self.deletePhotoRequest(
                app: app, bearer: author.token, recadoID: recado.id, photoID: photoID
            )
            XCTAssertEqual(result.status, .noContent)

            let rowsAfter = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rowsBefore.count, 1)
            XCTAssertEqual(rowsAfter.count, 0)

            let deletedKeys = await fake.deletedKeys
            XCTAssertEqual(deletedKeys, [keys[0]])
        }
    }

    func testDeletePhotoByNonAuthorIsForbidden() async throws {
        try await TestSupport.withApp { app in
            let fake = FakeObjectStorageClient()
            app.objectStorageClient = fake
            let (household, members) = try await TestSupport.makeHouseholdWithMembers(app: app, count: 2)
            let author = members[0]
            let otherMember = members[1]
            let recado = try await Self.postRecado(app: app, bearer: author.token, text: "não deixa apagar")
            let keys = try await Self.uploadAndConfirmPhotos(
                app: app, bearer: author.token, recadoID: recado.id, fake: fake, count: 1
            )
            let photoID = try await Self.photoID(app: app, householdID: household.id, recadoID: recado.id, objectKey: keys[0])

            let result = try await Self.deletePhotoRequest(
                app: app, bearer: otherMember.token, recadoID: recado.id, photoID: photoID
            )
            XCTAssertEqual(result.status, .forbidden)
            XCTAssertEqual(result.error?.code, .notAuthor)

            let rows = try await Self.photoRows(app: app, householdID: household.id, recadoID: recado.id)
            XCTAssertEqual(rows.count, 1, "foto continua lá — não-autor não conseguiu apagar")
        }
    }

    // MARK: Helpers de request (mesmo padrão de RecadoControllerTests/DeviceTokenTests)

    private static func postRecado(app: Application, bearer: String, text: String?) async throws -> RecadoDTO {
        var captured: RecadoDTO?
        try await app.testable().test(
            .POST, "/api/v1/recados",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(CreateRecadoRequest(text: text), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                XCTAssertEqual(res.status, .created)
                captured = try res.content.decode(RecadoDTO.self)
            }
        )
        return try XCTUnwrap(captured)
    }

    private static func postPresign(
        app: Application,
        bearer: String,
        recadoID: UUID,
        slots: [PhotoUploadSlotRequest]
    ) async throws -> (status: HTTPStatus, response: PresignPhotoUploadResponse?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedResponse: PresignPhotoUploadResponse?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados/\(recadoID.uuidString)/photos/presign",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(PresignPhotoUploadRequest(slots: slots), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedResponse = try res.content.decode(PresignPhotoUploadResponse.self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedResponse, capturedError)
    }

    private static func postConfirm(
        app: Application,
        bearer: String,
        recadoID: UUID,
        objectKeys: [String]
    ) async throws -> (status: HTTPStatus, dtos: [ConfirmedPhotoDTO]?, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedDTOs: [ConfirmedPhotoDTO]?
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados/\(recadoID.uuidString)/photos/confirm",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(ConfirmPhotoUploadRequest(objectKeys: objectKeys), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .created {
                    capturedDTOs = try res.content.decode([ConfirmedPhotoDTO].self)
                } else {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedDTOs, capturedError)
    }

    private static func postDownloadURLs(
        app: Application,
        bearer: String,
        recadoIDs: [UUID]
    ) async throws -> (status: HTTPStatus, response: PhotoDownloadURLsResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedResponse: PhotoDownloadURLsResponse?
        try await app.testable().test(
            .POST, "/api/v1/recados/photos/urls",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
                try req.content.encode(PhotoDownloadURLsRequest(recadoIDs: recadoIDs), as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedResponse = try res.content.decode(PhotoDownloadURLsResponse.self)
                }
            }
        )
        return (capturedStatus, capturedResponse)
    }

    private static func deletePhotoRequest(
        app: Application,
        bearer: String,
        recadoID: UUID,
        photoID: UUID
    ) async throws -> (status: HTTPStatus, error: APIErrorResponse?) {
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedError: APIErrorResponse?
        try await app.testable().test(
            .DELETE, "/api/v1/recados/\(recadoID.uuidString)/photos/\(photoID.uuidString)",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                req.headers.bearerAuthorization = BearerAuthorization(token: bearer)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status != .noContent {
                    capturedError = try? res.content.decode(APIErrorResponse.self)
                }
            }
        )
        return (capturedStatus, capturedError)
    }

    /// Presign + `markUploaded` no duplo + confirm — atalho para testes que só precisam de N
    /// fotos já confirmadas num recado, sem repetir os três passos manualmente. Devolve as
    /// chaves confirmadas, na ordem.
    @discardableResult
    private static func uploadAndConfirmPhotos(
        app: Application,
        bearer: String,
        recadoID: UUID,
        fake: FakeObjectStorageClient,
        count: Int
    ) async throws -> [String] {
        let slots = (0..<count).map { _ in PhotoUploadSlotRequest(contentType: "image/jpeg", byteSize: 1_000) }
        let presignResult = try await Self.postPresign(app: app, bearer: bearer, recadoID: recadoID, slots: slots)
        XCTAssertEqual(presignResult.status, .ok)
        let uploads = try XCTUnwrap(presignResult.response?.uploads)
        for upload in uploads {
            await fake.markUploaded(key: upload.objectKey)
        }
        let keys = uploads.map(\.objectKey)
        let confirmResult = try await Self.postConfirm(app: app, bearer: bearer, recadoID: recadoID, objectKeys: keys)
        XCTAssertEqual(confirmResult.status, .created)
        return keys
    }

    /// Leitura direta de `recado_photos` via conexão `jklar_app` com o contexto de casa
    /// aplicado — mesmo padrão de `RecadoRLSIsolationTests`, usado aqui só para inspecionar o
    /// que o controller realmente gravou (o teste não pode confiar só na resposta HTTP para
    /// provar "tudo ou nada").
    private static func photoRows(
        app: Application,
        householdID: UUID,
        recadoID: UUID
    ) async throws -> [(objectKey: String, position: Int, contentType: String, byteSize: Int64)] {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            let rows = try await sql.raw(
                """
                SELECT object_key, position, content_type, byte_size FROM recado_photos
                WHERE recado_id = \(bind: recadoID.uuidString)::uuid ORDER BY position
                """
            ).all()
            return try rows.map {
                (
                    objectKey: try $0.decode(column: "object_key", as: String.self),
                    position: try $0.decode(column: "position", as: Int.self),
                    contentType: try $0.decode(column: "content_type", as: String.self),
                    byteSize: try $0.decode(column: "byte_size", as: Int64.self)
                )
            }
        }
    }

    private static func photoID(
        app: Application,
        householdID: UUID,
        recadoID: UUID,
        objectKey: String
    ) async throws -> UUID {
        try await TestSupport.withAppRoleConnection(app: app, householdID: householdID) { sql in
            let row = try await sql.raw(
                """
                SELECT id FROM recado_photos
                WHERE recado_id = \(bind: recadoID.uuidString)::uuid AND object_key = \(bind: objectKey)
                """
            ).first()
            guard let row else {
                throw ObjectStorageNotConfiguredError()
            }
            return try row.decode(column: "id", as: UUID.self)
        }
    }
}

/// Duplo de teste de `ObjectStorageClient` — usado só por `RecadoPhotoTests` (nenhum teste
/// fala com R2/SotoS3 de verdade). Mesmo molde de `FakePushClient`
/// (`backend/Tests/AppTests/DeviceTokenTests.swift`): um `actor` com estado observável
/// (`private(set) var`) e um gatilho de falha configurável por teste.
actor FakeObjectStorageClient: ObjectStorageClient {
    private(set) var existingKeys: Set<String> = []
    private(set) var signedPutKeys: [String] = []
    private(set) var signedGetKeys: [String] = []
    private(set) var deletedKeys: [String] = []
    /// Toda chave que passou por `objectMetadata` — usado para provar que uma chave rejeitada
    /// pelo formato (T-02-27) nunca chega a virar consulta ao armazenamento.
    private(set) var metadataQueriedKeys: [String] = []
    private var metadataByKey: [String: ObjectMetadata] = [:]
    private var shouldFailNextSignature = false

    /// Simula "o objeto realmente chegou no bucket" — o que `confirm` verifica via
    /// `objectExists` antes de gravar qualquer linha (02-RESEARCH.md Pitfall 3).
    /// `contentType`/`byteSize` simulam o que um `HEAD` real devolveria, para
    /// `objectMetadata` ter algo para reler (T-02-36 — nunca aceito do corpo do request).
    func markUploaded(key: String, contentType: String = "image/jpeg", byteSize: Int64 = 12345) {
        existingKeys.insert(key)
        metadataByKey[key] = ObjectMetadata(contentType: contentType, byteSize: byteSize)
    }

    /// Simula uma falha de assinatura (rede, credencial) na próxima chamada a
    /// `presignedPutURL`/`presignedGetURL` — usado para provar que a rota não engole o erro.
    func failNextSignature() {
        shouldFailNextSignature = true
    }

    func presignedPutURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        if shouldFailNextSignature {
            shouldFailNextSignature = false
            throw ObjectStorageNotConfiguredError()
        }
        signedPutKeys.append(key)
        return URL(string: "https://fake-r2.test/\(key)?put-signature=fake")!
    }

    func presignedGetURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        if shouldFailNextSignature {
            shouldFailNextSignature = false
            throw ObjectStorageNotConfiguredError()
        }
        signedGetKeys.append(key)
        return URL(string: "https://fake-r2.test/\(key)?get-signature=fake")!
    }

    func objectExists(key: String) async throws -> Bool {
        existingKeys.contains(key)
    }

    func deleteObjects(keys: [String]) async throws {
        deletedKeys.append(contentsOf: keys)
    }

    func objectMetadata(key: String) async throws -> ObjectMetadata? {
        metadataQueriedKeys.append(key)
        return metadataByKey[key]
    }
}

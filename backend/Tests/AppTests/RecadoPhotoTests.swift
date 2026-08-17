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
    private var shouldFailNextSignature = false

    /// Simula "o objeto realmente chegou no bucket" — o que `confirm` verifica via
    /// `objectExists` antes de gravar qualquer linha (02-RESEARCH.md Pitfall 3).
    func markUploaded(key: String) {
        existingKeys.insert(key)
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
}

import Foundation
import Vapor

/// Abstração sobre o armazenamento de objeto (fotos do carrossel) — o único motivo de
/// existir é permitir que o plano 02-01 (schema + controller de recado) compile e teste sem
/// nenhuma dependência de nuvem, e que o plano 02-04 troque a implementação por trás deste
/// protocolo sem editar `RecadoController.swift`. Mesmo molde de `PushClient`
/// (`backend/Sources/App/Push/PushClient.swift`): protocolo `Sendable`, implementação real
/// (plano 02-04, SotoS3/R2), implementação nula usada só como padrão do getter.
///
/// Quem monta a chave do objeto é o `RecadoPhotoController` do plano 02-04 — o esquema de
/// nomenclatura é uma decisão com checkpoint próprio lá; este protocolo não a conhece, só
/// recebe/devolve `String` opacas.
protocol ObjectStorageClient: Sendable {
    func presignedPutURL(key: String, expiresIn: TimeInterval) async throws -> URL
    func presignedGetURL(key: String, expiresIn: TimeInterval) async throws -> URL
    func objectExists(key: String) async throws -> Bool
    func deleteObjects(keys: [String]) async throws
}

/// Erro lançado pelos dois métodos de URL de `NoopObjectStorageClient` — sinaliza "ainda não
/// configurado", nunca confundido com uma falha real de rede/credencial do plano 02-04.
struct ObjectStorageNotConfiguredError: Error {}

/// Cliente-nulo usado como valor-padrão do getter de `Application.objectStorageClient` —
/// mesmo papel de `NoopPushClient`: existir para o getter nunca precisar de um `fatalError`
/// de "esqueceram de configurar". `deleteObjects`/`objectExists` não fazem nada/devolvem
/// `false` (chamar com uma lista vazia, como o `destroy` de um recado sem fotos faz nesta
/// fase, é sempre seguro); os dois métodos de URL lançam, porque mintar uma URL sem
/// armazenamento real configurado não tem resposta segura nenhuma.
struct NoopObjectStorageClient: ObjectStorageClient {
    func presignedPutURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        throw ObjectStorageNotConfiguredError()
    }

    func presignedGetURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        throw ObjectStorageNotConfiguredError()
    }

    func objectExists(key: String) async throws -> Bool {
        false
    }

    func deleteObjects(keys: [String]) async throws {}
}

private struct ObjectStorageClientStorageKey: StorageKey {
    typealias Value = any ObjectStorageClient
}

extension Application {
    var objectStorageClient: any ObjectStorageClient {
        get { self.storage[ObjectStorageClientStorageKey.self] ?? NoopObjectStorageClient() }
        set { self.storage[ObjectStorageClientStorageKey.self] = newValue }
    }
}

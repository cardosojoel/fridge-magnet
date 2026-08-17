import Foundation
import SotoS3
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

/// Implementação real de `ObjectStorageClient` sobre `SotoS3` (Cloudflare R2, API S3
/// compatível) — plano 02-04, Task 3. Assinatura de requisição sempre pela biblioteca
/// (`AWSService.signURL`, sobre `SotoSignerV4`) — nenhum HMAC/canonicalização próprios,
/// verificado contra o código-fonte do pacote já resolvido nesta sessão (Passo 0 do plano,
/// fecha a Open Question 1 de `02-RESEARCH.md`; ver `02-04-SUMMARY.md` para a fonte exata).
///
/// **Nunca registrar a URL assinada completa em log**: ela embute a assinatura SigV4, que é
/// uma credencial de acesso temporária ao objeto — equivalente a um token de terceiro. Onde
/// for útil registrar alguma coisa sobre uma operação de armazenamento, registrar só a chave
/// do objeto (`String` opaca), nunca a `URL` assinada devolvida por `presignedPutURL`/
/// `presignedGetURL` — mesma disciplina que `.claude/CLAUDE.md` exige para dado financeiro e
/// para token de terceiro (Open Finance, Google, Microsoft).
struct SotoS3ObjectStorageClient: ObjectStorageClient {
    private let s3: S3
    private let bucketName: String

    /// `awsClient` é dono do pool de conexão HTTP e do ciclo de vida do credential provider —
    /// quem constrói este tipo (`configure.swift`) também é responsável por desligá-lo no
    /// shutdown da `Application` (ver `ObjectStorageLifecycleHandler` abaixo).
    init(config: R2Config, awsClient: AWSClient) {
        self.bucketName = config.bucketName
        // R2 não usa região da AWS — "auto" é o valor que a Cloudflare documenta para o
        // endpoint S3-compatível do R2; `endpoint` (não a região) é o que direciona a
        // requisição para o host correto do R2, não para a AWS.
        self.s3 = S3(client: awsClient, region: Region(rawValue: "auto"), endpoint: config.endpoint)
    }

    // MARK: ObjectStorageClient

    func presignedPutURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        let url = try objectURL(key: key)
        return try await s3.signURL(url: url, httpMethod: .PUT, expires: .seconds(Int64(expiresIn)))
    }

    func presignedGetURL(key: String, expiresIn: TimeInterval) async throws -> URL {
        let url = try objectURL(key: key)
        return try await s3.signURL(url: url, httpMethod: .GET, expires: .seconds(Int64(expiresIn)))
    }

    /// `HEAD` contra o objeto — a verificação de chegada que `RecadoPhotoController.confirm`
    /// exige antes de gravar qualquer linha (02-RESEARCH.md Pitfall 3). Devolve `false` só no
    /// caso reconhecido de "objeto não encontrado"; qualquer outro erro (rede, credencial,
    /// bucket errado) propaga — um `false` por engano aqui esconderia um problema real de
    /// configuração atrás de um 409 `photoNotUploaded` enganoso.
    func objectExists(key: String) async throws -> Bool {
        do {
            _ = try await s3.headObject(bucket: bucketName, key: key)
            return true
        } catch let error as S3ErrorType
        where error.errorCode == S3ErrorType.notFound.errorCode || error.errorCode == S3ErrorType.noSuchKey.errorCode {
            return false
        } catch let error as AWSRawError where error.context.responseCode == .notFound {
            // `HEAD` não devolve corpo XML (mesmo em erro) — quando a S3 não consegue extrair
            // um código de erro reconhecido do corpo (vazio, no caso de HEAD), Soto devolve
            // `AWSRawError` crua; o status HTTP 404 continua confiável mesmo sem código XML.
            return false
        }
    }

    /// Remoção em lote — lista vazia devolve sem chamada de rede (o `destroy` de um recado sem
    /// fotos, plano 02-01, já depende deste comportamento contra o `NoopObjectStorageClient`).
    func deleteObjects(keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let objects = keys.map { S3.ObjectIdentifier(key: $0) }
        _ = try await s3.deleteObjects(bucket: bucketName, delete: S3.Delete(objects: objects))
    }

    // MARK: Chave → URL do objeto

    /// Path-style (bucket no path, não em subdomínio): o host do R2
    /// (`<accountID>.r2.cloudflarestorage.com`) não é um domínio próprio do bucket, então o
    /// nome do bucket entra na URL — mesmo formato documentado pela Cloudflare para o
    /// endpoint S3 do R2.
    private func objectURL(key: String) throws -> URL {
        guard let url = URL(string: "\(s3.endpoint)/\(bucketName)/\(key)") else {
            throw ObjectStorageNotConfiguredError()
        }
        return url
    }
}

/// Desliga o `AWSClient` (pool HTTP + credential provider do R2) no shutdown da
/// `Application` — o mesmo tipo de disciplina de ciclo de vida que `app.apns`/`app.db`
/// recebem, para o processo não vazar tarefas em segundo plano ao encerrar.
struct ObjectStorageLifecycleHandler: LifecycleHandler {
    let awsClient: AWSClient

    func shutdownAsync(_ application: Application) async {
        try? await awsClient.shutdown()
    }
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

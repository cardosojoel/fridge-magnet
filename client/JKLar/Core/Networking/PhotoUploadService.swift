import Foundation

/// Transporte de upload de bytes de foto direto para o armazenamento — protocolo **próprio**,
/// nunca `APIClientTransport`, de propósito: `APIClient` anexa o Bearer token de sessão do JK
/// Lar em toda chamada autenticada, e este envio nunca deve herdar esse interceptador (ver doc
/// de `PhotoUploadService` abaixo).
protocol PhotoUploadTransport: Sendable {
    func upload(_ request: URLRequest, from data: Data) async throws -> HTTPURLResponse
}

struct URLSessionPhotoUploadTransport: PhotoUploadTransport {
    func upload(_ request: URLRequest, from data: Data) async throws -> HTTPURLResponse {
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else {
            throw PhotoUploadError.invalidResponse
        }
        return http
    }
}

/// Erro tipado de `PhotoUploadService` — carrega só o código de status HTTP, nunca a URL: a
/// URL assinada embute a própria assinatura (é credencial temporária, T-02-43 do plano 02-06),
/// então não pode aparecer em nenhum erro, log ou qualquer lugar que possa persistir.
enum PhotoUploadError: Error, Equatable {
    case invalidResponse
    case unexpectedStatus(Int)
}

/// Envia bytes de foto diretamente para a URL assinada de um recado — serviço **separado** de
/// `APIClient`, nunca uma rota a mais nele.
///
/// Por quê: a URL assinada aponta para um host de armazenamento (Cloudflare R2, plano 02-04)
/// que está fora do perímetro do backend do JK Lar. `APIClient.send(path:...:requiresAuth:
/// true)` anexa o Bearer token de sessão em toda chamada autenticada — mandar esse token para
/// um host externo entregaria a sessão da pessoa a um terceiro (T-02-42). Este serviço usa um
/// transporte próprio (`PhotoUploadTransport`), nunca herda o cabeçalho de sessão do
/// `APIClient`, nunca grava a URL assinada em disco ou em log, e não implementa retentativa
/// própria: decidir se e quando repetir uma foto é responsabilidade do view-model, por
/// miniatura (`ComposeRecadoViewModel.retryUpload(photoID:)`).
struct PhotoUploadService: Sendable {
    private let transport: PhotoUploadTransport

    init(transport: PhotoUploadTransport = URLSessionPhotoUploadTransport()) {
        self.transport = transport
    }

    /// Monta um `PUT` para `url` com `Content-Type: contentType` e **sem** o cabeçalho de
    /// sessão do `APIClient`. Uma resposta fora de 2xx lança `PhotoUploadError.unexpectedStatus`
    /// sem nenhuma tentativa própria de repetir.
    func upload(data: Data, to url: URL, contentType: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let response = try await transport.upload(request, from: data)
        guard (200..<300).contains(response.statusCode) else {
            throw PhotoUploadError.unexpectedStatus(response.statusCode)
        }
    }
}

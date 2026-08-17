import XCTest
@testable import JKLar

/// Transporte falso — captura o `URLRequest` recebido, para provar o formato exato do envio
/// (PUT + Content-Type, sem Authorization) sem tocar nenhum host de armazenamento real.
private actor PhotoUploadStubTransport: PhotoUploadTransport {
    private let statusCode: Int
    private(set) var capturedRequest: URLRequest?
    private(set) var capturedData: Data?
    private(set) var callCount = 0

    init(statusCode: Int = 200) {
        self.statusCode = statusCode
    }

    func upload(_ request: URLRequest, from data: Data) async throws -> HTTPURLResponse {
        callCount += 1
        capturedRequest = request
        capturedData = data
        return HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

final class PhotoUploadServiceTests: XCTestCase {
    func testUploadSendsPUTWithContentTypeAndNoAuthorizationHeader() async throws {
        let transport = PhotoUploadStubTransport(statusCode: 200)
        let service = PhotoUploadService(transport: transport)
        let url = URL(string: "https://storage.example.com/upload?sig=abc123")!
        let payload = Data("bytes-da-foto".utf8)

        try await service.upload(data: payload, to: url, contentType: "image/jpeg")

        let request = await transport.capturedRequest
        XCTAssertEqual(request?.httpMethod, "PUT")
        XCTAssertEqual(request?.url, url)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertNil(
            request?.value(forHTTPHeaderField: "Authorization"),
            "nunca anexa o token de sessão do JK Lar ao host de armazenamento (T-02-42)"
        )
        let capturedData = await transport.capturedData
        XCTAssertEqual(capturedData, payload)
    }

    func testUploadWithNon2xxStatusThrowsWithoutRetrying() async throws {
        let transport = PhotoUploadStubTransport(statusCode: 500)
        let service = PhotoUploadService(transport: transport)
        let url = URL(string: "https://storage.example.com/upload?sig=abc123")!

        do {
            try await service.upload(data: Data("bytes".utf8), to: url, contentType: "image/jpeg")
            XCTFail("esperava PhotoUploadError.unexpectedStatus")
        } catch let error as PhotoUploadError {
            XCTAssertEqual(error, .unexpectedStatus(500))
        }

        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1, "sem retentativa própria — a decisão de repetir é do view-model, por miniatura")
    }
}

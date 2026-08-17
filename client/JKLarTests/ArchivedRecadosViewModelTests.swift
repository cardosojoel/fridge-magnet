import XCTest
import JKLarShared
@testable import JKLar

/// Transporte falso que roteia `GET .../archived`, `DELETE .../archive` e
/// `POST .../photos/urls` — dono deste arquivo, sem estado compartilhado com stubs de
/// outros arquivos de teste (mesma disciplina de `MuralFeedStubTransport`/
/// `HouseholdStubTransport`). Todo fixture de RESPOSTA do servidor passa por
/// `ServerWire.encoder` — nunca por um codificador cru (foi exatamente esse furo que
/// derrubou o feed no primeiro login real).
private actor ArchivedStubTransport: APIClientTransport {
    enum ListOutcome {
        case success([RecadoDTO])
        case failure(status: Int)
    }

    enum UnarchiveOutcome {
        case success(RecadoDTO)
        case failure(status: Int)
    }

    enum PhotoURLsOutcome {
        case success(PhotoDownloadURLsResponse)
        case failure(status: Int)
    }

    private var listOutcome: ListOutcome
    /// Padrão de falha 500: um teste que não programa a rota e mesmo assim a chama deve
    /// falhar alto, não passar por acidente.
    private var unarchiveOutcome: UnarchiveOutcome = .failure(status: 500)
    private var photoURLsOutcome: PhotoURLsOutcome = .success(PhotoDownloadURLsResponse(recados: []))
    private(set) var listCallCount = 0
    private(set) var unarchiveCallCount = 0
    private(set) var photoURLsCallCount = 0
    /// Um elemento por chamada a `photos/urls`, na ordem em que ocorreram — os `recadoIDs`
    /// que o corpo daquela chamada pediu.
    private(set) var photoURLsRequestedIDs: [[UUID]] = []

    init(list: ListOutcome) {
        self.listOutcome = list
    }

    func setListOutcome(_ outcome: ListOutcome) {
        listOutcome = outcome
    }

    func setUnarchiveOutcome(_ outcome: UnarchiveOutcome) {
        unarchiveOutcome = outcome
    }

    func setPhotoURLsOutcome(_ outcome: PhotoURLsOutcome) {
        photoURLsOutcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/photos/urls") {
            photoURLsCallCount += 1
            if let body = request.httpBody, let decoded = try? JSONDecoder().decode(PhotoDownloadURLsRequest.self, from: body) {
                photoURLsRequestedIDs.append(decoded.recadoIDs)
            }
            switch photoURLsOutcome {
            case .success(let response):
                let data = try ServerWire.encoder.encode(response)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .failure(let status):
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        if url.path.hasSuffix("/archived") {
            listCallCount += 1
            switch listOutcome {
            case .success(let items):
                let data = try ServerWire.encoder.encode(items)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .failure(let status):
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        if url.path.hasSuffix("/archive"), request.httpMethod == "DELETE" {
            unarchiveCallCount += 1
            switch unarchiveOutcome {
            case .success(let dto):
                let data = try ServerWire.encoder.encode(dto)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .failure(let status):
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        fatalError("rota não esperada no teste: \(request.httpMethod ?? "") \(url.path)")
    }
}

/// Transporte que responde a listagem na hora, mas bloqueia `DELETE .../archive` até
/// `release()` — usado só pelo caso de desarquivamentos concorrentes no mesmo cartão, para
/// a guarda de "já em voo" por recado ter chance determinística de rejeitar a segunda
/// chamada enquanto a primeira ainda está suspensa na rede.
private actor ArchivedUnarchiveGatedTransport: APIClientTransport {
    private let list: [RecadoDTO]
    private let unarchiveResponse: RecadoDTO
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var unarchiveCallCount = 0
    private(set) var isWaiting = false

    init(list: [RecadoDTO], unarchiveResponse: RecadoDTO) {
        self.list = list
        self.unarchiveResponse = unarchiveResponse
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/archived") {
            let data = try ServerWire.encoder.encode(list)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        unarchiveCallCount += 1
        isWaiting = true
        await waitUntilReleased()
        let data = try ServerWire.encoder.encode(unarchiveResponse)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

/// Um caso por linha do `<behavior>` da Task 3 do plano 02-12 — cobertura de view-model,
/// sem SwiftUI (a tela `ArchivedRecadosView` é verificada no checkpoint humano).
@MainActor
final class ArchivedRecadosViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeArchivedRecado(
        id: UUID = UUID(), sequence: Int64, text: String = "Arquivado", photos: [RecadoPhotoRefDTO] = []
    ) -> RecadoDTO {
        RecadoDTO(
            id: id,
            authorID: UUID(),
            authorDisplayName: "Alguém",
            isMine: false,
            text: text,
            sequence: sequence,
            createdAt: Date(),
            updatedAt: Date(),
            photos: photos,
            mentions: [],
            reactions: [],
            myReaction: nil,
            commentCount: 0,
            latestComments: [],
            archivedAt: Date(),
            canUnarchive: true
        )
    }

    // MARK: load()

    func testLoadWithThreeArchivedLeadsToLoadedInServerOrder() async {
        let items = [makeArchivedRecado(sequence: 3), makeArchivedRecado(sequence: 2), makeArchivedRecado(sequence: 1)]
        let transport = ArchivedStubTransport(list: .success(items))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), items.map(\.id), "a ordem é a que o servidor devolveu — o cliente nunca reordena")
    }

    func testLoadWithNoArchivedLeadsToLoadedEmptyNotError() async {
        let transport = ArchivedStubTransport(list: .success([]))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("lista vazia é o estado vazio, nunca erro")
        }
        XCTAssertTrue(loadedItems.isEmpty)
    }

    func testLoadFailureLeadsToErrorWithScreenCopyPreservingLastGood() async {
        let items = [makeArchivedRecado(sequence: 1)]
        let transport = ArchivedStubTransport(list: .success(items))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await transport.setListOutcome(.failure(status: 500))
        await sut.load()

        guard case .error(let message, let lastGood) = sut.state else {
            return XCTFail("esperava .error")
        }
        XCTAssertEqual(message, JKCopy.muralArchivedLoadError, "a cópia de carga é a própria da tela")
        XCTAssertEqual(lastGood?.map(\.id), items.map(\.id), "a última lista boa é preservada")
    }

    // MARK: unarchive(recadoID:)

    func testUnarchiveSuccessRemovesThatCardWithoutTouchingOthers() async {
        let target = makeArchivedRecado(sequence: 3)
        let other = makeArchivedRecado(sequence: 2)
        let transport = ArchivedStubTransport(list: .success([target, other]))
        var unarchived = target
        unarchived.archivedAt = nil
        await transport.setUnarchiveOutcome(.success(unarchived))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await sut.unarchive(recadoID: target.id)

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), [other.id], "só o cartão desarquivado sai; os demais ficam intocados")
        XCTAssertNil(sut.actionErrorMessage)
        let listCallCount = await transport.listCallCount
        XCTAssertEqual(listCallCount, 1, "sem recarga no sucesso — a remoção local já é o resultado correto")
    }

    func testUnarchiveFailureRemovesNothingAndSetsSharedErrorPointingAtCard() async {
        let target = makeArchivedRecado(sequence: 3)
        let other = makeArchivedRecado(sequence: 2)
        let transport = ArchivedStubTransport(list: .success([target, other]))
        await transport.setUnarchiveOutcome(.failure(status: 500))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await sut.unarchive(recadoID: target.id)

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), [target.id, other.id], "falha não remove nada")
        XCTAssertEqual(sut.actionErrorMessage, JKCopy.muralMenuActionErrorMessage, "mensagem compartilhada de erro de ação")
        XCTAssertEqual(sut.actionErrorRecadoID, target.id, "apontando o cartão afetado")
    }

    func testConcurrentUnarchiveCallsOnSameCardTriggerExactlyOneNetworkCall() async {
        let target = makeArchivedRecado(sequence: 1)
        var unarchived = target
        unarchived.archivedAt = nil
        let gated = ArchivedUnarchiveGatedTransport(list: [target], unarchiveResponse: unarchived)
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: gated, baseURL: url()))
        await sut.load()

        let task1 = Task { await sut.unarchive(recadoID: target.id) }
        // Espera deterministicamente até a primeira chamada suspender dentro do transporte
        // bloqueante — só então a guarda de "já em voo" teve chance de rejeitar a segunda.
        var attempts = 0
        while await !gated.isWaiting, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        guard await gated.isWaiting else {
            await gated.release()
            await task1.value
            return XCTFail("transporte nunca suspendeu — unarchive não chamou a rede como esperado")
        }
        let task2 = Task { await sut.unarchive(recadoID: target.id) }
        await task2.value
        await gated.release()
        await task1.value

        let callCount = await gated.unarchiveCallCount
        XCTAssertEqual(callCount, 1, "desarquivar concorrente no mesmo cartão dispara exatamente uma chamada de rede")
    }

    // MARK: photoURLs(for:)

    func testPhotoURLsResolvedInSingleBatchForArchivedWithPhotos() async {
        let withPhoto1 = makeArchivedRecado(sequence: 3, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let withoutPhoto = makeArchivedRecado(sequence: 2)
        let withPhoto2 = makeArchivedRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let transport = ArchivedStubTransport(list: .success([withPhoto1, withoutPhoto, withPhoto2]))
        let download = PhotoDownloadDTO(
            id: withPhoto1.photos[0].id, position: 0,
            downloadURL: URL(string: "https://storage.example.com/a.jpg")!,
            expiresAt: Date().addingTimeInterval(3600)
        )
        await transport.setPhotoURLsOutcome(
            .success(PhotoDownloadURLsResponse(recados: [RecadoPhotoURLsDTO(recadoID: withPhoto1.id, photos: [download])]))
        )
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        let photoURLsCallCount = await transport.photoURLsCallCount
        XCTAssertEqual(photoURLsCallCount, 1, "uma única busca em lote, não uma por recado")
        let requestedIDs = await transport.photoURLsRequestedIDs.last
        XCTAssertEqual(Set(requestedIDs ?? []), Set([withPhoto1.id, withPhoto2.id]), "só os recados que têm foto")
        XCTAssertEqual(sut.photoURLs(for: withPhoto1.id).map(\.id), [download.id])
    }

    func testPhotoURLsBatchFailureNeverPutsScreenInError() async {
        let withPhoto = makeArchivedRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let transport = ArchivedStubTransport(list: .success([withPhoto]))
        await transport.setPhotoURLsOutcome(.failure(status: 500))
        let sut = ArchivedRecadosViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("uma imagem faltando não é motivo para esvaziar a tela")
        }
        XCTAssertEqual(loadedItems.map(\.id), [withPhoto.id])
        XCTAssertTrue(sut.photoURLs(for: withPhoto.id).isEmpty, "só o carrossel daquele cartão fica sem imagem")
    }
}

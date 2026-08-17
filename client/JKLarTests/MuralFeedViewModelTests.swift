import XCTest
import JKLarShared
@testable import JKLar

/// Transporte falso que roteia `GET api/v1/recados` (com/sem `?cursor=`) — dono deste
/// arquivo, sem estado compartilhado com stubs de outros arquivos de teste (mesmo padrão de
/// `HouseholdStubTransport`/`OnboardingStubTransport`). `actor` porque alguns testes trocam
/// a página programada entre chamadas (`setPage(forCursor:)`), e `MuralFeedViewModel` chama
/// `feed(cursor:)` de dentro de um contexto MainActor concorrente com o teste.
private actor MuralFeedStubTransport: APIClientTransport {
    enum Outcome {
        case page(RecadoFeedPage)
        case failure(status: Int)
    }

    /// Resposta simulada de `POST api/v1/recados/photos/urls` (plano 02-06 Task 3).
    enum PhotoURLsOutcome {
        case success(PhotoDownloadURLsResponse)
        case failure(status: Int)
    }

    /// Página devolvida quando `cursor` é `nil` (primeira carga/`reloadFromTop`).
    private var firstPageOutcome: Outcome
    /// Páginas devolvidas por cursor explícito (`loadNextPage`), chave = valor do cursor.
    private var cursoredOutcomes: [Int64: Outcome]
    private var photoURLsOutcome: PhotoURLsOutcome = .success(PhotoDownloadURLsResponse(recados: []))
    private(set) var callCount = 0
    private(set) var photoURLsCallCount = 0
    /// Um elemento por chamada a `photos/urls`, na ordem em que ocorreram — os
    /// `recadoIDs` que o corpo daquela chamada pediu.
    private(set) var photoURLsRequestedIDs: [[UUID]] = []

    init(firstPage: Outcome, cursoredPages: [Int64: Outcome] = [:]) {
        self.firstPageOutcome = firstPage
        self.cursoredOutcomes = cursoredPages
    }

    func setFirstPage(_ outcome: Outcome) {
        firstPageOutcome = outcome
    }

    func setPage(_ outcome: Outcome, forCursor cursor: Int64) {
        cursoredOutcomes[cursor] = outcome
    }

    func setPhotoURLsOutcome(_ outcome: PhotoURLsOutcome) {
        photoURLsOutcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/photos/urls") {
            return try encodePhotoURLs(request: request, url: url)
        }

        callCount += 1
        let cursor = Self.cursor(from: url)
        let outcome = cursor.flatMap { cursoredOutcomes[$0] } ?? firstPageOutcome
        return try Self.encode(outcome, url: url)
    }

    private func encodePhotoURLs(request: URLRequest, url: URL) throws -> (Data, HTTPURLResponse) {
        photoURLsCallCount += 1
        if let body = request.httpBody, let decoded = try? JSONDecoder().decode(PhotoDownloadURLsRequest.self, from: body) {
            photoURLsRequestedIDs.append(decoded.recadoIDs)
        }
        switch photoURLsOutcome {
        case .success(let response):
            let data = try JSONEncoder().encode(response)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func cursor(from url: URL) -> Int64? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "cursor" }).flatMap { Int64($0.value ?? "") }
    }

    private static func encode(_ outcome: Outcome, url: URL) throws -> (Data, HTTPURLResponse) {
        switch outcome {
        case .page(let page):
            let data = try JSONEncoder().encode(page)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Transporte que bloqueia dentro de `send(_:)` até `release()` ser chamado — mesmo molde de
/// `GatedTransport` em `OnboardingViewModelTests.swift`, usado só para o caso de
/// `loadNextPage()` concorrente.
private actor MuralFeedGatedTransport: APIClientTransport {
    private let page: RecadoFeedPage
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var callCount = 0

    init(page: RecadoFeedPage) {
        self.page = page
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        await waitUntilReleased()
        let data = try JSONEncoder().encode(page)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

/// Transporte que só bloqueia requests com `?cursor=` (a chamada de `loadNextPage()`) — a
/// primeira página (`load()`, sem `cursor`) responde imediatamente, para o teste de
/// concorrência poder popular `nextCursor` antes de exercitar a guarda de "já em voo".
private actor MuralFeedConcurrencyGateTransport: APIClientTransport {
    private let firstPage: RecadoFeedPage
    private let nextPage: RecadoFeedPage
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var nextPageCallCount = 0
    private(set) var isWaiting = false

    init(firstPage: RecadoFeedPage, nextPage: RecadoFeedPage) {
        self.firstPage = firstPage
        self.nextPage = nextPage
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let hasCursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "cursor" }) ?? false
        guard hasCursor else {
            let data = try JSONEncoder().encode(firstPage)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        nextPageCallCount += 1
        await waitUntilReleased()
        let data = try JSONEncoder().encode(nextPage)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func waitUntilReleased() async {
        if released { return }
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
final class MuralFeedViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeRecado(
        id: UUID = UUID(), sequence: Int64, text: String = "Oi", photos: [RecadoPhotoRefDTO] = []
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
            latestComments: []
        )
    }

    // MARK: load()

    func testLoadWithThreeItemsLeadsToLoadedInServerOrder() async {
        let items = [makeRecado(sequence: 3), makeRecado(sequence: 2), makeRecado(sequence: 1)]
        let page = RecadoFeedPage(items: items, nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), items.map(\.id), "o cliente não reordena")
    }

    func testLoadWithEmptyPageAndNilCursorIsEmptyStateNotError() async {
        let page = RecadoFeedPage(items: [], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("página vazia é o estado vazio, não erro")
        }
        XCTAssertTrue(loadedItems.isEmpty)
    }

    func testLoadFailurePreservesLastGoodList() async {
        let items = [makeRecado(sequence: 1)]
        let page = RecadoFeedPage(items: items, nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await transport.setFirstPage(.failure(status: 500))
        await sut.load()

        guard case .error(let message, let lastGood) = sut.state else {
            return XCTFail("esperava .error")
        }
        XCTAssertEqual(message, JKCopy.muralFeedLoadError)
        XCTAssertEqual(lastGood?.map(\.id), items.map(\.id))
    }

    // MARK: loadNextPage()

    func testLoadNextPageAppendsWithoutRemovingOrDuplicating() async {
        let firstItems = [makeRecado(sequence: 2), makeRecado(sequence: 1)]
        let firstPage = RecadoFeedPage(items: firstItems, nextCursor: 1)
        let secondItems = [makeRecado(sequence: 0)]
        let secondPage = RecadoFeedPage(items: secondItems, nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(firstPage), cursoredPages: [1: .page(secondPage)])
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await sut.loadNextPage()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), (firstItems + secondItems).map(\.id))
        XCTAssertEqual(Set(loadedItems.map(\.id)).count, loadedItems.count, "nenhum id duplicado")
    }

    func testLoadNextPageWithNilCursorMakesNoNetworkCall() async {
        let page = RecadoFeedPage(items: [makeRecado(sequence: 1)], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        let callCountAfterLoad = await transport.callCount

        await sut.loadNextPage()

        let callCountAfterAttempt = await transport.callCount
        XCTAssertEqual(callCountAfterAttempt, callCountAfterLoad, "sem nextCursor, nenhuma chamada de rede")
    }

    func testConcurrentLoadNextPageCallsTriggerExactlyOneNetworkCall() async {
        let firstPage = RecadoFeedPage(items: [makeRecado(sequence: 2)], nextCursor: 1)
        let nextPage = RecadoFeedPage(items: [makeRecado(sequence: 1)], nextCursor: nil)
        let transport = MuralFeedConcurrencyGateTransport(firstPage: firstPage, nextPage: nextPage)
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        let task1 = Task { await sut.loadNextPage() }
        let task2 = Task { await sut.loadNextPage() }

        // Espera deterministicamente até a primeira chamada de `loadNextPage()` suspender
        // dentro do transporte bloqueante — só então a guarda de "já em voo" teve chance de
        // rejeitar a segunda chamada concorrente. Limite de iterações (em vez de um `while
        // true`) para o teste falhar rápido em vez de travar a suíte se a suposição de
        // "vai suspender" deixar de valer.
        var attempts = 0
        while await !transport.isWaiting, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        guard await transport.isWaiting else {
            await transport.release()
            _ = await (task1.value, task2.value)
            return XCTFail("transporte nunca suspendeu — loadNextPage() não chamou a rede como esperado")
        }
        await Task.yield()
        await transport.release()
        await task1.value
        await task2.value

        let callCount = await transport.nextPageCallCount
        XCTAssertEqual(callCount, 1, "loadNextPage() concorrente dispara exatamente uma chamada de rede")
    }

    func testLoadNextPageFailurePutsPageStateFailedAndKeepsLoadedItems() async {
        let firstItems = [makeRecado(sequence: 2)]
        let firstPage = RecadoFeedPage(items: firstItems, nextCursor: 1)
        let transport = MuralFeedStubTransport(firstPage: .page(firstPage), cursoredPages: [1: .failure(status: 500)])
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await sut.loadNextPage()

        guard case .failed(let message) = sut.pageState else {
            return XCTFail("esperava .failed")
        }
        XCTAssertEqual(message, JKCopy.muralFeedLoadMoreError)
        XCTAssertEqual(sut.items.map(\.id), firstItems.map(\.id), "itens já carregados continuam em items")
    }

    func testRetryNextPageRefetchesSameCursorAfterFailure() async {
        let firstItems = [makeRecado(sequence: 2)]
        let firstPage = RecadoFeedPage(items: firstItems, nextCursor: 1)
        let secondItems = [makeRecado(sequence: 1)]
        let secondPage = RecadoFeedPage(items: secondItems, nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(firstPage), cursoredPages: [1: .failure(status: 500)])
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        await sut.loadNextPage()
        guard case .failed = sut.pageState else {
            return XCTFail("pré-condição: esperava falha antes da retentativa")
        }

        await transport.setPage(.page(secondPage), forCursor: 1)
        await sut.retryNextPage()

        XCTAssertEqual(sut.pageState, .exhausted)
        XCTAssertEqual(sut.items.map(\.id), (firstItems + secondItems).map(\.id))
    }

    // MARK: reloadFromTop()

    func testReloadFromTopDiscardsCursorAndReplacesListFromFirstPage() async {
        let firstItems = [makeRecado(sequence: 2)]
        let firstPage = RecadoFeedPage(items: firstItems, nextCursor: 1)
        let transport = MuralFeedStubTransport(firstPage: .page(firstPage))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        let refreshedItems = [makeRecado(sequence: 5)]
        await transport.setFirstPage(.page(RecadoFeedPage(items: refreshedItems, nextCursor: nil)))
        await sut.reloadFromTop()

        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.map(\.id), refreshedItems.map(\.id), "substitui a lista, não soma")
    }

    // MARK: insertLocally(_:)

    func testInsertLocallyPutsNewRecadoFirstWithoutNetworkCall() async {
        let firstItems = [makeRecado(sequence: 2)]
        let firstPage = RecadoFeedPage(items: firstItems, nextCursor: nil)
        let gated = MuralFeedGatedTransport(page: firstPage)
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: gated, baseURL: url()))
        await gated.release()
        await sut.load()
        let callCountBeforeInsert = await gated.callCount

        let newRecado = makeRecado(sequence: 3, text: "Recém publicado")
        sut.insertLocally(newRecado)

        let callCountAfterInsert = await gated.callCount
        XCTAssertEqual(callCountAfterInsert, callCountBeforeInsert, "insertLocally nunca chama a rede")
        guard case .loaded(let loadedItems) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loadedItems.first?.id, newRecado.id)
    }

    // MARK: photoURLs(for:) / busca em lote (plano 02-06 Task 3)

    private func makeDownload(id: UUID, url downloadURL: URL = URL(string: "https://storage.example.com/a.jpg")!) -> PhotoDownloadDTO {
        PhotoDownloadDTO(id: id, position: 0, downloadURL: downloadURL, expiresAt: Date().addingTimeInterval(3600))
    }

    func testLoadWithTwoOfThreeRecadosHavingPhotosTriggersExactlyOnePhotoURLsCallWithTheirIDs() async {
        let photoID1 = UUID()
        let photoID2 = UUID()
        let withPhoto1 = makeRecado(sequence: 3, photos: [RecadoPhotoRefDTO(id: photoID1, position: 0)])
        let withoutPhoto = makeRecado(sequence: 2)
        let withPhoto2 = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: photoID2, position: 0)])
        let page = RecadoFeedPage(items: [withPhoto1, withoutPhoto, withPhoto2], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        let photoURLsCallCount = await transport.photoURLsCallCount
        XCTAssertEqual(photoURLsCallCount, 1, "uma chamada em lote, não uma por recado")
        let requestedIDs = await transport.photoURLsRequestedIDs.last
        XCTAssertEqual(Set(requestedIDs ?? []), Set([withPhoto1.id, withPhoto2.id]))
    }

    func testLoadWithNoRecadoHavingPhotosTriggersNoPhotoURLsCall() async {
        let page = RecadoFeedPage(items: [makeRecado(sequence: 1), makeRecado(sequence: 2)], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        let photoURLsCallCount = await transport.photoURLsCallCount
        XCTAssertEqual(photoURLsCallCount, 0, "nenhum recado com foto, nenhuma chamada de URLs")
    }

    func testPhotoURLsExposedByPhotoURLsForAfterLoad() async {
        let photoID = UUID()
        let recado = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: photoID, position: 0)])
        let page = RecadoFeedPage(items: [recado], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let download = makeDownload(id: photoID)
        await transport.setPhotoURLsOutcome(
            .success(PhotoDownloadURLsResponse(recados: [RecadoPhotoURLsDTO(recadoID: recado.id, photos: [download])]))
        )
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        XCTAssertEqual(sut.photoURLs(for: recado.id).map(\.id), [photoID])
    }

    func testLoadNextPageOnlyFetchesURLsForNewPageRecadosNotAlreadyLoadedOnes() async {
        let firstItem = makeRecado(sequence: 2, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let firstPage = RecadoFeedPage(items: [firstItem], nextCursor: 1)
        let secondItem = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let secondPage = RecadoFeedPage(items: [secondItem], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(firstPage), cursoredPages: [1: .page(secondPage)])
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        let requestsAfterFirstLoad = await transport.photoURLsRequestedIDs.count

        await sut.loadNextPage()

        let requestsAfterNextPage = await transport.photoURLsRequestedIDs
        XCTAssertEqual(requestsAfterNextPage.count, requestsAfterFirstLoad + 1)
        XCTAssertEqual(requestsAfterNextPage.last, [secondItem.id], "só busca URLs dos recados da página nova")
    }

    func testReloadFromTopDiscardsPhotoURLsMapAndRefetches() async {
        let photoID = UUID()
        let recado = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: photoID, position: 0)])
        let page = RecadoFeedPage(items: [recado], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let download = makeDownload(id: photoID)
        await transport.setPhotoURLsOutcome(
            .success(PhotoDownloadURLsResponse(recados: [RecadoPhotoURLsDTO(recadoID: recado.id, photos: [download])]))
        )
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        XCTAssertFalse(sut.photoURLs(for: recado.id).isEmpty)

        await sut.reloadFromTop()

        let photoURLsCallCount = await transport.photoURLsCallCount
        XCTAssertEqual(photoURLsCallCount, 2, "busca de novo depois do refresh — URL assinada tem validade curta")
        XCTAssertFalse(sut.photoURLs(for: recado.id).isEmpty, "mapa repopulado depois do refetch")
    }

    func testPhotoURLsFetchFailureDoesNotPutFeedInErrorState() async {
        let recado = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: UUID(), position: 0)])
        let page = RecadoFeedPage(items: [recado], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        await transport.setPhotoURLsOutcome(.failure(status: 500))
        let sut = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let items) = sut.state else {
            return XCTFail("uma falha na busca de URLs de foto nunca deve pôr o feed em .error")
        }
        XCTAssertEqual(items.map(\.id), [recado.id], "o recado continua visível com o texto")
        XCTAssertTrue(sut.photoURLs(for: recado.id).isEmpty, "só o carrossel daquele recado fica sem imagem")
    }

    func testPhotoURLsMapIsInMemoryOnlyNeverSharedAcrossViewModelInstances() async {
        let photoID = UUID()
        let recado = makeRecado(sequence: 1, photos: [RecadoPhotoRefDTO(id: photoID, position: 0)])
        let page = RecadoFeedPage(items: [recado], nextCursor: nil)
        let transport = MuralFeedStubTransport(firstPage: .page(page))
        let download = makeDownload(id: photoID)
        await transport.setPhotoURLsOutcome(
            .success(PhotoDownloadURLsResponse(recados: [RecadoPhotoURLsDTO(recadoID: recado.id, photos: [download])]))
        )
        let sut1 = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        await sut1.load()
        XCTAssertFalse(sut1.photoURLs(for: recado.id).isEmpty)

        // Uma segunda instância, apontando pro mesmo transporte, nunca deveria "herdar" URLs
        // já buscadas pela primeira — se o mapa fosse persistido em algo compartilhado
        // (UserDefaults, disco), este teste falharia.
        let sut2 = MuralFeedViewModel(apiClient: APIClient(transport: transport, baseURL: url()))
        XCTAssertTrue(sut2.photoURLs(for: recado.id).isEmpty, "o mapa de URLs é só de memória, por instância")
    }
}

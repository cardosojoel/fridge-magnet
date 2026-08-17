import XCTest
import JKLarShared
@testable import JKLar

/// Transporte falso que roteia `GET`/`POST api/v1/recados/:id/comments` — dono deste arquivo,
/// sem estado compartilhado com stubs de outros arquivos de teste (mesmo padrão de
/// `MuralFeedStubTransport`). `actor` porque alguns testes trocam o resultado programado entre
/// chamadas.
private actor RecadoDetailStubTransport: APIClientTransport {
    enum CommentsOutcome {
        case success([CommentDTO])
        case failure(status: Int)
    }

    enum CreateOutcome {
        case success(CommentDTO)
        case failure(status: Int)
    }

    private var commentsOutcome: CommentsOutcome
    private var createOutcome: CreateOutcome
    private(set) var createCallCount = 0
    /// Um elemento por chamada a `POST .../comments`, na ordem em que ocorreram.
    private(set) var createRequestedBodies: [CreateCommentRequest] = []

    init(commentsOutcome: CommentsOutcome, createOutcome: CreateOutcome) {
        self.commentsOutcome = commentsOutcome
        self.createOutcome = createOutcome
    }

    func setCommentsOutcome(_ outcome: CommentsOutcome) {
        commentsOutcome = outcome
    }

    func setCreateOutcome(_ outcome: CreateOutcome) {
        createOutcome = outcome
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "GET" {
            switch commentsOutcome {
            case .success(let comments):
                let data = try JSONEncoder().encode(comments)
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .failure(let status):
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }

        createCallCount += 1
        if let body = request.httpBody, let decoded = try? JSONDecoder().decode(CreateCommentRequest.self, from: body) {
            createRequestedBodies.append(decoded)
        }
        switch createOutcome {
        case .success(let comment):
            let data = try JSONEncoder().encode(comment)
            return (data, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        case .failure(let status):
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Transporte que bloqueia dentro de `POST .../comments` até `release()` ser chamado — `GET`
/// (carga inicial) responde na hora, pro teste poder popular `state` antes de exercitar o
/// envio bloqueante. Mesmo molde de `MuralFeedGatedTransport`.
private actor RecadoDetailGatedTransport: APIClientTransport {
    private let commentsPage: [CommentDTO]
    private let createdComment: CommentDTO
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var createCallCount = 0

    init(commentsPage: [CommentDTO], createdComment: CommentDTO) {
        self.commentsPage = commentsPage
        self.createdComment = createdComment
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if request.httpMethod == "GET" {
            let data = try JSONEncoder().encode(commentsPage)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        createCallCount += 1
        await waitUntilReleased()
        let data = try JSONEncoder().encode(createdComment)
        return (data, HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
final class RecadoDetailViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeRecado(id: UUID = UUID()) -> RecadoDTO {
        RecadoDTO(
            id: id, authorID: UUID(), authorDisplayName: "Alguém", isMine: false, text: "Oi",
            sequence: 1, createdAt: Date(), updatedAt: Date(), photos: [], mentions: [],
            reactions: [], myReaction: nil, commentCount: 0, latestComments: []
        )
    }

    private func makeComment(
        id: UUID = UUID(), text: String = "Comentário", createdAt: Date = Date(), mentions: [MentionDTO] = []
    ) -> CommentDTO {
        CommentDTO(
            id: id, authorID: UUID(), authorDisplayName: "Fulano", text: text, mentions: mentions,
            createdAt: createdAt, isMine: false
        )
    }

    // MARK: load()

    func testLoadWithFiveCommentsLeadsToLoadedInServerOrder() async {
        let comments = (0..<5).map { makeComment(text: "Comentário \($0)") }
        let transport = RecadoDetailStubTransport(
            commentsOutcome: .success(comments), createOutcome: .success(makeComment())
        )
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loaded) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(loaded.map(\.id), comments.map(\.id), "o cliente não reordena")
    }

    func testLoadWithNoCommentsIsEmptyStateNotError() async {
        let transport = RecadoDetailStubTransport(commentsOutcome: .success([]), createOutcome: .success(makeComment()))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))

        await sut.load()

        guard case .loaded(let loaded) = sut.state else {
            return XCTFail("recado sem comentário é o estado vazio, não erro")
        }
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadFailurePreservesLastGoodList() async {
        let comments = [makeComment()]
        let transport = RecadoDetailStubTransport(commentsOutcome: .success(comments), createOutcome: .success(makeComment()))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()

        await transport.setCommentsOutcome(.failure(status: 500))
        await sut.load()

        guard case .error(let message, let lastGood) = sut.state else {
            return XCTFail("esperava .error")
        }
        XCTAssertEqual(message, JKCopy.muralCommentLoadError)
        XCTAssertEqual(lastGood?.map(\.id), comments.map(\.id))
    }

    // MARK: canSubmitComment

    func testCanSubmitCommentFalseWithEmptyOrWhitespaceOnlyTrueWithText() async {
        let transport = RecadoDetailStubTransport(commentsOutcome: .success([]), createOutcome: .success(makeComment()))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))

        sut.commentText = ""
        XCTAssertFalse(sut.canSubmitComment)

        sut.commentText = "   \n  "
        XCTAssertFalse(sut.canSubmitComment)

        sut.commentText = "Oi"
        XCTAssertTrue(sut.canSubmitComment)
    }

    // MARK: submitComment()

    func testSubmitCommentInFlightSetsIsSubmittingTrueAndCanSubmitFalse() async {
        let gated = RecadoDetailGatedTransport(commentsPage: [], createdComment: makeComment())
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: gated, baseURL: url()))
        await sut.load()
        sut.commentText = "Em voo"

        let task = Task { await sut.submitComment() }
        var attempts = 0
        while await gated.createCallCount == 0, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }

        XCTAssertTrue(sut.isSubmittingComment, "enquanto em voo, isSubmittingComment é verdadeiro")
        XCTAssertFalse(sut.canSubmitComment, "enquanto em voo, canSubmitComment é falso")

        await gated.release()
        await task.value
        XCTAssertFalse(sut.isSubmittingComment, "depois de resolver, isSubmittingComment volta a falso")
    }

    func testSubmitCommentSuccessAppendsToEndAndClearsField() async {
        let existing = makeComment(text: "Primeiro", createdAt: Date().addingTimeInterval(-60))
        let newComment = makeComment(text: "Novo")
        let transport = RecadoDetailStubTransport(
            commentsOutcome: .success([existing]), createOutcome: .success(newComment)
        )
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        sut.commentText = "Novo"

        await sut.submitComment()

        guard case .loaded(let comments) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertEqual(comments.map(\.id), [existing.id, newComment.id], "o comentário novo vai pro fim da lista")
        XCTAssertEqual(sut.commentText, "", "o campo limpa depois do sucesso")
    }

    func testSubmitCommentFailureSetsGenericErrorDoesNotClearFieldOrAddToList() async {
        let transport = RecadoDetailStubTransport(commentsOutcome: .success([]), createOutcome: .failure(status: 500))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        sut.commentText = "Vai falhar"

        await sut.submitComment()

        XCTAssertEqual(sut.actionErrorMessage, JKCopy.muralCommentGenericPostError)
        XCTAssertEqual(sut.commentText, "Vai falhar", "o campo não é limpo numa falha")
        guard case .loaded(let comments) = sut.state else {
            return XCTFail("esperava .loaded")
        }
        XCTAssertTrue(comments.isEmpty, "nada é acrescentado numa falha")
    }

    func testSubmitCommentWithTwoMentionedMembersSendsBothUserIDs() async {
        let transport = RecadoDetailStubTransport(commentsOutcome: .success([]), createOutcome: .success(makeComment()))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        let member1 = MentionDTO(userID: UUID(), displayName: "Ana")
        let member2 = MentionDTO(userID: UUID(), displayName: "Bruno")
        sut.setMentions([member1, member2])
        sut.commentText = "Marcando dois"

        await sut.submitComment()

        let requestedBodies = await transport.createRequestedBodies
        XCTAssertEqual(requestedBodies.last?.mentionedUserIDs, [member1.userID, member2.userID])
    }

    func testSubmitCommentFailurePreservesMentionedMembers() async {
        let transport = RecadoDetailStubTransport(commentsOutcome: .success([]), createOutcome: .failure(status: 500))
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: transport, baseURL: url()))
        await sut.load()
        let member = MentionDTO(userID: UUID(), displayName: "Ana")
        sut.setMentions([member])
        sut.commentText = "Vai falhar"

        await sut.submitComment()

        XCTAssertEqual(sut.selectedMentions.map(\.userID), [member.userID], "a seleção não se perde junto com o erro")
    }

    func testConcurrentSubmitCommentCallsTriggerExactlyOneNetworkCall() async {
        let gated = RecadoDetailGatedTransport(commentsPage: [], createdComment: makeComment())
        let sut = RecadoDetailViewModel(recado: makeRecado(), apiClient: APIClient(transport: gated, baseURL: url()))
        await sut.load()
        sut.commentText = "Duplo toque"

        let task1 = Task { await sut.submitComment() }
        var attempts = 0
        while await gated.createCallCount == 0, attempts < 10_000 {
            await Task.yield()
            attempts += 1
        }
        let task2 = Task { await sut.submitComment() }

        await gated.release()
        await task1.value
        await task2.value

        let callCount = await gated.createCallCount
        XCTAssertEqual(callCount, 1, "duas chamadas concorrentes disparam exatamente uma chamada de rede")
    }
}

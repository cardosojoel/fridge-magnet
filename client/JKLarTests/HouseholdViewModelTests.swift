import XCTest
import JKLarShared
@testable import JKLar

/// Transporte falso que roteia por caminho/método entre `GET .../current`,
/// `GET .../members` e `DELETE .../membership` — dono deste arquivo, sem estado
/// compartilhado com os stubs de outros arquivos de teste (mesmo padrão documentado em
/// `JoinByCodeViewModelTests.swift`). `actor` porque `HouseholdViewModel.leaveHousehold()`
/// precisa observar a "casa" desaparecer depois do sucesso — `setHouseholdResponse(_:)`
/// troca a resposta programada no momento certo, em vez de simular um servidor stateful de
/// verdade.
private actor HouseholdStubTransport: APIClientTransport {
    enum Response {
        case household(HouseholdDTO)
        case members([MemberDTO])
        case noHousehold
        case noContent
        case apiError(APIErrorCode, status: Int)
    }

    private var householdResponse: Response
    private let membersResponse: Response
    private let deleteMembershipResponse: Response

    init(household: Response, members: Response, deleteMembership: Response) {
        self.householdResponse = household
        self.membersResponse = members
        self.deleteMembershipResponse = deleteMembership
    }

    func setHouseholdResponse(_ response: Response) {
        householdResponse = response
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let path = url.path
        let method = request.httpMethod ?? "GET"

        if method == "DELETE", path.hasSuffix("/membership") {
            return try Self.encode(deleteMembershipResponse, url: url)
        }
        if method == "GET", path.hasSuffix("/members") {
            return try Self.encode(membersResponse, url: url)
        }
        if method == "GET", path.hasSuffix("/current") {
            return try Self.encode(householdResponse, url: url)
        }
        fatalError("rota não esperada no teste: \(method) \(path)")
    }

    private static func encode(_ response: Response, url: URL) throws -> (Data, HTTPURLResponse) {
        switch response {
        case .household(let dto):
            let data = try JSONEncoder().encode(dto)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .members(let dtos):
            let data = try JSONEncoder().encode(dtos)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case .noHousehold:
            return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        case .noContent:
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        case .apiError(let code, let status):
            let data = try JSONEncoder().encode(APIErrorResponse(code: code, message: "erro de teste"))
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Cobre os três primeiros itens testáveis em isolamento (sem SwiftUI/simulador) do
/// `<behavior>` da Task 2 do plano 01-10: regras de `canRemove(_:)`, saída com sucesso
/// limpando a casa em cache no `SessionStore` (e derivando `.needsHousehold`, D-02), e o
/// bloqueio de último admin mostrando a mensagem inline sem descartar a lista carregada.
@MainActor
final class HouseholdViewModelTests: XCTestCase {
    private func url() -> URL { URL(string: "http://test.local")! }

    private func makeMember(name: String, role: MemberRole, isSelf: Bool) -> MemberDTO {
        MemberDTO(id: UUID(), displayName: name, role: role, joinedAt: Date(), isSelf: isSelf)
    }

    // MARK: canRemove(_:)

    func testCanRemoveIsFalseForOwnRowAndTrueForOtherRowsWhenRequesterIsAdmin() async {
        let me = makeMember(name: "Eu", role: .admin, isSelf: true)
        let other = makeMember(name: "Outro", role: .adulto, isSelf: false)
        let household = HouseholdDTO(id: UUID(), name: "Casa", memberCount: 2, myRole: .admin)

        let transport = HouseholdStubTransport(
            household: .household(household), members: .members([me, other]), deleteMembership: .noContent
        )
        let client = APIClient(transport: transport, baseURL: url())
        let sessionStore = SessionStore(apiClient: client)
        let sut = HouseholdViewModel(apiClient: client, sessionStore: sessionStore)
        await sut.load()

        XCTAssertFalse(sut.canRemove(me), "a própria linha nunca é removível pelo botão, mesmo sendo admin")
        XCTAssertTrue(sut.canRemove(other), "admin pode remover qualquer outra linha")
    }

    func testCanRemoveIsFalseForEveryRowWhenRequesterIsNotAdmin() async {
        let me = makeMember(name: "Eu", role: .adulto, isSelf: true)
        let other = makeMember(name: "Outro", role: .adulto, isSelf: false)
        let household = HouseholdDTO(id: UUID(), name: "Casa", memberCount: 2, myRole: .adulto)

        let transport = HouseholdStubTransport(
            household: .household(household), members: .members([me, other]), deleteMembership: .noContent
        )
        let client = APIClient(transport: transport, baseURL: url())
        let sessionStore = SessionStore(apiClient: client)
        let sut = HouseholdViewModel(apiClient: client, sessionStore: sessionStore)
        await sut.load()

        XCTAssertFalse(sut.canRemove(me))
        XCTAssertFalse(sut.canRemove(other), "não-admin nunca vê a ação de remover, nem nas linhas alheias")
    }

    // MARK: leaveHousehold() — sucesso limpa a casa em cache e deriva .needsHousehold

    func testLeaveHouseholdSuccessClearsCachedHouseholdAndMovesSessionToNeedsHousehold() async {
        let admin = makeMember(name: "Admin", role: .admin, isSelf: false)
        let me = makeMember(name: "Eu", role: .adulto, isSelf: true)
        let household = HouseholdDTO(id: UUID(), name: "Casa", memberCount: 2, myRole: .adulto)

        let transport = HouseholdStubTransport(
            household: .household(household), members: .members([admin, me]), deleteMembership: .noContent
        )
        let client = APIClient(transport: transport, baseURL: url())
        let sessionStore = SessionStore(apiClient: client)
        let sut = HouseholdViewModel(apiClient: client, sessionStore: sessionStore)
        await sut.load()

        // Depois que a saída é confirmada pelo servidor, a próxima leitura de
        // `currentHousehold()` (feita por `SessionStore.refreshHouseholdState()`) precisa
        // devolver "sem casa" — é isso que o servidor real devolveria depois de uma
        // `DELETE .../membership` bem-sucedida.
        await transport.setHouseholdResponse(.noHousehold)
        await sut.leaveHousehold()

        XCTAssertNil(sessionStore.household, "sucesso na saída limpa a casa em cache no SessionStore")
        XCTAssertEqual(sessionStore.state, .needsHousehold, "RootView reage voltando para o gate de criar-ou-entrar (D-02)")
        XCTAssertNil(sut.actionErrorMessage)
    }

    // MARK: lastAdmin — mensagem inline, lista intacta

    func testLastAdminBlockShowsInlineMessageAndKeepsListIntact() async {
        let me = makeMember(name: "Eu", role: .admin, isSelf: true)
        let household = HouseholdDTO(id: UUID(), name: "Casa", memberCount: 1, myRole: .admin)

        let transport = HouseholdStubTransport(
            household: .household(household),
            members: .members([me]),
            deleteMembership: .apiError(.lastAdmin, status: 409)
        )
        let client = APIClient(transport: transport, baseURL: url())
        let sessionStore = SessionStore(apiClient: client)
        // Popula sessionStore.household/state antes do teste, como o RootView real já teria
        // feito ao chegar nesta tela — sem isso, `household` começaria `nil` de qualquer
        // forma (sucesso ou falha), e a asserção abaixo não provaria nada.
        await sessionStore.refreshHouseholdState()
        let sut = HouseholdViewModel(apiClient: client, sessionStore: sessionStore)
        await sut.load()

        await sut.leaveHousehold()

        XCTAssertEqual(sut.actionErrorMessage, JKCopy.householdLastAdminBlockMessage)
        XCTAssertEqual(sessionStore.state, .inHousehold, "um lastAdmin nunca move a sessão para fora da casa")
        XCTAssertNotNil(sessionStore.household, "a casa em cache não é limpa quando a saída é recusada")
        guard case .loaded(let loadedHousehold, let members) = sut.state else {
            return XCTFail("a lista deve continuar carregada, sem trocar de estado por causa do bloqueio")
        }
        XCTAssertEqual(loadedHousehold.id, household.id)
        XCTAssertEqual(members.count, 1)
    }
}

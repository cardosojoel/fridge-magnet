import XCTest
@testable import FridgeMagnet

/// Contra o Keychain real do macOS (sem mock — `Security.framework` não tem um substituto
/// razoável para este contrato simples). `tearDown` limpa sempre, para nenhum teste vazar
/// estado para o próximo.
final class KeychainTokenStoreTests: XCTestCase {
    override func tearDown() {
        KeychainTokenStore.delete()
        super.tearDown()
    }

    func testReadWithNothingSavedReturnsNil() {
        KeychainTokenStore.delete()
        XCTAssertNil(KeychainTokenStore.read())
    }

    func testSaveThenReadReturnsExactlyTheSamePair() {
        let pair = TokenPair(accessToken: "access-123", refreshToken: "refresh-456")
        KeychainTokenStore.save(pair)
        XCTAssertEqual(KeychainTokenStore.read(), pair)
    }

    func testDeleteMakesReadReturnNil() {
        KeychainTokenStore.save(TokenPair(accessToken: "a", refreshToken: "b"))
        KeychainTokenStore.delete()
        XCTAssertNil(KeychainTokenStore.read())
    }

    func testSavingTwiceOverwritesRatherThanDuplicating() {
        KeychainTokenStore.save(TokenPair(accessToken: "first-access", refreshToken: "first-refresh"))
        KeychainTokenStore.save(TokenPair(accessToken: "second-access", refreshToken: "second-refresh"))

        XCTAssertEqual(
            KeychainTokenStore.read(),
            TokenPair(accessToken: "second-access", refreshToken: "second-refresh")
        )
    }

    func testDeletingWhenNothingSavedIsIdempotent() {
        KeychainTokenStore.delete()
        KeychainTokenStore.delete()
        XCTAssertNil(KeychainTokenStore.read())
    }
}

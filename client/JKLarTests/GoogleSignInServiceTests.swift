import XCTest
@testable import JKLar

/// Guard de configuração do `GoogleSignInService` (fix do crash de 2026-08-17): com
/// `GIDClientID` ausente/vazio no Info.plist, o `GIDSignIn` lança
/// `NSInvalidArgumentException` não-capturável e derruba o app — o guard precisa barrar
/// ANTES de qualquer chamada ao SDK. A função é pura de propósito: testá-la não pode exigir
/// tocar o singleton `GIDSignIn` (que crasharia o runner pelo mesmo motivo).
final class GoogleSignInServiceTests: XCTestCase {
    func testNilClientIDIsNotConfigured() {
        XCTAssertEqual(GoogleSignInService.configurationError(clientID: nil), .notConfigured)
    }

    func testEmptyClientIDIsNotConfigured() {
        XCTAssertEqual(GoogleSignInService.configurationError(clientID: ""), .notConfigured)
    }

    func testWhitespaceOnlyClientIDIsNotConfigured() {
        // O Local.xcconfig com `GOOGLE_CLIENT_ID =` (valor em branco) produz string vazia,
        // mas um espaço acidental no arquivo produziria só-espaços — os dois são "sem config".
        XCTAssertEqual(GoogleSignInService.configurationError(clientID: "   "), .notConfigured)
    }

    func testRealLookingClientIDPassesTheGuard() {
        XCTAssertNil(GoogleSignInService.configurationError(
            clientID: "1234567890-abc123def456.apps.googleusercontent.com"
        ))
    }
}

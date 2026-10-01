import Foundation
import Security

/// Par access+refresh gravado no Keychain como um único blob `Codable` (D-10). O par é
/// atômico: meio par gravado (ex.: só o access, sem o refresh) é pior que nenhum, porque
/// `APIClient` não teria como renovar uma sessão com access expirado e refresh ausente.
struct TokenPair: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Encapsula `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` para a única conta de sessão
/// do FridgeMagnet. D-10 exige o Keychain e proíbe qualquer outro mecanismo de preferências do app
/// para este dado — nenhum outro arquivo de `Core/Auth` grava sessão em outro lugar (gate por
/// grep no plano 01-05, que por isso não pode citar literalmente o nome do mecanismo proibido
/// neste diretório).
///
/// `enum` sem estado próprio: cada chamada consulta o Keychain diretamente, então não há
/// necessidade de sincronização adicional além da que o próprio `Security.framework` já
/// garante para chamadas de `SecItem*`.
enum KeychainTokenStore {
    private static let service = "com.fridgemagnet.session"
    private static let account = "session"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Grava o par de tokens, sobrescrevendo qualquer valor anterior. Sempre apaga antes de
    /// inserir — evita `errSecDuplicateItem` numa segunda gravação e garante que salvar duas
    /// vezes sobrescreve em vez de duplicar.
    static func save(_ pair: TokenPair) {
        guard let data = try? JSONEncoder().encode(pair) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Lê o par salvo, ou `nil` se nada foi gravado (ou se o valor gravado não decodifica
    /// mais como `TokenPair` — tratado como "sem sessão", nunca como crash).
    static func read() -> TokenPair? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TokenPair.self, from: data)
    }

    /// Apaga a sessão salva. Idempotente — apagar quando não há nada salvo não é erro.
    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

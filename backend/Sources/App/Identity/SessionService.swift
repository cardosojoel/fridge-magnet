import Crypto
import Fluent
import FluentSQL
import Foundation
import JKLarShared
import JWT
import Vapor

/// Único ponto de emissão, rotação e revogação de sessão do JK Lar (plano 01-04).
///
/// `AuthController` nunca gera ou invalida um refresh token diretamente — toda sessão
/// passa por `issueSession`, `rotate`, `revoke` ou `revokeFamily`. O valor cru do refresh
/// token existe só na memória deste serviço e na resposta HTTP que o devolve; a tabela
/// `refresh_tokens` guarda apenas o SHA-256 (T-04-02).
struct SessionService {
    /// Único motivo de falha exposto ao chamador — `AuthController` sempre traduz para o
    /// mesmo `APIErrorCode.unauthorized`, exista o token, esteja expirado ou já tenha sido
    /// revogado (T-04-04: sem oráculo de existência de token).
    enum SessionError: Error {
        case invalidRefreshToken
    }

    let app: Application

    init(app: Application) {
        self.app = app
    }

    /// Emite uma sessão nova: access token JWT ES256 (`SessionPolicy.accessTokenLifetime`)
    /// + refresh token opaco de 32 bytes de um CSPRNG, devolvido em texto puro só nesta
    /// resposta. Persiste apenas o hash SHA-256 em `refresh_tokens`.
    ///
    /// `familyID` é `nil` no login (nova família) e o `family_id` da linha antiga na
    /// rotação (`rotate` preserva a família).
    func issueSession(
        for user: User,
        email: String? = nil,
        familyID: UUID? = nil,
        on database: any Database
    ) async throws -> SessionResponse {
        try await issueSessionInternal(for: user, email: email, familyID: familyID, on: database).response
    }

    /// Rotaciona um refresh token apresentado: valida (existe, não revogado, não expirado),
    /// emite uma sessão nova com a **mesma** família, e marca a linha antiga
    /// `revoked_at`/`replaced_by_id` — tudo na mesma transação, com a linha antiga travada
    /// por `SELECT ... FOR UPDATE` (T-04-06: impede duas rotações concorrentes do mesmo
    /// token de criarem duas famílias vivas).
    func rotate(presentedToken: String, on database: any Database) async throws -> SessionResponse {
        let tokenHash = Self.hash(presentedToken)

        let outcome = try await database.transaction { transactionDB -> RotateOutcome in
            guard let sql = transactionDB as? SQLDatabase else {
                fatalError("SessionService.rotate exige um SQLDatabase (FluentSQL escape hatch)")
            }

            guard let locked = try await Self.lockRefreshTokenRow(tokenHash: tokenHash, on: sql) else {
                // Token inexistente — nada a fazer, mesma resposta de qualquer outra falha.
                return .invalid
            }

            guard locked.revokedAt == nil else {
                // Um token revogado só existe depois de já ter sido rotacionado — reapresentá-lo
                // é a assinatura de roubo/replay (T-04-01). A revogação de família roda DENTRO
                // desta mesma transação e o outcome é devolvido por `return` (não `throw`): se
                // lançássemos aqui, `database.transaction` reverteria a UPDATE de `revokeFamily`
                // junto com tudo o mais, e a família comprometida continuaria viva.
                self.app.logger.warning(
                    "refresh token reapresentado após rotação — revogando família",
                    metadata: [
                        "user_id": .string(locked.userID.uuidString),
                        "family_id": .string(locked.familyID.uuidString),
                    ]
                )
                try await self.revokeFamily(familyID: locked.familyID, on: transactionDB)
                return .invalid
            }

            guard locked.expiresAt > Date() else {
                return .invalid
            }

            guard let user = try await User.find(locked.userID, on: transactionDB) else {
                return .invalid
            }

            let issued = try await self.issueSessionInternal(
                for: user,
                email: nil,
                familyID: locked.familyID,
                on: transactionDB
            )

            try await sql.raw("""
                UPDATE refresh_tokens
                SET revoked_at = now(), replaced_by_id = \(bind: try issued.refreshTokenRow.requireID())
                WHERE id = \(bind: locked.id)
                """).run()

            return .success(issued.response)
        }

        switch outcome {
        case .success(let response):
            return response
        case .invalid:
            throw SessionError.invalidRefreshToken
        }
    }

    /// Marca `revoked_at` da linha correspondente. Idempotente e sempre silencioso — exista
    /// o token ou não, `revoke` nunca lança, para não vazar ao chamador se um logout já
    /// havia acontecido antes.
    func revoke(presentedToken: String, on database: any Database) async throws {
        let tokenHash = Self.hash(presentedToken)
        guard let sql = database as? SQLDatabase else {
            fatalError("SessionService.revoke exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("""
            UPDATE refresh_tokens SET revoked_at = now()
            WHERE token_hash = \(bind: tokenHash) AND revoked_at IS NULL
            """).run()
    }

    /// Revoga toda a família de um refresh token roubado/reapresentado — chamada só por
    /// `rotate` na detecção de reuso (T-04-01, plano 01-04 Task 2). Um único `UPDATE`
    /// afeta toda a cadeia de rotações daquele login de uma vez; um segundo login do mesmo
    /// usuário tem `family_id` diferente e não é afetado.
    func revokeFamily(familyID: UUID, on database: any Database) async throws {
        guard let sql = database as? SQLDatabase else {
            fatalError("SessionService.revokeFamily exige um SQLDatabase (FluentSQL escape hatch)")
        }
        try await sql.raw("""
            UPDATE refresh_tokens SET revoked_at = now()
            WHERE family_id = \(bind: familyID) AND revoked_at IS NULL
            """).run()
    }

    // MARK: Internals

    private struct IssuedSession {
        var response: SessionResponse
        var refreshTokenRow: RefreshToken
    }

    private enum RotateOutcome {
        case success(SessionResponse)
        case invalid
    }

    private func issueSessionInternal(
        for user: User,
        email: String?,
        familyID: UUID?,
        on database: any Database
    ) async throws -> IssuedSession {
        let userID = try user.requireID()
        let rawToken = Self.generateRawToken()
        let tokenHash = Self.hash(rawToken)
        let resolvedFamilyID = familyID ?? UUID()

        let refreshRow = RefreshToken(
            userID: userID,
            familyID: resolvedFamilyID,
            tokenHash: tokenHash,
            expiresAt: Date().addingTimeInterval(SessionPolicy.refreshTokenLifetime)
        )
        try await refreshRow.save(on: database)

        let accessPayload = AccessTokenPayload(
            subject: SubjectClaim(value: userID.uuidString),
            expiration: .init(value: Date().addingTimeInterval(SessionPolicy.accessTokenLifetime))
        )
        let accessToken = try await app.jwt.keys.sign(accessPayload)

        // Plano 01-02: SessionResponse.household já existia no contrato desde o plano
        // 01-01 — toda emissão de sessão (login e rotação) o preenche do mesmo jeito.
        let householdSummary = try await HouseholdContextMiddleware.resolveHouseholdSummary(
            userID: userID,
            database: database
        )

        let userDTO = UserDTO(
            id: userID,
            displayName: user.displayName,
            email: email,
            gender: user.gender.flatMap(Gender.init(rawValue:))
        )

        let response = SessionResponse(
            accessToken: accessToken,
            refreshToken: rawToken,
            expiresIn: Int(SessionPolicy.accessTokenLifetime),
            user: userDTO,
            household: householdSummary
        )
        return IssuedSession(response: response, refreshTokenRow: refreshRow)
    }

    /// Recorte decodificado da linha travada por `FOR UPDATE` — lido via SQL cru (não
    /// Fluent) porque o lock precisa acontecer na mesma instrução que a leitura.
    private struct LockedRefreshTokenRow {
        var id: UUID
        var userID: UUID
        var familyID: UUID
        var revokedAt: Date?
        var expiresAt: Date
    }

    private static func lockRefreshTokenRow(
        tokenHash: String,
        on sql: any SQLDatabase
    ) async throws -> LockedRefreshTokenRow? {
        guard let row = try await sql.raw("""
            SELECT id, user_id, family_id, revoked_at, expires_at
            FROM refresh_tokens
            WHERE token_hash = \(bind: tokenHash)
            FOR UPDATE
            """).first()
        else {
            return nil
        }
        return LockedRefreshTokenRow(
            id: try row.decode(column: "id", as: UUID.self),
            userID: try row.decode(column: "user_id", as: UUID.self),
            familyID: try row.decode(column: "family_id", as: UUID.self),
            revokedAt: try row.decode(column: "revoked_at", as: Date?.self),
            expiresAt: try row.decode(column: "expires_at", as: Date.self)
        )
    }

    /// 32 bytes de um CSPRNG (`SystemRandomNumberGenerator` — `arc4random_buf` no Darwin,
    /// nunca um gerador semeado por relógio), codificados em base64url sem padding.
    private static func generateRawToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = [UInt8].random(count: 32, using: &rng)
        return bytes.base64URLEncodedString()
    }

    /// SHA-256 do valor cru, em hexadecimal minúsculo — o único formato persistido em
    /// `refresh_tokens.token_hash` (T-04-02).
    private static func hash(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension [UInt8] {
    /// Base64url sem padding (RFC 4648 §5) — usado pelo refresh token opaco emitido em
    /// `SessionService.issueSession`.
    func base64URLEncodedString() -> String {
        Data(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Fluent
import FluentSQL
import Foundation
import FridgeMagnetShared
import Vapor

/// Resolve `(provider, subject, email, emailVerified)` já verificados para um `User`
/// interno, criando quando ausente.
///
/// Ordem de decisão (01-RESEARCH.md Architecture Patterns > Pattern 1, D-03):
/// 1. Buscar `linked_identities` por `(provider, provider_subject)` — achou, devolve
///    aquele `user_id`. É o caminho de todo login recorrente, e nunca consulta e-mail.
/// 2. Não achou, e o token traz e-mail verificado: buscar um `linked_identities`
///    EXISTENTE cujo `lower(email)` bate **e** que já está marcado `email_verified = true`
///    — achou, cria a nova linha de `linked_identities` apontando para aquele `user_id`,
///    sem criar usuário (plano 01-08, Task 2).
/// 3. Qualquer outro caso → cria `users` + `linked_identities`.
///
/// As duas guardas que tornam a etapa 2 segura em vez de uma tomada de conta
/// (`findExistingVerifiedIdentity`/o parâmetro `emailVerified` recebido): a verificação é
/// exigida nos **dois** lados — o registro existente precisa estar marcado verificado, não
/// só o token que chega. E-mail nunca vira chave estrangeira em lugar nenhum (01-RESEARCH.md
/// Pitfall 4) — depois do vínculo, tudo referencia `users.id`.
struct IdentityResolver {
    let database: any Database
    let logger: Logger

    func resolve(
        provider: AuthProvider,
        subject: String,
        email: String?,
        emailVerified: Bool
    ) async throws -> User {
        try await database.transaction { db in
            // Etapa 1: (provider, subject) já vinculado — login recorrente, nunca consulta
            // e-mail.
            if let existing = try await LinkedIdentity.query(on: db)
                .filter(\.$provider == provider.rawValue)
                .filter(\.$providerSubject == subject)
                .with(\.$user)
                .first()
            {
                return existing.user
            }

            // Guarda 1 (D-03): o token apresentado agora precisa trazer e-mail
            // verificado — sem isso, a unificação por e-mail nunca é sequer tentada,
            // mesmo que exista um `users` com o mesmo e-mail.
            let incomingTokenEmailIsVerified = emailVerified
            if incomingTokenEmailIsVerified, let email {
                // Guarda 2 (D-03/T-08-01): só conta como match um `linked_identities`
                // cujo PRÓPRIO `email_verified` já é `true` — um registro existente
                // não-verificado nunca serve de âncora de unificação, mesmo com o
                // mesmo e-mail. `findExistingVerifiedIdentity` filtra por isso.
                if let match = try await findExistingVerifiedIdentity(withEmail: email, on: db) {
                    return try await linkNewIdentity(
                        toExistingUserID: match.userID,
                        existingProvider: match.provider,
                        provider: provider,
                        subject: subject,
                        email: email,
                        db: db
                    )
                }
            }

            // Etapa 3: nenhum caso anterior — usuário novo.
            return try await createUserWithNewIdentity(
                provider: provider,
                subject: subject,
                email: email,
                emailVerified: emailVerified,
                db: db
            )
        }
    }

    private struct VerifiedIdentityMatch {
        var userID: UUID
        var provider: String
    }

    /// Busca por `lower(email)` restrita a linhas já marcadas `email_verified = true`
    /// (Guarda 2 de `resolve`). SQL bruto porque o query builder tipado do Fluent não
    /// expõe `lower()` — é este predicado que exercita o índice parcial
    /// `idx_linked_identities_verified_email` criado por `CreateIdentitySchema`.
    private func findExistingVerifiedIdentity(
        withEmail email: String,
        on db: any Database
    ) async throws -> VerifiedIdentityMatch? {
        guard let sql = db as? SQLDatabase else {
            fatalError("IdentityResolver exige um SQLDatabase para a busca por e-mail verificado")
        }
        guard let row = try await sql.raw("""
            SELECT user_id, provider FROM linked_identities
            WHERE lower(email) = \(bind: email.lowercased()) AND email_verified = true
            LIMIT 1
            """).first() else {
            return nil
        }
        return VerifiedIdentityMatch(
            userID: try row.decode(column: "user_id", as: UUID.self),
            provider: try row.decode(column: "provider", as: String.self)
        )
    }

    /// Cria só a nova `linked_identities`, apontando para um `users.id` que já existe —
    /// nunca cria um segundo `users`. Registra em log de auditoria (nível `notice`) o
    /// evento de vínculo entre provedores: `users.id`, provedor novo e provedor existente
    /// — nunca o e-mail (T-08-07). Um vínculo entre provedores é exatamente o evento que
    /// alguém vai querer reconstituir depois.
    private func linkNewIdentity(
        toExistingUserID userID: UUID,
        existingProvider: String,
        provider: AuthProvider,
        subject: String,
        email: String,
        db: any Database
    ) async throws -> User {
        let linkedIdentity = LinkedIdentity(
            userID: userID,
            provider: provider.rawValue,
            providerSubject: subject,
            email: email,
            emailVerified: true
        )
        try await linkedIdentity.save(on: db)

        logger.notice("Nova identidade vinculada a conta existente por e-mail verificado", metadata: [
            "userID": .string(userID.uuidString),
            "newProvider": .string(provider.rawValue),
            "existingProvider": .string(existingProvider),
        ])

        guard let user = try await User.find(userID, on: db) else {
            fatalError("linked_identities aponta para um users.id inexistente — violação de integridade referencial")
        }
        return user
    }

    /// Etapa 3 de `resolve`: cria `users` + `linked_identities` juntos, dentro da mesma
    /// transação.
    private func createUserWithNewIdentity(
        provider: AuthProvider,
        subject: String,
        email: String?,
        emailVerified: Bool,
        db: any Database
    ) async throws -> User {
        let user = User()
        try await user.save(on: db)

        let linkedIdentity = try LinkedIdentity(
            userID: user.requireID(),
            provider: provider.rawValue,
            providerSubject: subject,
            email: email,
            emailVerified: emailVerified
        )
        try await linkedIdentity.save(on: db)

        return user
    }
}

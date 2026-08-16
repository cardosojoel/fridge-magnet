import Fluent
import Foundation
import JKLarShared

/// Resolve `(provider, subject, email, emailVerified)` já verificados para um `User`
/// interno, criando quando ausente.
///
/// Ordem desta fatia (01-RESEARCH.md Architecture Patterns > Pattern 1): (1) procurar
/// `linked_identities` por `(provider, provider_subject)` — se achar, devolver o
/// `user_id`; (2) senão, criar `users` + `linked_identities`. O degrau de unificação por
/// e-mail verificado de D-03 é o passo intermediário que o plano 01-08 insere entre os
/// dois — este resolvedor já nasce com a assinatura e a transação que ele exige.
/// E-mail nunca vira chave estrangeira em lugar nenhum (Pitfall 4).
struct IdentityResolver {
    let database: any Database

    func resolve(
        provider: AuthProvider,
        subject: String,
        email: String?,
        emailVerified: Bool
    ) async throws -> User {
        try await database.transaction { db in
            if let existing = try await LinkedIdentity.query(on: db)
                .filter(\.$provider == provider.rawValue)
                .filter(\.$providerSubject == subject)
                .with(\.$user)
                .first()
            {
                return existing.user
            }

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
}

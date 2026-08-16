import Fluent
import Foundation
import JKLarShared
import Vapor

/// Resolve `(provider, subject, email, emailVerified)` já verificados para um `User`
/// interno, criando quando ausente.
///
/// RED temporário (plano 01-08 Task 2): esta versão só implementa a Etapa 1 (login
/// recorrente por `(provider, subject)`) e a Etapa 3 (usuário novo) — a Etapa 2 de D-03
/// (unificação por e-mail verificado) chega no commit GREEN seguinte.
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

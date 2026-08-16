import Fluent
import Foundation

/// Conta interna do JK Lar — a chave de junção lida por toda tabela de domínio das Fases
/// 2 a 10. Nunca chaveada pelo `sub` de um provedor nem por e-mail (01-RESEARCH.md
/// Pitfall 4): só por este UUID.
final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "display_name")
    var displayName: String?

    /// String bruta ("feminino" | "masculino" | "naoInformado") espelhando `Gender` do
    /// contrato compartilhado (`JKLarShared`) — opcional por D-04.
    @OptionalField(key: "gender")
    var gender: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, displayName: String? = nil, gender: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.gender = gender
    }
}

/// Federa um provedor de identidade externo (`provider`, `provider_subject`) para um
/// `User` interno.
///
/// `unique(provider, provider_subject)` no schema (`CreateIdentitySchema`) é o que torna
/// IDENT-02 (login recorrente sem duplicata) uma restrição de banco, não só de aplicação —
/// ver `IdentityResolver`.
final class LinkedIdentity: Model, @unchecked Sendable {
    static let schema = "linked_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    /// "apple" | "google" | "microsoft" — espelha `AuthProvider` do contrato compartilhado.
    @Field(key: "provider")
    var provider: String

    /// Identificador estável do provedor (`sub` do identity token) — nunca reaproveitado
    /// como chave estrangeira em nenhuma outra tabela.
    @Field(key: "provider_subject")
    var providerSubject: String

    @OptionalField(key: "email")
    var email: String?

    /// Sempre gravado explicitamente pelo código de aplicação — `false` quando a claim
    /// `email_verified` do provedor está ausente (nunca assumir verdadeiro por omissão).
    /// Trava a unificação por e-mail de D-03 (plano 01-08) contra o degrau de
    /// account-takeover descrito em 01-RESEARCH.md Pitfall/Anti-Pattern.
    @Field(key: "email_verified")
    var emailVerified: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        provider: String,
        providerSubject: String,
        email: String? = nil,
        emailVerified: Bool
    ) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.providerSubject = providerSubject
        self.email = email
        self.emailVerified = emailVerified
    }
}

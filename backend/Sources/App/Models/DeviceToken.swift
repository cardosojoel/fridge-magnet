import Fluent
import Foundation

/// Registro de um device token de push (IDENT-05, IDENT-06) — escopado por `household_id`
/// sob RLS `ENABLE`+`FORCE`, no mesmo espírito de `households`/`household_members`
/// (`CreateHouseholdSchema`). `unique(apns_token)` no schema (`CreateDeviceTokens`) é o que
/// faz o upsert e a troca de casa funcionarem sem lixo acumulado.
final class DeviceToken: Model, @unchecked Sendable {
    static let schema = "device_tokens"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "household_id")
    var household: Household

    @Field(key: "apns_token")
    var apnsToken: String

    /// "ios" | "macos" — espelha `DevicePlatform` do contrato compartilhado.
    @Field(key: "platform")
    var platform: String

    /// "sandbox" | "production" — espelha `APNSEnvironment`. Preenchido pelo cliente no
    /// registro (`#if DEBUG` → sandbox); corrigido pelo backend no primeiro `BadDeviceToken`
    /// (D-16, opção c aprovada no `checkpoint:decision` da Task 1 do plano 01-11 — ver
    /// `PushService`).
    @Field(key: "environment")
    var environment: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: User.IDValue,
        householdID: Household.IDValue,
        apnsToken: String,
        platform: String,
        environment: String
    ) {
        self.id = id
        self.$user.id = userID
        self.$household.id = householdID
        self.apnsToken = apnsToken
        self.platform = platform
        self.environment = environment
    }
}

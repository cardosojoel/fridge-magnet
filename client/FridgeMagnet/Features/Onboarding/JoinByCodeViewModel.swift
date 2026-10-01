import Foundation
import FridgeMagnetShared
import Observation

/// Regras testáveis do formulário "Entrar com código" (D-02, D-05) — cobre os cinco
/// primeiros itens de `<behavior>` da Task 1 do plano 01-09: habilitação de `canSubmit`
/// exatamente em 6 caracteres, normalização para maiúsculas + filtro de alfabeto, estado em
/// voo, e a tradução de `inviteInvalid`/`inviteExpired`/`householdFull` para a cópia certa
/// do 01-UI-SPEC.md.
///
/// `JoinByCodeView` nunca faz `switch` em string de mensagem — só neste tipo, sobre o
/// `APIErrorCode` já tipado por `APIClient.joinHousehold` (T-09-04, zero-trust do
/// `.claude/CLAUDE.md`: a UI traduz o que o servidor decidiu, nunca decide sozinha).
@MainActor
@Observable
final class JoinByCodeViewModel {
    /// Mesmo alfabeto do `InviteCodeGenerator` do backend (plano 01-06, 31 caracteres sem
    /// `0`/`O`/`1`/`I`/`L`) — duplicado aqui porque o cliente não importa código de
    /// `backend/`. Filtragem é conveniência de digitação, nunca validação: o servidor
    /// decide se o código vale, mesmo que o cliente deixe passar algo que não deveria.
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let codeLength = 6

    enum SubmitError: Equatable {
        case invalidOrExpired
        case householdFull
        case generic
    }

    var code: String = "" {
        didSet {
            let normalized = String(code.uppercased().filter(Self.alphabet.contains).prefix(Self.codeLength))
            guard normalized != code else { return }
            code = normalized
        }
    }

    private(set) var isSubmitting = false
    private(set) var submitError: SubmitError?
    /// Preenchido quando `POST /api/v1/households/join` responde com sucesso —
    /// `JoinByCodeView` observa isto para acionar `SessionStore.hydrate()`, a mesma
    /// reconfirmação server-truth usada por `OnboardingViewModel` desde o plano 01-07
    /// (T-05-06).
    private(set) var joinedHousehold: HouseholdDTO?

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Cópia derivada de `submitError` — nunca guardada como `String` própria, para que a
    /// única fonte de verdade sobre "qual erro aconteceu" seja o `APIErrorCode` tipado.
    var errorMessage: String? {
        switch submitError {
        case .invalidOrExpired: FMCopy.onboardingInvalidCodeError
        case .householdFull: FMCopy.onboardingHouseholdFullError
        case .generic: FMCopy.onboardingCreateGenericError
        case nil: nil
        }
    }

    /// Falso com 0–5 caracteres e verdadeiro só com exatamente 6; falso durante uma
    /// validação em voo (01-UI-SPEC.md "loading | code-entry-form").
    var canSubmit: Bool {
        !isSubmitting && code.count == Self.codeLength
    }

    /// Valida o código contra o backend real. Falha preserva `code` (nunca limpo) — o
    /// 01-UI-SPEC.md exige que o texto digitado sobreviva a um erro de código
    /// inválido/expirado ou de casa lotada.
    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        submitError = nil
        do {
            let household = try await apiClient.joinHousehold(code: code)
            joinedHousehold = household
        } catch APIClientError.apiError(.inviteInvalid), APIClientError.apiError(.inviteExpired) {
            submitError = .invalidOrExpired
        } catch APIClientError.apiError(.householdFull) {
            submitError = .householdFull
        } catch {
            submitError = .generic
        }
        isSubmitting = false
    }

    /// Chamado por `OnboardingView` ao consumir um código pendente de deep link
    /// (`fridgemagnet://join/<CODE>`, D-02) — passa pela mesma normalização/filtro do `didSet` de
    /// `code`, nunca um caminho separado que pudesse divergir.
    func prefill(code: String) {
        self.code = code
    }
}

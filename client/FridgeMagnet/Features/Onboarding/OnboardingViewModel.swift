import Foundation
import FridgeMagnetShared
import Observation

/// Regras testáveis do gate obrigatório de casa (D-02) e do formulário "Criar casa" (D-04).
///
/// `OnboardingView` é a única consumidora — `RootView` nunca decide navegação a partir daqui,
/// só reflete o estado real do servidor via `SessionStore.hydrate()` depois que
/// `createdHousehold` é preenchido (a mesma reconfirmação server-truth usada em todo o
/// roteador desde o plano 01-05, T-05-06).
///
/// Zero-trust do `.claude/CLAUDE.md`: o corte em 40 caracteres é conveniência de UI, não
/// validação — o servidor rejeita acima de 40 de qualquer forma (`HouseholdController`,
/// plano 01-02). O cliente nunca é a linha de defesa.
@MainActor
@Observable
final class OnboardingViewModel {
    /// Hard cap de conveniência — o mesmo limite que o servidor aplica (`HouseholdController.
    /// maxHouseholdNameLength`), duplicado aqui como constante de UI porque o cliente não
    /// importa código de `backend/`.
    static let maxHouseholdNameLength = 40

    var houseName: String = "" {
        didSet {
            guard houseName.count > Self.maxHouseholdNameLength else { return }
            houseName = String(houseName.prefix(Self.maxHouseholdNameLength))
        }
    }

    var gender: Gender?

    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    /// Preenchido quando `POST /api/v1/households` responde com sucesso — `OnboardingView`
    /// observa isto para acionar `SessionStore.hydrate()` e sair do gate. Testável em
    /// isolamento sem SwiftUI (comportamento #5 do `<behavior>` da Task 1).
    private(set) var createdHousehold: HouseholdDTO?

    private let apiClient: APIClient

    init(apiClient: APIClient = APIClient()) {
        self.apiClient = apiClient
    }

    /// Falso com o campo vazio ou só com espaços, e durante uma criação em voo — nunca
    /// depende de nada além do que o formulário já sabe localmente.
    var canSubmitCreate: Bool {
        !isSubmitting && !houseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cria a casa contra o backend real. Falha preserva `houseName` (nunca limpo) e expõe a
    /// cópia genérica de `FMCopy` — sem distinguir 400/409 nesta fatia, já que o único jeito
    /// de chegar aqui é com sessão válida e sem casa (o gate de `RootView` garante isso).
    ///
    /// Gênero (D-04) é enviado como uma chamada separada e não-bloqueante depois da criação
    /// ter sucesso: é um campo opcional de perfil, não parte da criação da casa em si
    /// (`CreateHouseholdRequest` nem carrega esse campo — ver `Shared/HouseholdDTO.swift`).
    /// Uma falha ao gravar o gênero nunca deve impedir o membro de entrar na casa que acabou
    /// de criar.
    func submitCreate() async {
        guard canSubmitCreate else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let household = try await apiClient.createHousehold(name: houseName)
            createdHousehold = household
            if let gender {
                try? await apiClient.updateProfile(gender: gender)
            }
        } catch {
            errorMessage = FMCopy.onboardingCreateGenericError
        }
        isSubmitting = false
    }
}

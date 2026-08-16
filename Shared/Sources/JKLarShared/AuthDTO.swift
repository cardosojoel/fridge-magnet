import Foundation

/// Provedores de identidade suportados pelo login do JK Lar.
/// Ordem de exibição no cliente (D-01, 01-CONTEXT.md): Apple primeiro (obrigatório pela
/// App Store Guideline 4.8), depois Google, depois Microsoft. Só `.apple` tem verificador
/// implementado no plano 01-01; `.google` e `.microsoft` chegam no plano 01-08.
public enum AuthProvider: String, Codable, Sendable {
    case apple
    case google
    case microsoft
}

/// Gênero coletado no onboarding (D-04) — campo opcional, usado só pela lógica de tema
/// visual da Fase 9. Nenhuma lógica de tema vive neste arquivo: é só o contrato de dados.
public enum Gender: String, Codable, Sendable {
    case feminino
    case masculino
    case naoInformado
}

/// Corpo de `POST /api/v1/auth/session`.
///
/// `identityToken` é o token assinado que o SDK nativo do provedor devolveu ao cliente
/// (Apple: `identityToken` da `ASAuthorizationAppleIDCredential`; Google/Microsoft: `idToken`).
/// O backend verifica esse token contra o JWKS do provedor e nunca o persiste, loga ou
/// devolve ao cliente (D-12) — ele existe só na memória do handler que processa este request.
public struct SessionRequest: Codable, Sendable {
    public var provider: AuthProvider
    public var identityToken: String
    public var displayName: String?
    public var gender: Gender?

    public init(
        provider: AuthProvider,
        identityToken: String,
        displayName: String? = nil,
        gender: Gender? = nil
    ) {
        self.provider = provider
        self.identityToken = identityToken
        self.displayName = displayName
        self.gender = gender
    }
}

/// Recorte mínimo de casa devolvido dentro de `SessionResponse`.
///
/// Definido aqui — e não em um `HouseholdDTO.swift` próprio — porque o plano 01-01 não cria
/// nenhuma tabela de casa; ele só reserva o campo `SessionResponse.household` no contrato
/// para o plano 01-02 preencher, sem exigir recompilação de um cliente já publicado na
/// App Store. O plano 01-02 pode estender este tipo (nunca renomear o campo).
public struct HouseholdSummaryDTO: Codable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Corpo de `POST /api/v1/auth/refresh` (plano 01-04) — a única credencial apresentada,
/// já que a rota roda deliberadamente fora do `SessionAuthenticator` (o cliente chama
/// `/refresh` justamente quando o access token já expirou).
public struct RefreshRequest: Codable, Sendable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// Corpo de `POST /api/v1/auth/logout` (plano 01-04) — marca o refresh token como
/// revogado no servidor (D-11), não só no dispositivo.
public struct LogoutRequest: Codable, Sendable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// Corpo de `PATCH /api/v1/auth/profile` (plano 01-07) — atualização explícita de gênero
/// depois do login (D-04). O gênero é oferecido no formulário de criar casa, não no login
/// em si, então precisa de uma rota própria em vez de reabrir `/auth/session`; nenhuma
/// lógica de tema é derivada deste valor nesta fase (Fase 9).
public struct UpdateProfileRequest: Codable, Sendable {
    public var gender: Gender

    public init(gender: Gender) {
        self.gender = gender
    }
}

/// Constantes de duração de sessão lidas por cliente e servidor a partir de um único
/// lugar (D-09) — nunca literais duplicados em `AuthController`/`SessionService` de um
/// lado e no cliente do outro.
public enum SessionPolicy {
    /// Validade do access token — 900s (15 min).
    public static let accessTokenLifetime: TimeInterval = 900
    /// Validade do refresh token — 30 dias.
    public static let refreshTokenLifetime: TimeInterval = 60 * 60 * 24 * 30
}

/// Resposta de sessão do JK Lar — devolvida por `POST /api/v1/auth/session` e, no plano
/// 01-04, por `POST /api/v1/auth/refresh`.
public struct SessionResponse: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Segundos até `accessToken` expirar — 900 (15 min) por D-09.
    public var expiresIn: Int
    public var user: UserDTO
    /// Nulo até o plano 01-02 existir uma casa para o usuário — ver `HouseholdSummaryDTO`.
    public var household: HouseholdSummaryDTO?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        user: UserDTO,
        household: HouseholdSummaryDTO? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.user = user
        self.household = household
    }
}

/// Perfil de usuário devolvido ao cliente.
///
/// Nunca inclui e-mail não verificado do provedor nem qualquer claim bruta do identity
/// token — só o que o JK Lar já resolveu e persistiu como seu (D-12, zero-trust do
/// front-end em `.claude/CLAUDE.md`).
public struct UserDTO: Codable, Sendable {
    public var id: UUID
    public var displayName: String?
    public var email: String?
    public var gender: Gender?

    public init(
        id: UUID,
        displayName: String? = nil,
        email: String? = nil,
        gender: Gender? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.gender = gender
    }
}

import Foundation
import MSAL

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Resultado do fluxo real do MSAL na autoridade `common`: o id_token assinado (D-12, usado
/// uma única vez para trocar por sessão no backend e descartado) e o nome de exibição, lido
/// da conta MSAL quando disponível.
struct MicrosoftSignInResult: Sendable {
    var identityToken: String
    var displayName: String?
}

enum MicrosoftSignInError: Error, Equatable {
    case cancelled
    case missingPresentingSurface
    case missingIdentityToken
    case configurationFailure
    case other(String)
}

protocol MicrosoftSignInServiceProtocol: Sendable {
    func signIn() async -> Result<MicrosoftSignInResult, MicrosoftSignInError>
}

/// Ponte entre o MSAL e o contrato de domínio do FridgeMagnet — mesma forma de
/// `AppleSignInService`/`GoogleSignInService`: devolve `(identityToken, displayName?)`.
///
/// A autoridade é sempre `common` — multi-tenant + contas pessoais (D-01, este é o mesmo
/// requisito que levou `MicrosoftTokenVerifier` a nunca fixar um `iss` literal no backend).
/// `MSALPublicClientApplication` é recriada a cada chamada porque `GOOGLE_CLIENT_ID`-style
/// client ID só existe em runtime (lido do `Info.plist` via `MICROSOFT_CLIENT_ID`); manter
/// uma instância cacheada não traz benefício aqui e evita um segundo ponto de estado global.
struct MicrosoftSignInService: MicrosoftSignInServiceProtocol {
    /// Lido do `Info.plist` (`MICROSOFT_CLIENT_ID`, substituído pelo XcodeGen a partir do
    /// ambiente no momento de `xcodegen generate` — mesmo padrão de `GIDClientID`).
    private static var clientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "MicrosoftClientID") as? String
    }

    func signIn() async -> Result<MicrosoftSignInResult, MicrosoftSignInError> {
        guard let clientID = Self.clientID, !clientID.isEmpty else {
            return .failure(.configurationFailure)
        }

        guard let authorityURL = URL(string: "https://login.microsoftonline.com/common") else {
            return .failure(.configurationFailure)
        }

        let application: MSALPublicClientApplication
        do {
            let authority = try MSALAADAuthority(url: authorityURL)
            let config = MSALPublicClientApplicationConfig(clientId: clientID, redirectUri: nil, authority: authority)
            application = try MSALPublicClientApplication(configuration: config)
        } catch {
            return .failure(.configurationFailure)
        }

        #if os(iOS)
        guard let presenter = await Self.topmostViewController() else {
            return .failure(.missingPresentingSurface)
        }
        let webviewParameters = await MSALWebviewParameters(authPresentationViewController: presenter)
        #elseif os(macOS)
        // MSALViewController é NSViewController no macOS — não NSWindow diretamente
        // (MSALWebviewParameters.h) — a janela precisa ter um `contentViewController`.
        guard let presenter = await Self.keyWindow()?.contentViewController else {
            return .failure(.missingPresentingSurface)
        }
        let webviewParameters = await MSALWebviewParameters(authPresentationViewController: presenter)
        #endif

        let interactiveParameters = MSALInteractiveTokenParameters(scopes: ["openid", "profile", "email"], webviewParameters: webviewParameters)

        return await withCheckedContinuation { continuation in
            application.acquireToken(with: interactiveParameters) { result, error in
                continuation.resume(returning: Self.mapResult(result, error))
            }
        }
    }

    /// MSAL não expõe um `signOut()` isolado do token — `removeAccount(_:)` é o
    /// equivalente correto: apaga o cache local do MSAL para esta conta, para que o token
    /// do provedor não continue residente no dispositivo (D-12).
    private static func mapResult(
        _ result: MSALResult?,
        _ error: Error?
    ) -> Result<MicrosoftSignInResult, MicrosoftSignInError> {
        if let error {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain, nsError.code == MSALError.userCanceled.rawValue {
                return .failure(.cancelled)
            }
            return .failure(.other(error.localizedDescription))
        }
        guard let result, let idToken = result.idToken else {
            return .failure(.missingIdentityToken)
        }
        let displayName = result.account.username
        return .success(MicrosoftSignInResult(identityToken: idToken, displayName: displayName))
    }

    #if os(iOS)
    @MainActor
    private static func topmostViewController() -> UIViewController? {
        guard
            let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
    #elseif os(macOS)
    @MainActor
    private static func keyWindow() -> NSWindow? {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    }
    #endif
}

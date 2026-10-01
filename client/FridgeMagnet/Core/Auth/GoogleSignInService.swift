import Foundation
import GoogleSignIn

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Resultado do fluxo real do GIDSignIn: o id_token assinado (D-12, usado uma única vez
/// para trocar por sessão no backend e descartado — nunca gravado em disco) e o nome, que o
/// Google só entrega quando o escopo `profile` foi concedido.
struct GoogleSignInResult: Sendable {
    var identityToken: String
    var displayName: String?
}

enum GoogleSignInError: Error, Equatable {
    case cancelled
    case missingPresentingSurface
    case missingIdentityToken
    /// `GIDClientID` ausente/vazio no Info.plist (Local.xcconfig sem `GOOGLE_CLIENT_ID`).
    /// Sem este guard o `GIDSignIn` lança `NSInvalidArgumentException` não-capturável e
    /// derruba o app inteiro — visto no dogfooding de 2026-08-17 (2 crashes reais). Espelho
    /// do `.configurationFailure` que `MicrosoftSignInService` já tinha.
    case notConfigured
    case other(String)
}

protocol GoogleSignInServiceProtocol: Sendable {
    func signIn() async -> Result<GoogleSignInResult, GoogleSignInError>
}

/// Ponte entre o `GIDSignIn` do GoogleSignIn-iOS e o contrato de domínio do FridgeMagnet — mesma
/// forma de `AppleSignInService`: devolve `(identityToken, displayName?)` e nada mais.
///
/// `#if os(iOS)`/`#if os(macOS)` isolam só o que diverge de verdade entre plataformas — o
/// tipo usado para apresentar o fluxo (`UIViewController` vs `NSWindow`) — sem criar um
/// segundo target (01-08 `<action>`). Depois de entregar o token, `LoginView` chama
/// `GIDSignIn.sharedInstance.signOut()` (via este serviço) para que o token do provedor não
/// continue residente no dispositivo (D-12).
struct GoogleSignInService: GoogleSignInServiceProtocol {
    /// Valida o `GIDClientID` ANTES de qualquer chamada ao SDK — função pura para o teste
    /// unitário cobrir os três estados sem tocar o singleton `GIDSignIn` (que crasharia o
    /// runner de teste do mesmo jeito que crashava o app).
    static func configurationError(clientID: String?) -> GoogleSignInError? {
        guard let clientID, !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notConfigured
        }
        return nil
    }

    func signIn() async -> Result<GoogleSignInResult, GoogleSignInError> {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        if let configurationError = Self.configurationError(clientID: clientID) {
            return .failure(configurationError)
        }

        #if os(iOS)
        guard let presenter = await Self.topmostViewController() else {
            return .failure(.missingPresentingSurface)
        }
        return await Self.performSignIn { completion in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter, completion: completion)
        }
        #elseif os(macOS)
        guard let window = await Self.keyWindow() else {
            return .failure(.missingPresentingSurface)
        }
        return await Self.performSignIn { completion in
            GIDSignIn.sharedInstance.signIn(withPresenting: window, completion: completion)
        }
        #endif
    }

    private static func performSignIn(
        _ start: @escaping (@escaping (GIDSignInResult?, Error?) -> Void) -> Void
    ) async -> Result<GoogleSignInResult, GoogleSignInError> {
        await withCheckedContinuation { continuation in
            start { signInResult, error in
                continuation.resume(returning: Self.mapResult(signInResult, error))
            }
        }
    }

    /// Chama `signOut()` local após extrair o token — o token do provedor cumpriu seu
    /// papel e não pode continuar residente no dispositivo (D-12).
    private static func mapResult(
        _ signInResult: GIDSignInResult?,
        _ error: Error?
    ) -> Result<GoogleSignInResult, GoogleSignInError> {
        if let error {
            let nsError = error as NSError
            // kGIDSignInErrorCodeCanceled = -5 (GIDSignIn.h) — comparado pelo valor bruto
            // porque o tipo Swift gerado para o NS_ERROR_ENUM varia entre versões do SDK;
            // o domínio + código numérico é o contrato estável.
            if nsError.domain == kGIDSignInErrorDomain, nsError.code == -5 {
                return .failure(.cancelled)
            }
            return .failure(.other(error.localizedDescription))
        }
        guard let idToken = signInResult?.user.idToken?.tokenString else {
            return .failure(.missingIdentityToken)
        }
        let displayName = signInResult?.user.profile?.name
        GIDSignIn.sharedInstance.signOut()
        return .success(GoogleSignInResult(identityToken: idToken, displayName: displayName))
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

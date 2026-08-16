@testable import App
import Fluent
import Foundation
import JKLarShared
import XCTVapor

/// Plano 01-08 Task 2 — regra de unificação de conta por e-mail verificado (IDENT-02,
/// D-03). Os sete casos de `<behavior>`, sempre passando pelo caminho real de
/// `POST /api/v1/auth/session` (nunca chamando `IdentityResolver` diretamente) — é o
/// mesmo caminho que um membro real da família percorre ao trocar de provedor.
final class IdentityResolutionTests: XCTestCase {
    private func postSession(
        app: Application,
        provider: AuthProvider,
        token: String
    ) async throws -> (status: HTTPStatus, session: SessionResponse?, error: APIErrorResponse?) {
        let sessionRequest = SessionRequest(provider: provider, identityToken: token)
        var capturedStatus: HTTPStatus = .internalServerError
        var capturedSession: SessionResponse?
        var capturedError: APIErrorResponse?

        try await app.testable().test(
            .POST, "/api/v1/auth/session",
            beforeRequest: { (req: inout XCTHTTPRequest) async throws in
                try req.content.encode(sessionRequest, as: .json)
            },
            afterResponse: { (res: XCTHTTPResponse) async throws in
                capturedStatus = res.status
                if res.status == .ok {
                    capturedSession = try res.content.decode(SessionResponse.self)
                } else {
                    capturedError = try res.content.decode(APIErrorResponse.self)
                }
            }
        )

        return (capturedStatus, capturedSession, capturedError)
    }

    /// Caso principal — nome fixado por `01-VALIDATION.md` linha `01-02`. Apple com
    /// `joel@exemplo.com` verificado, depois Google com o mesmo e-mail verificado: um só
    /// `users.id`, duas linhas em `linked_identities`.
    func testEmailMatchLinksExistingUser() async throws {
        try await TestSupport.withApp { app in
            let email = "joel@exemplo.com"

            let appleToken = try await TestSupport.makeAppleIdentityToken(email: email, emailVerified: true)
            let appleResult = try await postSession(app: app, provider: .apple, token: appleToken)
            XCTAssertEqual(appleResult.status, .ok)
            let appleUserID = try XCTUnwrap(appleResult.session?.user.id)

            let googleToken = try await TestSupport.makeGoogleIdentityToken(email: email, emailVerified: true)
            let googleResult = try await postSession(app: app, provider: .google, token: googleToken)
            XCTAssertEqual(googleResult.status, .ok)
            let googleUserID = try XCTUnwrap(googleResult.session?.user.id)

            XCTAssertEqual(appleUserID, googleUserID, "o mesmo e-mail verificado nos dois lados deve resolver para o mesmo users.id")

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1, "não pode criar um segundo users")

            let linkedCount = try await LinkedIdentity.query(on: app.db).count()
            XCTAssertEqual(linkedCount, 2, "devem existir exatamente duas linked_identities (apple + google)")
        }
    }

    /// Apple com e-mail verificado, depois Google com o mesmo e-mail NÃO verificado — dois
    /// `users.id` distintos.
    func testUnverifiedIncomingEmailNeverUnifies() async throws {
        try await TestSupport.withApp { app in
            let email = "joel@exemplo.com"

            let appleToken = try await TestSupport.makeAppleIdentityToken(email: email, emailVerified: true)
            let appleResult = try await postSession(app: app, provider: .apple, token: appleToken)
            let appleUserID = try XCTUnwrap(appleResult.session?.user.id)

            let googleToken = try await TestSupport.makeGoogleIdentityToken(email: email, emailVerified: false)
            let googleResult = try await postSession(app: app, provider: .google, token: googleToken)
            let googleUserID = try XCTUnwrap(googleResult.session?.user.id)

            XCTAssertNotEqual(appleUserID, googleUserID, "e-mail não verificado no token recebido nunca pode unificar")

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 2)
        }
    }

    /// Apple com e-mail NÃO verificado, depois Google com o mesmo e-mail verificado — dois
    /// `users.id` distintos. Este é o caso mais perigoso de esquecer: sem ele, uma conta
    /// criada por um provedor que não verifica e-mail vira porta de entrada para a conta
    /// de outra pessoa (T-08-01).
    func testExistingUnverifiedEmailNeverServesAsMergeAnchor() async throws {
        try await TestSupport.withApp { app in
            let email = "joel@exemplo.com"

            let appleToken = try await TestSupport.makeAppleIdentityToken(email: email, emailVerified: false)
            let appleResult = try await postSession(app: app, provider: .apple, token: appleToken)
            let appleUserID = try XCTUnwrap(appleResult.session?.user.id)

            let googleToken = try await TestSupport.makeGoogleIdentityToken(email: email, emailVerified: true)
            let googleResult = try await postSession(app: app, provider: .google, token: googleToken)
            let googleUserID = try XCTUnwrap(googleResult.session?.user.id)

            XCTAssertNotEqual(
                appleUserID, googleUserID,
                "um linked_identities existente não-verificado nunca pode servir de âncora de unificação"
            )

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 2)
        }
    }

    /// Diferença apenas de maiúsculas/minúsculas no e-mail conta como o mesmo e-mail.
    func testEmailMatchIsCaseInsensitive() async throws {
        try await TestSupport.withApp { app in
            let appleToken = try await TestSupport.makeAppleIdentityToken(email: "Joel@Exemplo.com", emailVerified: true)
            let appleResult = try await postSession(app: app, provider: .apple, token: appleToken)
            let appleUserID = try XCTUnwrap(appleResult.session?.user.id)

            let googleToken = try await TestSupport.makeGoogleIdentityToken(email: "joel@exemplo.com", emailVerified: true)
            let googleResult = try await postSession(app: app, provider: .google, token: googleToken)
            let googleUserID = try XCTUnwrap(googleResult.session?.user.id)

            XCTAssertEqual(appleUserID, googleUserID, "diferença de maiúsculas/minúsculas não pode impedir a unificação")

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 1)
        }
    }

    /// Google e Microsoft com e-mails diferentes — dois usuários, nenhuma fusão.
    func testDifferentEmailsNeverMerge() async throws {
        try await TestSupport.withApp { app in
            let googleToken = try await TestSupport.makeGoogleIdentityToken(email: "joel@exemplo.com", emailVerified: true)
            let googleResult = try await postSession(app: app, provider: .google, token: googleToken)
            let googleUserID = try XCTUnwrap(googleResult.session?.user.id)

            let microsoftToken = try await TestSupport.makeMicrosoftIdentityToken(
                email: "outrapessoa@exemplo.com", emailVerified: true
            )
            let microsoftResult = try await postSession(app: app, provider: .microsoft, token: microsoftToken)
            let microsoftUserID = try XCTUnwrap(microsoftResult.session?.user.id)

            XCTAssertNotEqual(googleUserID, microsoftUserID)

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 2)
        }
    }

    /// Reapresentar o mesmo `(provider, subject)` nunca cria segunda linha, independente
    /// do e-mail — a Etapa 1 de `IdentityResolver.resolve` nunca consulta e-mail.
    func testRepeatedPresentationOfSameProviderSubjectNeverCreatesSecondRow() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString

            let firstToken = try await TestSupport.makeGoogleIdentityToken(
                subject: subject, email: "joel@exemplo.com", emailVerified: true
            )
            let firstResult = try await postSession(app: app, provider: .google, token: firstToken)
            let firstUserID = try XCTUnwrap(firstResult.session?.user.id)

            // Mesmo (provider, subject), e-mail diferente do primeiro login — a Etapa 1
            // resolve pelo (provider, subject) e nunca chega a olhar o e-mail.
            let secondToken = try await TestSupport.makeGoogleIdentityToken(
                subject: subject, email: "outro@exemplo.com", emailVerified: true
            )
            let secondResult = try await postSession(app: app, provider: .google, token: secondToken)
            let secondUserID = try XCTUnwrap(secondResult.session?.user.id)

            XCTAssertEqual(firstUserID, secondUserID)

            let linkedCount = try await LinkedIdentity.query(on: app.db)
                .filter(\.$provider == AuthProvider.google.rawValue)
                .filter(\.$providerSubject == subject)
                .count()
            XCTAssertEqual(linkedCount, 1, "o mesmo (provider, subject) nunca pode criar uma segunda linked_identities")
        }
    }

    /// Um provedor que muda o e-mail de uma identidade já vinculada não desvincula nem
    /// refunde nada — o vínculo é decidido uma única vez, na primeira apresentação.
    func testChangingEmailOfAlreadyLinkedIdentityNeitherUnlinksNorRelinks() async throws {
        try await TestSupport.withApp { app in
            let subject = UUID().uuidString

            let firstToken = try await TestSupport.makeGoogleIdentityToken(
                subject: subject, email: "original@exemplo.com", emailVerified: true
            )
            let firstResult = try await postSession(app: app, provider: .google, token: firstToken)
            let firstUserID = try XCTUnwrap(firstResult.session?.user.id)

            // Um segundo usuário já existe com o e-mail novo, verificado — se o vínculo
            // fosse reavaliado a cada login, isto fundiria as duas contas incorretamente.
            let otherAppleToken = try await TestSupport.makeAppleIdentityToken(
                email: "novo@exemplo.com", emailVerified: true
            )
            let otherResult = try await postSession(app: app, provider: .apple, token: otherAppleToken)
            let otherUserID = try XCTUnwrap(otherResult.session?.user.id)
            XCTAssertNotEqual(firstUserID, otherUserID)

            let changedEmailToken = try await TestSupport.makeGoogleIdentityToken(
                subject: subject, email: "novo@exemplo.com", emailVerified: true
            )
            let changedResult = try await postSession(app: app, provider: .google, token: changedEmailToken)
            let changedUserID = try XCTUnwrap(changedResult.session?.user.id)

            XCTAssertEqual(
                changedUserID, firstUserID,
                "o vínculo já decidido na primeira apresentação não pode ser reavaliado por uma mudança de e-mail"
            )
            XCTAssertNotEqual(
                changedUserID, otherUserID,
                "mudar o e-mail de uma identidade já vinculada não pode refundir com a conta que já usava esse e-mail"
            )

            let usersCount = try await User.query(on: app.db).count()
            XCTAssertEqual(usersCount, 2, "nenhuma conta nova nem fusão deve acontecer neste terceiro login")

            let linkedCount = try await LinkedIdentity.query(on: app.db)
                .filter(\.$provider == AuthProvider.google.rawValue)
                .filter(\.$providerSubject == subject)
                .count()
            XCTAssertEqual(linkedCount, 1, "a mudança de e-mail não pode criar uma segunda linked_identities para o mesmo (provider, subject)")
        }
    }
}

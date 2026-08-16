import SwiftUI

/// Estado de navegação de nível superior do app inteiro.
///
/// Os quatro casos são declarados desde já (plano 01-03), mesmo que só `.loading` e
/// `.signedOut` tenham destino implementado nesta fatia. Declarar o enum completo agora —
/// em vez de só os dois casos que já têm tela — é o que impede que uma fase futura invente
/// navegação imperativa em cima de um roteador incompleto.
enum JKAppState: Equatable {
    /// Resolvendo a sessão local no lançamento do app.
    case loading
    /// Nenhuma sessão válida encontrada — mostra `LoginView`.
    case signedOut
    /// Sessão válida, mas o usuário ainda não pertence a nenhuma casa. Tela chega no
    /// plano 01-07.
    case needsHousehold
    /// Sessão válida e o usuário já pertence a uma casa. Tela chega no plano 01-07.
    case inHousehold
}

/// Roteador de estado do app inteiro. `JKLarApp` injeta esta view na `WindowGroup`.
///
/// Nesta fatia (01-03) não existe nenhum serviço de sessão real ainda — a leitura do
/// Keychain chega no plano 01-05, e a leitura de pertencimento a uma casa chega no plano
/// 01-07. Por isso a transição de `.loading` para `.signedOut` aqui é incondicional: não há
/// sessão nenhuma para encontrar ainda, então o único destino possível hoje é a tela de
/// login.
struct RootView: View {
    @State private var state: JKAppState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .signedOut:
                LoginView()
            case .needsHousehold, .inHousehold:
                // Chegam no plano 01-07, sobre a sessão real ligada no plano 01-05.
                EmptyView()
            }
        }
        .task {
            // TODO(01-05): substituir por leitura real da sessão no Keychain.
            state = .signedOut
        }
    }
}

#Preview {
    RootView()
}

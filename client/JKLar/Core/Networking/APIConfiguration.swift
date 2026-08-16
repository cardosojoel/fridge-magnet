import Foundation

/// Único lugar do cliente que sabe o endereço do backend (regra zero-trust do
/// `.claude/CLAUDE.md`: nenhum outro arquivo em `client/` referencia host, porta ou caminho
/// de infraestrutura do servidor). Nenhum segredo, chave de assinatura ou nome de tabela
/// aparece aqui nem em nenhum outro arquivo de `Core/` — só a URL base HTTP.
enum APIConfiguration {
    /// Em DEBUG (todo build local/desenvolvimento), sempre o backend Vapor local dos planos
    /// 01-01/01-02/01-04 (`scripts/dev-backend.sh`). `NSAllowsLocalNetworking` no
    /// `project.yml` (plano 01-03) já restringe a exceção de ATS a este hostname.
    ///
    /// Fora de DEBUG, lê `JKLarAPIBaseURL` do Info.plist gerado por `client/project.yml` —
    /// placeholder até a Fase 10 decidir o hosting real (Fly.io/Railway, STACK.md). Não
    /// hardcoda a URL de produção no código-fonte: trocar de provedor de hosting depois não
    /// deve exigir recompilar o app, só regenerar o Info.plist.
    static var baseURL: URL {
        #if DEBUG
        return URL(string: "http://127.0.0.1:8080")!
        #else
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "JKLarAPIBaseURL") as? String,
            let url = URL(string: raw)
        else {
            fatalError("JKLarAPIBaseURL ausente ou inválida no Info.plist de produção")
        }
        return url
        #endif
    }
}

import Foundation

/// Contrato de cópia dos pushes de @menção do mural (D-05, D-09) — texto verbatim do
/// `02-UI-SPEC.md` §Copywriting Contract ("Push — @mention in recado" / "Push — @mention in
/// comment"). Este arquivo é a ÚNICA cópia destas strings no backend: nenhuma view do
/// cliente as duplica, porque o corpo do push é renderizado pelo APNs na tela de bloqueio do
/// aparelho, não pelo app.
enum MuralPushCopy {
    /// Título de todo push de @menção — recado ou comentário, mesmo texto nos dois casos.
    static let mentionTitle = "Você foi mencionado"

    private static let previewMaxLength = 80

    static func recadoMentionBody(author: String, preview: String) -> String {
        "\(author) marcou você num recado: \"\(preview)\""
    }

    /// Consumida pelo plano 02-03 a partir da criação de comentário (D-09) — mesma
    /// infraestrutura de fan-out, corpo de cópia diferente.
    static func commentMentionBody(author: String, preview: String) -> String {
        "\(author) marcou você num comentário: \"\(preview)\""
    }

    /// Texto truncado em ~80 caracteres (com elipse quando truncado), ou a prévia fixa de
    /// foto (ver retorno abaixo) quando não há texto — o recado/comentário sem nenhum texto
    /// (D-01: recado só-foto) usa sempre essa prévia fixa, independente de `hasPhotos`.
    /// `hasPhotos` existe por simetria com o plano 02-04 (fotos de verdade) e não é lido
    /// hoje, porque nenhuma rota desta fase grava foto ainda.
    static func preview(fromText text: String?, hasPhotos: Bool) -> String {
        guard let text, !text.isEmpty else {
            return "uma foto"
        }
        guard text.count > previewMaxLength else {
            return text
        }
        let truncated = text.prefix(previewMaxLength)
        return "\(truncated)…"
    }
}

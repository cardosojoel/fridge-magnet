import Foundation

#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers

/// Leitura de metadado de foto a partir dos **mesmos bytes** que o seletor fora-de-processo já
/// entregou ao compose — o caminho alternativo (resolver o item de volta ao registro do acervo
/// do sistema para ler a data de criação de lá) exigiria autorização de leitura do acervo
/// inteiro, string de uso nova no Info.plist e um alerta de permissão, desfazendo a decisão
/// deliberada do plano 02-06 de o fluxo de foto desta fase nunca pedir permissão nenhuma.
///
/// Namespace sem estado (enum sem casos): tipo próprio — e não método privado da view — porque
/// a leitura de metadado precisa de teste unitário direto (`PhotoMetadataReaderTests`), e um
/// `private static` de uma `View` não é alcançável de `FridgeMagnetTests`.
enum PhotoMetadataReader {
    /// Detecta o `Content-Type` real pelos bytes — nunca confia numa extensão de arquivo, que
    /// o seletor nem sempre expõe. Corpo movido verbatim de `ComposeRecadoView` (plano 02-09),
    /// incluindo o valor de recuo quando os bytes não são imagem interpretável.
    static func contentType(for data: Data) -> String {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let utTypeIdentifier = CGImageSourceGetType(source) as String?,
            let mimeType = UTType(utTypeIdentifier)?.preferredMIMEType
        else {
            return "image/jpeg"
        }
        return mimeType
    }

    /// Data de captura do arquivo (D-11): lê **somente** a chave de data do dicionário EXIF —
    /// nenhuma outra família de metadado (GPS, equipamento) é tocada nem transmitida
    /// (T-02-63). Qualquer passo que falhe (bytes não-imagem, sem EXIF, string de data em
    /// formato inesperado) devolve nulo, nunca lança.
    static func capturedAt(for data: Data) -> Date? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else {
            return nil
        }
        return exifDateFormatter.date(from: raw)
    }

    /// Formato de fio fixo do metadado EXIF ("yyyy:MM:dd HH:mm:ss" — dois-pontos na data, não
    /// ISO 8601), locale POSIX para o parse nunca variar com o aparelho, e o **fuso deixado no
    /// padrão do aparelho de propósito**: o metadado não carrega fuso, e D-11 quer o dia local
    /// da captura — forçar UTC deslocaria o dia do calendário, que é exatamente o que decide se
    /// a legenda aparece. `static let` reutilizado: instanciar `DateFormatter` por foto num
    /// laço de até 10 é desperdício mensurável (T-02-65).
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
#endif

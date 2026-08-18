import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import JKLar

/// Testes de `PhotoMetadataReader` (plano 02-09, D-11): leitura da data de captura e do tipo
/// de conteúdo a partir dos próprios bytes da imagem — nunca do registro da biblioteca de
/// fotos do sistema.
///
/// Os bytes de teste são gerados em tempo de execução via `CGImageDestination` (uma imagem de
/// 1×1 com ou sem dicionário EXIF), em vez de embutir arquivos binários no repositório: uma
/// fixture binária de imagem é opaca — não diz o que está testando nem deixa visível qual
/// metadado carrega — enquanto a geração inline documenta exatamente o cenário de cada caso.
final class PhotoMetadataReaderTests: XCTestCase {
    // MARK: - Geração de bytes de teste

    /// Gera um JPEG de 1×1 em memória; quando `exifDateTimeOriginal` é não-nulo, grava o
    /// dicionário EXIF com `DateTimeOriginal` naquele valor exato (o formato de fio do EXIF é
    /// "yyyy:MM:dd HH:mm:ss" — dois-pontos na data, de propósito).
    private func makeJPEGData(exifDateTimeOriginal: String? = nil) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        var properties: [CFString: Any] = [:]
        if let exifDateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: exifDateTimeOriginal
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Mesmo formatador que o leitor usa (formato de fio fixo do EXIF, locale POSIX, fuso do
    /// aparelho) — o teste compara o `Date` esperado construído pela mesma regra.
    private func exifDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    // MARK: - capturedAt(for:)

    func testCapturedAtReadsExactDateFromExifMetadata() throws {
        let raw = "2026:03:12 08:30:00"
        let data = try makeJPEGData(exifDateTimeOriginal: raw)

        let capturedAt = PhotoMetadataReader.capturedAt(for: data)

        XCTAssertEqual(capturedAt, exifDate(raw), "a data lida é exatamente a gravada no metadado")
    }

    func testCapturedAtIsNilWhenImageHasNoExifDate() throws {
        let data = try makeJPEGData(exifDateTimeOriginal: nil)

        XCTAssertNil(PhotoMetadataReader.capturedAt(for: data), "imagem sem metadado de data produz nulo")
    }

    func testCapturedAtIsNilForNonImageBytesWithoutThrowing() {
        let data = Data("isto não é uma imagem".utf8)

        XCTAssertNil(PhotoMetadataReader.capturedAt(for: data), "bytes que não são imagem produzem nulo, sem lançar")
    }

    func testCapturedAtIsNilForUnexpectedDateStringFormat() throws {
        let data = try makeJPEGData(exifDateTimeOriginal: "12/03/2026 08h30")

        XCTAssertNil(PhotoMetadataReader.capturedAt(for: data), "string de data em formato inesperado produz nulo, sem lançar")
    }

    // MARK: - contentType(for:) (corpo movido de ComposeRecadoView — mesmo comportamento)

    func testContentTypeDetectsJPEGFromBytes() throws {
        let data = try makeJPEGData()

        XCTAssertEqual(PhotoMetadataReader.contentType(for: data), "image/jpeg")
    }

    func testContentTypeFallsBackToJPEGForNonImageBytes() {
        let data = Data("bytes quaisquer".utf8)

        XCTAssertEqual(
            PhotoMetadataReader.contentType(for: data), "image/jpeg",
            "o valor de recuo para bytes não interpretáveis é o mesmo de antes da mudança de casa"
        )
    }

    // MARK: - Regra de exibição da legenda (JKPhotoDateBadge.shouldDisplay, Task 2, D-11)
    // Mesma unidade de assunto (metadado de data de foto) — casos aqui em vez de um arquivo
    // de teste novo por função, que seria fragmentação sem ganho.

    /// Constrói um instante no fuso do aparelho via componentes de calendário — a regra de
    /// D-11 é sobre o **dia local**, então os cenários são declarados em dia/hora locais.
    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    func testShouldDisplayTrueWhenCaptureDayDiffersFromPostDay() throws {
        let captured = try localDate(year: 2026, month: 3, day: 12, hour: 10)
        let posted = try localDate(year: 2026, month: 3, day: 15, hour: 10)

        XCTAssertTrue(JKPhotoDateBadge.shouldDisplay(capturedAt: captured, postedAt: posted))
    }

    func testShouldDisplayFalseForSameCalendarDayWithDifferentHours() throws {
        let captured = try localDate(year: 2026, month: 3, day: 12, hour: 8)
        let posted = try localDate(year: 2026, month: 3, day: 12, hour: 21)

        XCTAssertFalse(
            JKPhotoDateBadge.shouldDisplay(capturedAt: captured, postedAt: posted),
            "a comparação é por dia do calendário, não por instante"
        )
    }

    func testShouldDisplayTrueForAdjacentDaysMinutesApartAroundMidnight() throws {
        let captured = try localDate(year: 2026, month: 3, day: 12, hour: 23, minute: 55)
        let posted = try localDate(year: 2026, month: 3, day: 13, hour: 0, minute: 5)

        XCTAssertTrue(
            JKPhotoDateBadge.shouldDisplay(capturedAt: captured, postedAt: posted),
            "dias de calendário diferentes é o critério, não a distância em segundos"
        )
    }

    func testShouldDisplayFalseForSameLocalDayEvenWhenUTCDaysDiffer() throws {
        // 20:00 e 22:00 locais: no fuso do aparelho de desenvolvimento (UTC-3), viram 23:00
        // e 01:00 em UTC — dias UTC diferentes, mesmo dia local. A regra de D-11 usa o dia
        // local, então a legenda não aparece; num fuso sem essa divergência o caso degrada
        // para "mesmo dia, horas diferentes", que continua correto.
        let captured = try localDate(year: 2026, month: 3, day: 12, hour: 20)
        let posted = try localDate(year: 2026, month: 3, day: 12, hour: 22)

        XCTAssertFalse(
            JKPhotoDateBadge.shouldDisplay(capturedAt: captured, postedAt: posted),
            "mesmo dia no fuso do aparelho — mesmo que os instantes caiam em dias diferentes em UTC"
        )
    }

    // MARK: - Cópia da legenda (JKCopy, Task 2)

    func testCapturedAtCaptionFormatsPortugueseLongDayAndMonth() throws {
        let date = try localDate(year: 2026, month: 3, day: 12, hour: 10)

        XCTAssertEqual(JKCopy.muralPhotoCapturedAtCaption(date), "Tirada em 12 de março")
    }
}

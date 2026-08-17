import XCTest
@testable import JKLar

/// Trava por teste os valores numéricos das tabelas Spacing Scale e Native Materials &
/// Translucency do 01-UI-SPEC.md — é o que impede que uma fase futura mude 16pt para 15pt
/// em silêncio.
final class DesignTokenTests: XCTestCase {
    func testSpacingScaleMatchesUISpec() {
        XCTAssertEqual(JKSpacing.xs, 4)
        XCTAssertEqual(JKSpacing.sm, 8)
        XCTAssertEqual(JKSpacing.md, 16)
        XCTAssertEqual(JKSpacing.lg, 24)
        XCTAssertEqual(JKSpacing.xl, 32)
        XCTAssertEqual(JKSpacing.xxl, 48)
        XCTAssertEqual(JKSpacing.xxxl, 64)
    }

    func testLayoutMetricsMatchUISpec() {
        XCTAssertEqual(JKLayout.minTapTarget, 44)
        XCTAssertEqual(JKLayout.memberRowMinHeight, 56)
        XCTAssertEqual(JKLayout.cardCornerRadius, 16)
        XCTAssertEqual(JKLayout.controlCornerRadius, 12)
        XCTAssertEqual(JKLayout.sheetCornerRadius, 28)
    }

    /// Dimensões de componente do compose em tela cheia (02-UI-SPEC.md § Addendum 2, D-13) —
    /// travadas por teste para ninguém "arredondar" um dos três valores depois sem passar
    /// pelo contrato visual (plano 02-13 Task 1).
    func testComposeFullScreenDimensionsMatchUISpec() {
        XCTAssertEqual(JKLayout.composeSheetMinWidth, 560)
        XCTAssertEqual(JKLayout.composeSheetMinHeight, 640)
        XCTAssertEqual(JKLayout.composePhotoInviteMinHeight, 200)
    }
}

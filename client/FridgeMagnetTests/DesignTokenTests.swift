import XCTest
@testable import FridgeMagnet

/// Trava por teste os valores numéricos das tabelas Spacing Scale e Native Materials &
/// Translucency do 01-UI-SPEC.md — é o que impede que uma fase futura mude 16pt para 15pt
/// em silêncio.
final class DesignTokenTests: XCTestCase {
    func testSpacingScaleMatchesUISpec() {
        XCTAssertEqual(FMSpacing.xs, 4)
        XCTAssertEqual(FMSpacing.sm, 8)
        XCTAssertEqual(FMSpacing.md, 16)
        XCTAssertEqual(FMSpacing.lg, 24)
        XCTAssertEqual(FMSpacing.xl, 32)
        XCTAssertEqual(FMSpacing.xxl, 48)
        XCTAssertEqual(FMSpacing.xxxl, 64)
    }

    func testLayoutMetricsMatchUISpec() {
        XCTAssertEqual(FMLayout.minTapTarget, 44)
        XCTAssertEqual(FMLayout.memberRowMinHeight, 56)
        XCTAssertEqual(FMLayout.cardCornerRadius, 16)
        XCTAssertEqual(FMLayout.controlCornerRadius, 12)
        XCTAssertEqual(FMLayout.sheetCornerRadius, 28)
    }

    /// Dimensões de componente do compose em tela cheia (02-UI-SPEC.md § Addendum 2, D-13) —
    /// travadas por teste para ninguém "arredondar" um dos três valores depois sem passar
    /// pelo contrato visual (plano 02-13 Task 1).
    func testComposeFullScreenDimensionsMatchUISpec() {
        XCTAssertEqual(FMLayout.composeSheetMinWidth, 560)
        XCTAssertEqual(FMLayout.composeSheetMinHeight, 640)
        XCTAssertEqual(FMLayout.composePhotoInviteMinHeight, 200)
    }
}

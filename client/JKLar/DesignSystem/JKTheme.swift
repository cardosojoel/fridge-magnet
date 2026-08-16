import SwiftUI

/// Escala de espaçamento do 01-UI-SPEC.md (§ Spacing Scale). Múltiplos de 4pt — nenhuma view
/// em `client/JKLar/Features` usa um número de espaçamento fora desta escala.
enum JKSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

/// Métricas de layout do 01-UI-SPEC.md (§ Spacing Scale exceptions, § Native Materials &
/// Translucency corner radius table).
enum JKLayout {
    /// 44×44pt mínimo de área tocável — requisito rígido do HIG para qualquer controle
    /// icon-only.
    static let minTapTarget: CGFloat = 44
    /// Altura mínima de linha da lista de membros da casa, para caber avatar + nome +
    /// `JKRoleBadge` sem violar `minTapTarget` na área de toque da linha.
    static let memberRowMinHeight: CGFloat = 56
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 12
    static let sheetCornerRadius: CGFloat = 28

    static let cardShape = RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    static let controlShape = RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
    static let sheetShape = RoundedRectangle(cornerRadius: sheetCornerRadius, style: .continuous)
}

/// Tipografia do 01-UI-SPEC.md (§ Typography) — sempre por estilo semântico do Dynamic
/// Type, nunca por tamanho fixo em pontos. Exatamente 2 pesos (Regular/Semibold) por design;
/// não introduzir Bold como um terceiro peso.
enum JKTypography {
    static let body: Font = .body
    static let label: Font = .footnote
    static let heading: Font = .title3.weight(.semibold)
    static let display: Font = .largeTitle.weight(.semibold)
}

/// Cor do 01-UI-SPEC.md (§ Color) — Fase 1 usa o conjunto neutro. A Fase 9 troca os valores
/// por trás destes mesmos nomes de token pelas variantes rosa/azul-escuro translúcido; até
/// lá, nenhuma view referencia `Color` ou `UIColor`/`NSColor` diretamente.
///
/// `jkScreenBackgroundBase` e `jkCardSurfaceBase` divergem entre iOS e macOS porque
/// `UIColor.systemGroupedBackground`/`.secondarySystemBackground` (as cores exatas citadas
/// no 01-UI-SPEC.md) só existem no UIKit — não há equivalente com esse nome no AppKit. O
/// analógo mais próximo no macOS é `NSColor.windowBackgroundColor` (fundo de tela) e
/// `NSColor.controlBackgroundColor` (superfície de cartão elevada), que resolvem para o
/// mesmo papel visual descrito na tabela Color do UI-SPEC. Isto é o único ponto desta
/// camada de tokens com divergência de plataforma — cada view continua referenciando só o
/// nome do token, nunca a cor concreta.
enum JKColor {
    static let jkAccent = Color.accentColor
    static let jkDestructive = Color.red

    static var jkScreenBackgroundBase: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #elseif os(macOS)
        Color(.windowBackgroundColor)
        #endif
    }

    static var jkCardSurfaceBase: Color {
        #if os(iOS)
        Color(.secondarySystemBackground)
        #elseif os(macOS)
        Color(.controlBackgroundColor)
        #endif
    }
}

/// Cópia pt-BR centralizada (§ Copywriting Contract do 01-UI-SPEC.md). Nenhuma view escreve
/// texto de interface direto — toda string visível ao usuário vem daqui, para não divergir
/// entre telas conforme mais planos acrescentam linhas neste arquivo.
enum JKCopy {
    /// Nome do app, usado como headline de hero na tela de login. O Copywriting Contract não
    /// fixa uma string exata para este momento (só descreve o papel do estilo `display` como
    /// "hero moments only, ... login welcome headline"); esta é a cópia adotada até uma
    /// fase futura de marketing/copy a revisar.
    static let appName = "JK Lar"
    static let loginTagline = "A casa toda em um só lugar."
    static let loginErrorMessage = "Não foi possível entrar. Verifique sua conexão e tente novamente."
    static let loginErrorRetry = "Tentar de novo"

    /// Placeholders mínimos dos dois ramos que o plano 01-05 abre em `RootView`
    /// (`.needsHousehold`/`.inHousehold`) — o onboarding de criar/entrar em casa e a tela da
    /// casa em si são escopo do plano 01-07, que substitui este texto por telas reais.
    static let needsHouseholdPlaceholder = "Vamos formar sua casa — essa tela chega no próximo plano."
    static let inHouseholdPlaceholderPrefix = "Você já está em uma casa: "
}

import Foundation
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
    /// String exata do Copywriting Contract (01-UI-SPEC.md § Copywriting Contract, linha
    /// "Login — Google button") — segundo botão, na ordem Apple → Google → Microsoft (D-01).
    static let loginContinueWithGoogle = "Continuar com o Google"
    /// String exata do Copywriting Contract (linha "Login — Microsoft button") — terceiro
    /// botão.
    static let loginContinueWithMicrosoft = "Continuar com a Microsoft"

    /// Cópia genérica reusável entre contextos ("Tentar de novo" inline) — não listada no
    /// `<files>` do plano 01-07, mas necessária para o gate de grep contra string solta em
    /// `Text(` (ver deviations do plano 01-07).
    static let retryButtonLabel = "Tentar de novo"

    // MARK: - Onboarding (plano 01-07, D-02/D-04)

    static let onboardingToggleCreate = "Criar casa"
    static let onboardingToggleJoin = "Entrar com código"
    static let onboardingCreateHeading = "Criar casa"
    static let onboardingHouseNamePlaceholder = "Nome da casa (ex.: Família Silva)"
    static let onboardingGenderLabel = "Gênero (opcional)"
    static let onboardingGenderFeminino = "Feminino"
    static let onboardingGenderMasculino = "Masculino"
    static let onboardingGenderNaoInformado = "Prefiro não dizer"
    /// Item inicial do seletor de gênero, representando "nenhuma escolha feita ainda"
    /// (`Gender?.none`) — distinto de `onboardingGenderNaoInformado`, que é uma resposta
    /// real enviada ao servidor. Sem essa entrada, o Picker não teria como representar o
    /// estado "opcional, ainda não tocado" (D-04).
    static let onboardingGenderPlaceholder = "Selecionar"
    static let onboardingCreateCTA = "Criar casa"
    static let onboardingCreateGenericError = "Não foi possível concluir. Tente de novo em instantes."
    // MARK: - Entrar com código (plano 01-09, D-02/D-05)

    static let onboardingCodeFieldPlaceholder = "Código de 6 dígitos"
    static let onboardingJoinCTA = "Entrar"
    /// String exata do Copywriting Contract (linha "Onboarding — invalid/expired code
    /// error") — mesma mensagem para `inviteInvalid` e `inviteExpired`, a tela nunca
    /// diferencia os dois motivos (T-09-04).
    static let onboardingInvalidCodeError = "Esse código não é válido ou expirou. Confira com quem te convidou e tente de novo."
    /// String **verbatim** do CONTEXT.md, cobrada por grep no verify da Task 1 — nunca
    /// alterar mesmo por um caractere.
    static let onboardingHouseholdFullError = "Esta casa já atingiu o limite de 10 membros."
    /// Orientação complementar (linha "Onboarding — house-at-capacity error"), exibida
    /// junto da mensagem verbatim acima, nunca concatenada nela.
    static let onboardingHouseholdFullErrorDetail = "Peça pro admin remover alguém ou fale com quem te convidou."

    // MARK: - Household (plano 01-07)

    static let householdSingleMemberHeading = "Você é o único membro por enquanto"
    static let householdSingleMemberBody = "Convide até 9 pessoas pra formar sua casa — toque em Convidar pra gerar um código ou link."
    static let householdLoadErrorMessage = "Não foi possível carregar os membros da casa."
    static let householdUnnamedMember = "Sem nome"

    // MARK: - Convite e lista de membros (plano 01-09, IDENT-04/IDENT-05)

    static let householdInviteCTA = "Convidar"
    /// Cópia de zero-one-many (01-UI-SPEC.md "zero-one-many | member-list") — singular só
    /// no caso de 1 membro; plural cobre 2–10 sem mudar na fronteira de 10.
    static let householdMemberCountSingular = "1 membro"
    static func householdMemberCountPlural(_ count: Int) -> String { "\(count) membros" }

    /// Heading da folha de convite — string exata citada em 01-UI-SPEC.md § Typography
    /// ("Heading → screen/section titles ('Criar casa', 'Convide sua família', ...)").
    static let inviteSheetHeading = "Convide sua família"
    static let inviteSheetShareCTA = "Compartilhar"
    static let inviteSheetLoadErrorMessage = "Não foi possível gerar o convite."
    /// Não faz parte do Copywriting Contract (nenhuma linha fixa a redação de expiração) —
    /// cópia adotada até uma fase futura de marketing/copy a revisar, mesmo raciocínio já
    /// documentado para `JKCopy.appName`/`loginTagline`.
    static func inviteSheetExpiresLabel(_ date: Date) -> String {
        "Expira em \(expiresDateFormatter.string(from: date))"
    }

    private static let expiresDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

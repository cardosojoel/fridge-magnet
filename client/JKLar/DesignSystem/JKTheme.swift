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
    /// Lado da miniatura de foto anexada no compose (plano 02-06) — não fixado pelo
    /// `02-UI-SPEC.md` (só descreve o carrossel publicado, não o tamanho da miniatura em
    /// edição); tamanho adotado por conveniência de leiaute até uma fase futura de
    /// design revisar, mesmo raciocínio já documentado para `JKCopy.appName`.
    static let stagedPhotoThumbnailSize: CGFloat = 96
    /// Largura mínima da folha grande de compose no macOS (02-UI-SPEC.md § Addendum 2, D-13
    /// "Presentation": "macOS ... large `sheet` with a declared minimum content size of
    /// **560×640pt**") — dimensão de componente declarada, mesma categoria de exceção dos
    /// 44pt/56pt/96pt acima, não um valor da escala de espaçamento.
    static let composeSheetMinWidth: CGFloat = 560
    /// Altura mínima da folha grande de compose no macOS — mesma linha do contrato acima
    /// (02-UI-SPEC.md § Addendum 2, D-13 "Presentation", 560×640pt); dimensão de componente
    /// declarada, não valor da escala de espaçamento.
    static let composeSheetMinHeight: CGFloat = 640
    /// Altura mínima do convite de foto do compose sem nenhuma foto anexada (02-UI-SPEC.md §
    /// Addendum 2, D-13 corpo item 1: "minimum height **200pt** (component dimension)") —
    /// dimensão de componente declarada, não valor da escala de espaçamento. Consumido pela
    /// Task 2 do plano 02-13; declarado junto dos irmãos para o arquivo de tokens ser tocado
    /// uma vez só.
    static let composePhotoInviteMinHeight: CGFloat = 200
    /// Altura fixa do trecho de mapa da localização de um recado (02-UI-SPEC.md § Native
    /// Materials, Addendum D-12: "fixed 120pt height") — dimensão de componente declarada,
    /// no molde de `stagedPhotoThumbnailSize`, não valor da escala de espaçamento.
    static let locationPreviewHeight: CGFloat = 120
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
    /// Primeiro botão (D-01, Apple sempre primeiro — App Store Guideline 4.8). O
    /// `SignInWithAppleButton` nativo renderizava o rótulo em inglês ("Continue with Apple"),
    /// inconsistente com os outros dois botões em português; o botão custom que o substituiu
    /// (ver `LoginView.appleRow`) usa esta cópia, no mesmo padrão dos irmãos.
    static let loginContinueWithApple = "Continuar com a Apple"
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
    /// Não é linha do Copywriting Contract (nem o `01-UI-SPEC.md` nem o `02-UI-SPEC.md` fixam
    /// uma cópia própria para "confirmar seleção e fechar a folha") — usado pelo botão de
    /// concluir do `MentionPickerView` (plano 02-06), mesmo raciocínio já documentado para
    /// `JKCopy.appName`/`loginTagline`: cópia genérica reusável, adotada até uma fase futura
    /// de marketing/copy revisar.
    static let doneButtonLabel = "Concluir"

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

    // MARK: - Editar nome de exibição (2026-08-17)
    // A Apple só entrega o nome na primeira autorização do app — quem perde esse momento
    // (primeiro login falhou, app reautorizado) ficaria "Sem nome" para sempre sem um ponto
    // de edição. Vale para os três provedores.

    static let householdEditNameAction = "Editar nome"
    static let householdEditNameTitle = "Como você quer aparecer?"
    static let householdEditNameFieldPlaceholder = "Seu nome"
    static let householdEditNameSaveButton = "Salvar"
    static let householdEditNameError = "Não foi possível salvar o nome. Tente de novo."

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

    // MARK: - Sair da casa / remover membro (plano 01-10, IDENT-06)

    /// Rótulo genérico de cancelamento não-destrutivo, compartilhado pelos dois diálogos
    /// abaixo (01-UI-SPEC.md § Copywriting Contract, "Cancel: 'Cancelar'" em ambas as linhas).
    static let cancelButtonLabel = "Cancelar"

    /// Rótulo da linha destrutiva no rodapé da tela — visível para qualquer papel — e título
    /// do diálogo que ela abre.
    static let householdLeaveRowLabel = "Sair da casa"
    /// String exata do Copywriting Contract (linha "Destructive — 'Sair da casa'").
    static let householdLeaveConfirmMessage = "Sair da casa? Você perde acesso aos recados, agenda e remédios dessa casa até ser convidado de novo."
    static let householdLeaveConfirmButton = "Sair"

    /// Rótulo curto da ação de remover — usado no `swipeActions`/`contextMenu` da linha (o
    /// nome já está na própria linha, não precisa repetir ali) e como botão de confirmação do
    /// diálogo (01-UI-SPEC.md, "Confirm: 'Remover'").
    static let householdRemoveActionLabel = "Remover"
    static let householdRemoveConfirmButton = "Remover"
    /// String exata do Copywriting Contract, com o nome interpolado (linha "Destructive —
    /// 'Remover membro' (admin only)").
    static func householdRemoveConfirmMessage(_ name: String) -> String {
        "Remover \(name) da casa? Essa pessoa perde acesso imediatamente e precisa de um novo convite pra voltar."
    }

    /// String exata do Copywriting Contract (linha "Destructive — last-admin block") —
    /// mostrada inline quando o servidor recusa uma saída/remoção com `lastAdmin`, sem
    /// navegar para fora da tela e sem descartar a lista carregada.
    static let householdLastAdminBlockMessage = "Você é o único admin da casa. Promova outra pessoa a admin antes de sair."

    // MARK: - Primer de notificação (plano 01-12, D-13/D-14)

    /// As quatro linhas exatas do Copywriting Contract (01-UI-SPEC.md, "Notification
    /// primer — heading/body/primary CTA/secondary/dismiss"), mais a linha de
    /// reasseguramento pós-recusa ("Notification primer — post-deny reassurance").
    static let notificationPrimerHeading = "Ative as notificações"
    static let notificationPrimerBody = "Assim você fica sabendo na hora quando alguém te menciona, manda um recado ou é sua vez de tomar remédio."
    static let notificationPrimerPrimaryCTA = "Ativar notificações"
    static let notificationPrimerSecondaryCTA = "Agora não"
    /// D-14: recusar (secundário ou prompt do sistema) nunca bloqueia nada — só reassegura
    /// que dá pra reativar depois, sem insistência.
    static let notificationPrimerReassurance = "Sem problema — você pode ativar isso depois em Ajustes."

    // MARK: - Mural (Fase 2)

    /// Rótulos das duas abas de `RootView.MainTabView` (plano 02-05) — assunção do
    /// planejador (ver `<planner_assumptions>` do plano), não linha do Copywriting Contract
    /// do `02-UI-SPEC.md`, mesma disciplina de `JKCopy.appName`/`loginTagline` acima.
    static let muralTabLabel = "Mural"
    static let householdTabLabel = "Casa"

    /// String exata do Copywriting Contract (linha "Feed screen title").
    static let muralFeedTitle = "Mural"
    /// String exata do Copywriting Contract (linha "Compose entry point (FAB)") — rótulo de
    /// acessibilidade do FAB `plus.circle.fill`, ícone sem texto visível.
    static let muralComposeAccessibilityLabel = "Novo recado"
    /// String exata do Copywriting Contract (linha "Compose sheet title (new)").
    static let muralComposeTitleNew = "Novo recado"
    /// String exata do Copywriting Contract (linha "Compose sheet title (editing)").
    static let muralComposeTitleEditing = "Editar recado"
    /// String exata do Copywriting Contract (linha "Compose text field placeholder").
    static let muralComposeTextPlaceholder = "O que está acontecendo em casa?"
    /// String exata do Copywriting Contract (linha "Compose submit CTA (new)").
    static let muralComposeSubmitCTANew = "Postar"
    /// String exata do Copywriting Contract (linha "Compose submit CTA (editing)").
    static let muralComposeSubmitCTAEditing = "Salvar"
    /// String exata do Copywriting Contract (linha "Compose — add photos button").
    static let muralComposeAddPhotosCTA = "Adicionar fotos"
    /// Contador "{n}/10" mostrado ao lado do botão de adicionar fotos, uma vez que há pelo
    /// menos uma foto marcada (linha "Compose — add photos button").
    static func muralComposePhotoCounter(_ staged: Int) -> String { "\(staged)/10" }
    /// String exata do Copywriting Contract (linha "Compose — photo cap reached").
    static let muralComposePhotoCapReached = "Você já adicionou o máximo de 10 fotos."
    /// String exata do Copywriting Contract (linha "Compose — mention picker trigger") —
    /// reusa `muralMentionPickerTitle`, mesmo texto em dois pontos de entrada distintos
    /// (botão do compose e título da folha), para não declarar o mesmo literal duas vezes.
    static let muralComposeMentionPickerTrigger = muralMentionPickerTitle
    /// String exata do Copywriting Contract (linha "Compose — generic publish error").
    static let muralComposeGenericPublishError = "Não foi possível publicar. Tente de novo em instantes."
    /// String exata do Copywriting Contract (linha "Compose — photo upload partial
    /// failure").
    static let muralComposePhotoUploadPartialFailure = "Uma ou mais fotos não foram enviadas. Tente novamente."
    /// Não é linha própria do Copywriting Contract (a tabela só define a mensagem de falha
    /// parcial acima, não o rótulo por miniatura) — citada em prosa no `02-UI-SPEC.md` §UI
    /// Considerations ("photo-carousel" | error: "'Falha no envio' label"), então o texto é
    /// verbatim dali. Mostrado na sobreposição de retentativa de cada miniatura que falhou.
    static let muralComposePhotoUploadFailedLabel = "Falha no envio"
    /// Não é linha do Copywriting Contract (a tabela do `02-UI-SPEC.md` não cobre o caso de
    /// editar um recado que deixou de ser seu, ex.: sessão trocada) — plano 02-05 Task 3
    /// exige uma mensagem específica para `.apiError(.notAuthor)` na edição, distinta da
    /// genérica de publicação. Cópia adotada até uma fase futura de marketing/copy revisar,
    /// mesmo raciocínio já documentado para `JKCopy.appName`/`loginTagline`.
    static let muralComposeNotAuthorError = "Você não pode mais editar este recado."

    /// String exata do Copywriting Contract (linha "Mention picker sheet title") — também a
    /// cópia do botão que abre a folha (ver `muralComposeMentionPickerTrigger` acima).
    static let muralMentionPickerTitle = "Marcar alguém"
    /// String exata do Copywriting Contract (linha "Mention picker search placeholder").
    static let muralMentionPickerSearchPlaceholder = "Buscar membro"
    /// String exata do Copywriting Contract (linha "Mention picker — only-member state").
    static let muralMentionPickerOnlyMemberState = "Você é o único membro da casa — não há ninguém pra marcar."
    /// String exata do Copywriting Contract (linha "Mention picker — load error") — o
    /// "Tentar de novo" inline reusa `JKCopy.retryButtonLabel`.
    static let muralMentionPickerLoadError = "Não foi possível carregar os membros pra marcar."

    /// String exata do Copywriting Contract (linha "Feed — empty state heading").
    static let muralFeedEmptyHeading = "Ainda não tem recados por aqui"
    /// String exata do Copywriting Contract (linha "Feed — empty state body").
    static let muralFeedEmptyBody = "Seja o primeiro a postar algo pra família ver."
    /// String exata do Copywriting Contract (linha "Feed — load error") — o "Tentar de novo"
    /// inline reusa `JKCopy.retryButtonLabel`.
    static let muralFeedLoadError = "Não foi possível carregar o mural."
    /// String exata do Copywriting Contract (linha "Feed — load-more (pagination) error") —
    /// o "Tentar de novo" inline reusa `JKCopy.retryButtonLabel`.
    static let muralFeedLoadMoreError = "Não foi possível carregar mais recados."

    /// String exata do Copywriting Contract (linha "Recado — long text expand").
    static let muralRecadoExpandText = "ver mais"
    /// Itens do menu de overflow (linha "Recado — own-post overflow menu").
    static let muralRecadoEditAction = "Editar"
    static let muralRecadoDeleteAction = "Apagar"
    /// String exata do Copywriting Contract (linha "Recado — delete confirmation") — o botão
    /// de cancelar reusa `JKCopy.cancelButtonLabel`.
    static let muralRecadoDeleteConfirmMessage = "Apagar este recado? Essa ação não pode ser desfeita."
    static let muralRecadoDeleteConfirmButton = "Apagar"

    /// String exata do Copywriting Contract (linha "Reaction bar — error after failed tap").
    static let muralReactionErrorMessage = "Não foi possível reagir. Tente de novo."

    /// String exata do Copywriting Contract (linha "Comment input placeholder").
    static let muralCommentInputPlaceholder = "Adicionar um comentário..."
    /// String exata do Copywriting Contract (linha "Comment send button") — rótulo de
    /// acessibilidade do botão `paperplane.fill`, ícone sem texto visível.
    static let muralCommentSendAccessibilityLabel = "Enviar comentário"
    /// String exata do Copywriting Contract (linha "Comment — empty state").
    static let muralCommentEmptyState = "Nenhum comentário ainda. Seja o primeiro a comentar."
    /// String exata do Copywriting Contract (linha "Comment — load error") — o "Tentar de
    /// novo" inline reusa `JKCopy.retryButtonLabel`.
    static let muralCommentLoadError = "Não foi possível carregar os comentários."
    /// String exata do Copywriting Contract (linha "Comment — generic post error").
    static let muralCommentGenericPostError = "Não foi possível enviar o comentário. Tente de novo."

    /// String com interpolação (linha "Feed card — comment-count link").
    static func muralFeedCommentCountLink(_ count: Int) -> String { "Ver todos os \(count) comentários" }

    /// Título verbatim do push de @menção (linhas "Push — @mention in recado/comment") —
    /// as duas linhas compartilham o mesmo título.
    static let muralPushMentionTitle = "Você foi mencionado"
    /// Corpo verbatim do push de @menção num recado (linha "Push — @mention in recado").
    static func muralPushMentionInRecadoBody(autor: String, preview: String) -> String {
        "\(autor) marcou você num recado: \"\(preview)\""
    }
    /// Corpo verbatim do push de @menção num comentário (linha "Push — @mention in
    /// comment").
    static func muralPushMentionInCommentBody(autor: String, preview: String) -> String {
        "\(autor) marcou você num comentário: \"\(preview)\""
    }

    // Fixar/arquivar (Adendo 2 do 02-UI-SPEC.md, D-14/D-15, plano 02-12) — mesma seção de
    // mural, mesma disciplina: toda string vem da tabela "Copywriting Contract — Addendum 2".
    // O botão de cancelar do diálogo de arquivar reusa `cancelButtonLabel` e o "Tentar de
    // novo" da tela de arquivados reusa `retryButtonLabel` — nunca duplicatas.

    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — overflow menu:
    /// pin").
    static let muralRecadoPinAction = "Fixar"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — overflow menu:
    /// unpin").
    static let muralRecadoUnpinAction = "Desafixar"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — pinned badge") —
    /// também o rótulo de acessibilidade do selo, por contrato.
    static let muralRecadoPinnedBadgeLabel = "Fixado"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — overflow menu:
    /// archive").
    static let muralRecadoArchiveAction = "Arquivar"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — archive
    /// confirmation") — a cópia diz explicitamente que só o admin desarquiva (D-15).
    static let muralRecadoArchiveConfirmMessage = "Arquivar este recado? Ele sai do mural de todos e só o admin pode desarquivar."
    /// Botão de confirmação da mesma linha do contrato — estilo padrão, nunca destrutivo
    /// (arquivar é recuperável pelo admin; apagar não é).
    static let muralRecadoArchiveConfirmButton = "Arquivar"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Recado — menu-action
    /// error") — UMA string compartilhada por fixar/desafixar/arquivar/desarquivar, exibida
    /// inline no cartão afetado, no mesmo espaço do erro de reação.
    static let muralMenuActionErrorMessage = "Não foi possível concluir a ação. Tente de novo."
    /// String exata do Copywriting Contract — Addendum 2 (linha "Casa — archived row
    /// (admin-only)").
    static let householdArchivedRowLabel = "Arquivados"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Arquivados — screen
    /// title").
    static let muralArchivedTitle = "Arquivados"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Arquivados — empty state
    /// heading").
    static let muralArchivedEmptyHeading = "Nenhum recado arquivado"
    /// String exata do Copywriting Contract — Addendum 2 (linha "Arquivados — empty state
    /// body").
    static let muralArchivedEmptyBody = "Recados arquivados pelo autor ou pelo admin ficam aqui até serem desarquivados."
    /// String exata do Copywriting Contract — Addendum 2 (linha "Arquivados — load error")
    /// — o "Tentar de novo" inline reusa `JKCopy.retryButtonLabel`.
    static let muralArchivedLoadError = "Não foi possível carregar os arquivados."
    /// String exata do Copywriting Contract — Addendum 2 (linha "Arquivados — unarchive
    /// CTA").
    static let muralArchivedUnarchiveCTA = "Desarquivar"

    // Localização do recado (Adendo 1 do 02-UI-SPEC.md, D-12, plano 02-10) — mesma seção
    // de mural, mesma disciplina: toda string vem da tabela do Copywriting Contract.

    /// String exata do Copywriting Contract — Addendum (linha "Compose — add location
    /// button") — o glifo de pino com elipse acompanha o botão, nunca faz parte da string.
    static let muralComposeAddLocationCTA = "Adicionar localização"
    /// String exata do Copywriting Contract — Addendum (linha "Compose — location field,
    /// after a result is picked"): placeholder do campo editável quando ele fica vazio.
    static let muralComposeLocationPlaceholder = "Nome do local (opcional)"
    /// String exata do Copywriting Contract — Addendum (linha "Compose — remove location")
    /// — rótulo de acessibilidade do botão de limpar, ícone sem texto visível; tratamento
    /// neutro, nunca destrutivo (mesmo precedente de remover uma foto anexada).
    static let muralComposeRemoveLocationAccessibilityLabel = "Remover localização"

    /// String exata do Copywriting Contract — Addendum (linha "Location search sheet
    /// title").
    static let muralLocationSearchTitle = "Buscar localização"
    /// String exata do Copywriting Contract — Addendum (linha "Location search field
    /// placeholder") — o glifo de lupa acompanha o campo, nunca faz parte da string.
    static let muralLocationSearchPlaceholder = "Buscar endereço ou local"
    /// String exata do Copywriting Contract — Addendum (linha "Location search — no
    /// results").
    static let muralLocationSearchNoResults = "Nenhum resultado encontrado."
    /// String exata do Copywriting Contract — Addendum (linha "Location search — error") —
    /// exibida inline na folha de busca, tanto para falha do completador quanto para falha
    /// de resolução de uma escolha; a linha do compose nunca mostra estado quebrado.
    static let muralLocationSearchError = "Não foi possível buscar. Tente de novo."

    /// String do Copywriting Contract — Addendum D-11 (linha "Photo — captured-date
    /// caption"): "Tirada em {data}", data pt-BR em formato longo de dia e mês (ex.:
    /// "Tirada em 12 de março"). Renderizada só pelo componente de legenda do design
    /// system, nunca montada em view.
    static func muralPhotoCapturedAtCaption(_ date: Date) -> String {
        "Tirada em \(capturedAtCaptionDateFormatter.string(from: date))"
    }

    /// Formato `d 'de' MMMM` fixado pela mesma linha do contrato; locale pt-BR explícito
    /// para o nome do mês nunca variar com o idioma do aparelho — a cópia deste app é
    /// pt-BR por contrato, não por acaso do ambiente.
    private static let capturedAtCaptionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d 'de' MMMM"
        return formatter
    }()
}

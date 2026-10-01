import FridgeMagnetShared
import MapKit
import SwiftUI

/// Fundo de tela translúcido — `.ultraThinMaterial` sobre `jkScreenBackgroundBase`
/// (01-UI-SPEC.md § Native Materials & Translucency). Toda tela usa este modificador em vez
/// de aplicar Material ad hoc, para a Fase 9 poder injetar um tint/gradiente por trás sem
/// tocar em nenhuma view individual.
private struct FMGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                FMColor.jkScreenBackgroundBase
                    .overlay(.ultraThinMaterial)
                    .ignoresSafeArea()
            )
    }
}

extension View {
    func jkGlassBackground() -> some View {
        modifier(FMGlassBackground())
    }
}

/// Cartão de conteúdo agrupado — `.regularMaterial` + raio de 16 (01-UI-SPEC.md § Native
/// Materials & Translucency). Usado pelo cartão de código de convite, formulário de criar
/// casa e cada linha da lista de membros (planos seguintes).
struct FMCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(FMSpacing.md)
            .background(.regularMaterial, in: FMLayout.cardShape)
    }
}

/// CTA de largura total: fundo `jkAccent`, raio de 12, altura mínima de 44
/// (01-UI-SPEC.md § Native Materials & Translucency, § Spacing Scale exceptions).
struct FMPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FMTypography.body)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: FMLayout.minTapTarget)
            .background(FMColor.jkAccent, in: FMLayout.controlShape)
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

extension ButtonStyle where Self == FMPrimaryButtonStyle {
    static var jkPrimary: FMPrimaryButtonStyle { FMPrimaryButtonStyle() }
}

/// Papel de um membro da casa. Só usado para escolher o SF Symbol de `FMRoleBadge` nesta
/// fatia — o modelo de domínio completo de household chega no plano 01-02/01-07.
enum FMHouseholdRole {
    case admin
    case adult
    case child

    var symbolName: String {
        switch self {
        case .admin: "crown.fill"
        case .adult: "person.fill"
        case .child: "figure.child"
        }
    }

    var label: String {
        switch self {
        case .admin: "Admin"
        case .adult: "Adulto"
        case .child: "Criança"
        }
    }
}

/// Pílula de papel (Admin/Adulto/Criança) sobre `jkCardSurfaceBase`. Deliberadamente sem
/// cor semântica — a diferenciação é só por SF Symbol, para continuar legível em
/// daltonismo (01-UI-SPEC.md § Color, "Explicit non-use").
struct FMRoleBadge: View {
    let role: FMHouseholdRole

    var body: some View {
        Label(role.label, systemImage: role.symbolName)
            .font(FMTypography.label)
            .padding(.horizontal, FMSpacing.sm)
            .padding(.vertical, FMSpacing.xs)
            .background(FMColor.jkCardSurfaceBase, in: Capsule())
    }
}

/// Carrossel paginado de até 10 fotos (D-02, plano 02-06) — usado tanto pelo compose
/// (miniaturas locais recém-anexadas) quanto pelo cartão do feed (fotos remotas). Recebe dado
/// tipado (`Item: Identifiable`) e uma view por item — nenhuma lógica de tela mora aqui, mesmo
/// molde de `FMCard`. `ScrollView`/`scrollTargetBehavior(.paging)` em vez de
/// `TabView(.page)` porque o estilo de página nativo do `TabView` não existe no macOS — este
/// componente precisa funcionar nas duas plataformas com o mesmo código.
///
/// O indicador de pontos só aparece com 2+ itens (com 1 item, imagem única de borda a borda,
/// sem nenhuma marcação de página — 02-UI-SPEC.md § Native Materials/zero-one-many); ponto
/// ativo em `FMColor.jkAccent`, inativos em `.secondary` a 50% de opacidade (constante nomeada
/// abaixo, não um literal solto), sobreposto ao centro-inferior a `FMSpacing.sm` da borda.
struct FMPhotoCarousel<Item: Identifiable, ItemContent: View>: View {
    let items: [Item]
    @ViewBuilder var content: (Item) -> ItemContent

    @State private var scrolledID: Item.ID?

    private static var dotDiameter: CGFloat { 6 }
    private static var inactiveDotOpacity: Double { 0.5 }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    content(item)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrolledID)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                pageIndicator
            }
        }
    }

    private var currentID: Item.ID? {
        scrolledID ?? items.first?.id
    }

    private var pageIndicator: some View {
        HStack(spacing: FMSpacing.xs) {
            ForEach(items) { item in
                Circle()
                    .fill(item.id == currentID ? FMColor.jkAccent : Color.secondary.opacity(Self.inactiveDotOpacity))
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            }
        }
        .padding(.bottom, FMSpacing.sm)
    }
}

/// Pílula de menção `@Nome` — cópia da forma de `FMRoleBadge` trocando o fundo por
/// `FMColor.jkAccent` e renderizando texto em vez de `Label` (01-UI-SPEC.md/02-UI-SPEC.md §
/// Color: único componente novo autorizado a usar accent como fundo). Usado no compose, no
/// texto do recado publicado e no texto de comentário (plano 02-07).
struct FMMentionChip: View {
    let displayName: String

    var body: some View {
        Text("@\(displayName)")
            .font(FMTypography.label)
            .padding(.horizontal, FMSpacing.sm)
            .padding(.vertical, FMSpacing.xs)
            .foregroundStyle(.white)
            .background(FMColor.jkAccent, in: Capsule())
    }
}

/// Fileira de `FMMentionChip` que quebra em várias linhas conforme a largura disponível —
/// usada no compose (chips das menções selecionadas, plano 02-06 Task 2) e no cartão do feed
/// (chips das menções do recado publicado, plano 02-06 Task 3). Quem chama decide se a
/// fileira deve nem renderizar com zero menções (nenhum dos dois pontos de uso mostra a
/// fileira vazia).
struct FMMentionChipRow: View {
    let mentions: [MentionDTO]

    var body: some View {
        FMFlowLayout(spacing: FMSpacing.xs) {
            ForEach(mentions, id: \.userID) { mention in
                FMMentionChip(displayName: mention.displayName ?? FMCopy.householdUnnamedMember)
            }
        }
    }
}

/// `Layout` mínimo de quebra automática — SwiftUI não tem um "wrap HStack" nativo. Usado só
/// por `FMMentionChipRow`; não é um componente de propósito geral do design system.
private struct FMFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Barra de reações de conjunto fechado (D-07/D-07b, plano 02-07) — deriva os 6 botões do
/// `CaseIterable` do enum compartilhado, nunca uma lista escrita à mão, para acrescentar um
/// emoji no futuro ser uma edição do enum e não da view. Glifo sem nenhum estilo de cor aplicado
/// (02-UI-SPEC.md § Color: "o glifo em si nunca recebe estilo de cor") — o botão do
/// `myReaction` ativo recebe fundo `jkAccent` em `Capsule()`, único lugar onde cor entra na
/// barra. A linha de resumo abaixo só é renderizada quando a soma das contagens é > 0
/// (02-UI-SPEC.md "empty | reaction-bar"); numeral simples, sem ramificação de singular/
/// plural ("zero-one-many | reaction-bar").
struct FMReactionBar: View {
    let reactions: [ReactionCountDTO]
    let myReaction: ReactionKind?
    let onTap: (ReactionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FMSpacing.sm) {
            HStack(spacing: FMSpacing.xs) {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    reactionButton(kind)
                }
            }

            if totalCount > 0 {
                summaryRow
            }
        }
    }

    private func reactionButton(_ kind: ReactionKind) -> some View {
        let isActive = myReaction == kind
        return Button {
            onTap(kind)
        } label: {
            Text(kind.glyph)
                .frame(width: FMLayout.minTapTarget, height: FMLayout.minTapTarget)
                .background(isActive ? FMColor.jkAccent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.rawValue)
    }

    private var totalCount: Int {
        reactions.reduce(0) { $0 + $1.count }
    }

    /// Cada emoji presente (contagem > 0) com o numeral ao lado — `FMSpacing.xs` entre glifo
    /// e numeral (§Spacing Scale), destaque `jkAccent` no do próprio requisitante.
    private var summaryRow: some View {
        HStack(spacing: FMSpacing.sm) {
            ForEach(reactions.filter { $0.count > 0 }, id: \.kind) { entry in
                HStack(spacing: FMSpacing.xs) {
                    Text(entry.kind.glyph)
                    Text("\(entry.count)")
                        .font(FMTypography.label)
                        .foregroundStyle(entry.kind == myReaction ? FMColor.jkAccent : Color.secondary)
                }
            }
        }
    }
}

/// Linha de um comentário em lista plana cronológica (D-08, plano 02-07) — avatar (círculo
/// com a inicial, mesmo tratamento da linha de membro da Fase 1), nome, texto com menções
/// inline em `FMMentionChip`, e horário relativo. Altura mínima `FMLayout.memberRowMinHeight`
/// — mesma constante já usada pela lista de membros e pelo seletor de menção, para caber
/// avatar + nome + texto sem violar a área de toque mínima da linha.
struct FMCommentRow: View {
    let comment: CommentDTO

    var body: some View {
        HStack(alignment: .top, spacing: FMSpacing.sm) {
            avatar

            VStack(alignment: .leading, spacing: FMSpacing.xs) {
                HStack(spacing: FMSpacing.xs) {
                    Text(comment.authorDisplayName ?? FMCopy.householdUnnamedMember)
                        .font(FMTypography.body.weight(.semibold))
                        .lineLimit(1)
                    Text(comment.createdAt, style: .relative)
                        .font(FMTypography.label)
                        .foregroundStyle(.secondary)
                }

                Text(comment.text)
                    .font(FMTypography.body)

                if !comment.mentions.isEmpty {
                    FMMentionChipRow(mentions: comment.mentions)
                }
            }
        }
        .frame(minHeight: FMLayout.memberRowMinHeight, alignment: .top)
    }

    private var avatar: some View {
        Circle()
            .fill(FMColor.jkCardSurfaceBase)
            .overlay(
                Text(initial)
                    .font(FMTypography.label.weight(.semibold))
            )
            .frame(width: FMSpacing.xl, height: FMSpacing.xl)
    }

    private var initial: String {
        String((comment.authorDisplayName ?? FMCopy.householdUnnamedMember).prefix(1)).uppercased()
    }
}

/// Esqueleto de carregamento (shimmer) — implementação de `View.jkShimmerPlaceholder(isActive:)`
/// abaixo, no mesmo molde de `FMGlassBackground` (`ViewModifier` privado + `extension View`).
///
/// A Fase 1 desenhou esse shimmer solto direto em `HouseholdView.loadingSkeleton` (3 linhas
/// de `RoundedRectangle` sobre `.regularMaterial`) sem nunca extrair um modificador
/// reutilizável — este modificador existe para o feed do mural (plano 02-05) e uma futura
/// migração da tela da casa não implementarem a mesma animação duas vezes.
///
/// Quando `isActive`: sobrepõe uma pulsação de opacidade sobre `FMColor.jkCardSurfaceBase`
/// no conteúdo redigido (`.redacted(reason: .placeholder)`); uma linha de esqueleto não é
/// conteúdo real, então fica `.accessibilityHidden(true)` para o VoiceOver não a anunciar.
/// Quando inativo, devolve o conteúdo intocado.
private struct FMShimmerPlaceholder: ViewModifier {
    let isActive: Bool
    @State private var isAnimating = false

    /// Duração de um ciclo completo (escurecer + clarear) do pulso de shimmer — constante
    /// nomeada, nunca um literal solto na chamada de `.animation(...)`.
    private static let cycleDuration: TimeInterval = 1.2
    private static let minOpacity: Double = 0.35
    private static let maxOpacity: Double = 0.85

    func body(content: Content) -> some View {
        if isActive {
            content
                .redacted(reason: .placeholder)
                .background(
                    FMLayout.cardShape
                        .fill(FMColor.jkCardSurfaceBase)
                        .opacity(isAnimating ? Self.maxOpacity : Self.minOpacity)
                )
                .accessibilityHidden(true)
                .onAppear { isAnimating = true }
                .animation(
                    .easeInOut(duration: Self.cycleDuration).repeatForever(autoreverses: true),
                    value: isAnimating
                )
        } else {
            content
        }
    }
}

extension View {
    /// Aplica o esqueleto de carregamento (`jkShimmerPlaceholder`) quando `isActive`;
    /// devolve o conteúdo intocado quando não. Usado pelo estado `.loading` do feed do
    /// mural (plano 02-05).
    func jkShimmerPlaceholder(isActive: Bool) -> some View {
        modifier(FMShimmerPlaceholder(isActive: isActive))
    }
}

/// Legenda de data de captura sobre uma foto de carrossel (D-11, plano 02-09) — cápsula de
/// `.ultraThinMaterial` com texto branco no papel de rótulo, renderizada **somente** quando o
/// dia de calendário da captura difere do dia do post (o caso da foto de exame tirada em
/// outro dia); no caso comum — mesmo dia, ou foto sem metadado — a view não desenha nada, e
/// quem usa pode posicionar a legenda incondicionalmente. Branco puro por contrato
/// (02-UI-SPEC.md § Color: sem accent nesta legenda); nenhum token de cor do tema entra.
///
/// Ancoragem: quem usa põe a `FMPhotoDateBadge` em `alignment: .bottomLeading` com recuo de
/// `FMSpacing.sm` dos dois lados — o centro inferior é território do indicador de página do
/// `FMPhotoCarousel`, e sobrepor as duas ancoragens num carrossel de 2+ fotos é o erro
/// esperado aqui.
struct FMPhotoDateBadge: View {
    let capturedAt: Date
    let postedAt: Date

    /// A **única** materialização da regra de D-11 em todo o cliente — os três carrosséis
    /// (compose, cartão do feed, detalhe) chamam este ponto; nenhuma view reimplementa a
    /// comparação de dia. `Calendar.current`: o dia relevante é o do fuso do aparelho.
    static func shouldDisplay(capturedAt: Date, postedAt: Date) -> Bool {
        !Calendar.current.isDate(capturedAt, inSameDayAs: postedAt)
    }

    var body: some View {
        if Self.shouldDisplay(capturedAt: capturedAt, postedAt: postedAt) {
            Text(FMCopy.muralPhotoCapturedAtCaption(capturedAt))
                .font(FMTypography.label)
                .foregroundStyle(.white)
                .padding(.horizontal, FMSpacing.sm)
                .padding(.vertical, FMSpacing.xs)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Trecho de mapa da localização de um recado publicado (D-12, plano 02-10) — recebe
/// latitude e longitude, não o DTO inteiro: um componente do design system não precisa
/// conhecer a forma da DTO de rede. Mapa SwiftUI pós-WWDC23 (inicializadora de posição +
/// construtor de conteúdo com marcador — nunca a inicializadora antiga de região vinculada
/// nem os tipos de anotação depreciados), com altura fixa do token e recorte no raio de
/// **controle** (é um elemento pequeno dentro de um cartão, não um cartão próprio).
///
/// Duas escolhas fixadas pelo 02-UI-SPEC.md § Addendum: a prévia é somente-leitura por
/// decisão — toque e gesto desabilitados, sem nenhum caminho para o app de mapas do sistema
/// neste adendo (arrastar sobre o mapa rola o feed); e a alternativa de imagem estática
/// renderizada e cacheada fica registrada como otimização futura, para quando o volume real
/// de recados com localização justificar (Pitfall 4 do 02-ADDENDUM-RESEARCH.md).
struct FMLocationPreview: View {
    let lat: Double
    let lng: Double

    /// Span da região inicial centrada na coordenada guardada — ~1km de contexto urbano,
    /// valor do exemplo de referência do research; constante nomeada, não literal solto.
    private static let regionSpanDelta: CLLocationDegrees = 0.01

    var body: some View {
        Map(initialPosition: .region(region)) {
            Marker("", coordinate: coordinate)
        }
        .allowsHitTesting(false)
        .frame(height: FMLayout.locationPreviewHeight)
        .clipShape(FMLayout.controlShape)
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: Self.regionSpanDelta, longitudeDelta: Self.regionSpanDelta)
        )
    }
}

/// Linha de compose da localização escolhida (D-12, plano 02-10) — pino preenchido tingido
/// com o token de destaque (§Color do 02-UI-SPEC.md autoriza destaque **exatamente** aqui:
/// seleção confirmada em tempo de compose, mesmo papel do chip de menção), campo de texto
/// editável pré-preenchido com o nome do lugar escolhido, e botão de limpar com o glifo de
/// "x" em círculo em tratamento neutro `.secondary` — mesmo precedente de remover uma foto
/// anexada: é edição desfazível antes de postar, não remoção de dado real; o token
/// destrutivo nunca entra neste componente.
struct FMLocationField: View {
    let text: String
    let onTextChange: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: FMSpacing.sm) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(FMColor.jkAccent)

            TextField(
                FMCopy.muralComposeLocationPlaceholder,
                text: Binding(get: { text }, set: onTextChange)
            )
            .font(FMTypography.body)
            .lineLimit(1)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: FMLayout.minTapTarget, minHeight: FMLayout.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FMCopy.muralComposeRemoveLocationAccessibilityLabel)
        }
    }
}

/// Linha de compose do lembrete escolhido (D-16, plano 02-15) — espelho declarado de
/// `FMLocationField` logo acima, com DUAS diferenças de contrato: o texto é um RESUMO
/// derivado do par (data/hora + antecedência), não editável — não é um rótulo que a
/// pessoa escreve, ao contrário do campo de localização —, e o toque no resumo REABRE a
/// folha de configuração pré-preenchida. Sino preenchido tingido com o token de destaque
/// `jkAccent`: o `02-UI-SPEC.md` § Addendum 3 autoriza **exatamente** este uso novo de
/// destaque neste adendo (seleção confirmada em tempo de compose, mesmo papel do pino de
/// localização). Botão de limpar com "x" em círculo em tratamento neutro `.secondary`,
/// área de toque mínima e rótulo de acessibilidade da tabela de cópia — o tratamento
/// destrutivo nunca entra neste componente: limpar antes de postar é edição desfazível,
/// não remoção de dado real.
struct FMReminderField: View {
    let summary: String
    let onTapSummary: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: FMSpacing.sm) {
            Button(action: onTapSummary) {
                HStack(spacing: FMSpacing.sm) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(FMColor.jkAccent)

                    Text(summary)
                        .font(FMTypography.body)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: FMLayout.minTapTarget, minHeight: FMLayout.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FMCopy.muralComposeRemoveReminderAccessibilityLabel)
        }
    }
}

/// Selo de recado fixado (D-14, plano 02-12) — pílula compacta `pin.fill` + "Fixado", no
/// mesmo molde de `FMRoleBadge`: cápsula sobre `FMColor.jkCardSurfaceBase`, papel
/// tipográfico de rótulo. Foreground **neutro** de propósito: a lista de usos reservados de
/// destaque do `02-UI-SPEC.md` não cresce para isto — o selo é estado só de leitura, não
/// seleção ativa (mesmo precedente da linha de localização publicada do Adendo 1). Rótulo de
/// acessibilidade igual à cópia do selo, por contrato ("the badge reads 'Fixado'").
struct FMPinnedBadge: View {
    var body: some View {
        Label(FMCopy.muralRecadoPinnedBadgeLabel, systemImage: "pin.fill")
            .font(FMTypography.label)
            .padding(.horizontal, FMSpacing.sm)
            .padding(.vertical, FMSpacing.xs)
            .background(FMColor.jkCardSurfaceBase, in: Capsule())
            .accessibilityLabel(FMCopy.muralRecadoPinnedBadgeLabel)
    }
}

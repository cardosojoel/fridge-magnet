import JKLarShared
import SwiftUI

/// Fundo de tela translúcido — `.ultraThinMaterial` sobre `jkScreenBackgroundBase`
/// (01-UI-SPEC.md § Native Materials & Translucency). Toda tela usa este modificador em vez
/// de aplicar Material ad hoc, para a Fase 9 poder injetar um tint/gradiente por trás sem
/// tocar em nenhuma view individual.
private struct JKGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                JKColor.jkScreenBackgroundBase
                    .overlay(.ultraThinMaterial)
                    .ignoresSafeArea()
            )
    }
}

extension View {
    func jkGlassBackground() -> some View {
        modifier(JKGlassBackground())
    }
}

/// Cartão de conteúdo agrupado — `.regularMaterial` + raio de 16 (01-UI-SPEC.md § Native
/// Materials & Translucency). Usado pelo cartão de código de convite, formulário de criar
/// casa e cada linha da lista de membros (planos seguintes).
struct JKCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(JKSpacing.md)
            .background(.regularMaterial, in: JKLayout.cardShape)
    }
}

/// CTA de largura total: fundo `jkAccent`, raio de 12, altura mínima de 44
/// (01-UI-SPEC.md § Native Materials & Translucency, § Spacing Scale exceptions).
struct JKPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JKTypography.body)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            .background(JKColor.jkAccent, in: JKLayout.controlShape)
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

extension ButtonStyle where Self == JKPrimaryButtonStyle {
    static var jkPrimary: JKPrimaryButtonStyle { JKPrimaryButtonStyle() }
}

/// Papel de um membro da casa. Só usado para escolher o SF Symbol de `JKRoleBadge` nesta
/// fatia — o modelo de domínio completo de household chega no plano 01-02/01-07.
enum JKHouseholdRole {
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
struct JKRoleBadge: View {
    let role: JKHouseholdRole

    var body: some View {
        Label(role.label, systemImage: role.symbolName)
            .font(JKTypography.label)
            .padding(.horizontal, JKSpacing.sm)
            .padding(.vertical, JKSpacing.xs)
            .background(JKColor.jkCardSurfaceBase, in: Capsule())
    }
}

/// Carrossel paginado de até 10 fotos (D-02, plano 02-06) — usado tanto pelo compose
/// (miniaturas locais recém-anexadas) quanto pelo cartão do feed (fotos remotas). Recebe dado
/// tipado (`Item: Identifiable`) e uma view por item — nenhuma lógica de tela mora aqui, mesmo
/// molde de `JKCard`. `ScrollView`/`scrollTargetBehavior(.paging)` em vez de
/// `TabView(.page)` porque o estilo de página nativo do `TabView` não existe no macOS — este
/// componente precisa funcionar nas duas plataformas com o mesmo código.
///
/// O indicador de pontos só aparece com 2+ itens (com 1 item, imagem única de borda a borda,
/// sem nenhuma marcação de página — 02-UI-SPEC.md § Native Materials/zero-one-many); ponto
/// ativo em `JKColor.jkAccent`, inativos em `.secondary` a 50% de opacidade (constante nomeada
/// abaixo, não um literal solto), sobreposto ao centro-inferior a `JKSpacing.sm` da borda.
struct JKPhotoCarousel<Item: Identifiable, ItemContent: View>: View {
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
        HStack(spacing: JKSpacing.xs) {
            ForEach(items) { item in
                Circle()
                    .fill(item.id == currentID ? JKColor.jkAccent : Color.secondary.opacity(Self.inactiveDotOpacity))
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            }
        }
        .padding(.bottom, JKSpacing.sm)
    }
}

/// Pílula de menção `@Nome` — cópia da forma de `JKRoleBadge` trocando o fundo por
/// `JKColor.jkAccent` e renderizando texto em vez de `Label` (01-UI-SPEC.md/02-UI-SPEC.md §
/// Color: único componente novo autorizado a usar accent como fundo). Usado no compose, no
/// texto do recado publicado e no texto de comentário (plano 02-07).
struct JKMentionChip: View {
    let displayName: String

    var body: some View {
        Text("@\(displayName)")
            .font(JKTypography.label)
            .padding(.horizontal, JKSpacing.sm)
            .padding(.vertical, JKSpacing.xs)
            .foregroundStyle(.white)
            .background(JKColor.jkAccent, in: Capsule())
    }
}

/// Fileira de `JKMentionChip` que quebra em várias linhas conforme a largura disponível —
/// usada no compose (chips das menções selecionadas, plano 02-06 Task 2) e no cartão do feed
/// (chips das menções do recado publicado, plano 02-06 Task 3). Quem chama decide se a
/// fileira deve nem renderizar com zero menções (nenhum dos dois pontos de uso mostra a
/// fileira vazia).
struct JKMentionChipRow: View {
    let mentions: [MentionDTO]

    var body: some View {
        JKFlowLayout(spacing: JKSpacing.xs) {
            ForEach(mentions, id: \.userID) { mention in
                JKMentionChip(displayName: mention.displayName ?? JKCopy.householdUnnamedMember)
            }
        }
    }
}

/// `Layout` mínimo de quebra automática — SwiftUI não tem um "wrap HStack" nativo. Usado só
/// por `JKMentionChipRow`; não é um componente de propósito geral do design system.
private struct JKFlowLayout: Layout {
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

/// Esqueleto de carregamento (shimmer) — implementação de `View.jkShimmerPlaceholder(isActive:)`
/// abaixo, no mesmo molde de `JKGlassBackground` (`ViewModifier` privado + `extension View`).
///
/// A Fase 1 desenhou esse shimmer solto direto em `HouseholdView.loadingSkeleton` (3 linhas
/// de `RoundedRectangle` sobre `.regularMaterial`) sem nunca extrair um modificador
/// reutilizável — este modificador existe para o feed do mural (plano 02-05) e uma futura
/// migração da tela da casa não implementarem a mesma animação duas vezes.
///
/// Quando `isActive`: sobrepõe uma pulsação de opacidade sobre `JKColor.jkCardSurfaceBase`
/// no conteúdo redigido (`.redacted(reason: .placeholder)`); uma linha de esqueleto não é
/// conteúdo real, então fica `.accessibilityHidden(true)` para o VoiceOver não a anunciar.
/// Quando inativo, devolve o conteúdo intocado.
private struct JKShimmerPlaceholder: ViewModifier {
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
                    JKLayout.cardShape
                        .fill(JKColor.jkCardSurfaceBase)
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
        modifier(JKShimmerPlaceholder(isActive: isActive))
    }
}

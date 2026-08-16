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

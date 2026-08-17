import JKLarShared
import SwiftUI

/// Um recado do feed, envolto em `JKCard` (01-UI-SPEC.md § Native Materials).
///
/// Nesta fatia (plano 02-05, caminho de texto) renderiza: nome do autor + horário relativo,
/// texto com truncagem em ~5 linhas e "ver mais" inline, e o menu de overflow `ellipsis`
/// (Editar/Apagar) mostrado **somente** quando `recado.isMine` — sinal já calculado pelo
/// servidor (D-03), o cliente nunca decide isso comparando nome/posição. O diálogo de
/// confirmação de apagar mora aqui (não no chamador): `onDelete` só é invocado depois que a
/// pessoa confirma no diálogo destrutivo.
///
/// Pontos de extensão nomeados, na ordem do `02-UI-SPEC.md` § Native Materials ("carrossel,
/// texto, chips de menção, barra de reação, prévia dos 2 últimos comentários") — nenhum
/// deles é renderizado por este plano:
/// - Carrossel de fotos (plano 02-04/02-06): entraria acima do texto, edge-to-edge dentro do
///   `JKCard`.
/// - Chips de menção (plano 02-06): entrariam abaixo do texto.
/// - Barra de reação (plano 02-07): entraria abaixo dos chips de menção.
/// - Prévia dos 2 últimos comentários + link "Ver todos os {n} comentários" (plano 02-07):
///   entraria abaixo da barra de reação.
struct RecadoCard: View {
    let recado: RecadoDTO
    var onEdit: (RecadoDTO) -> Void
    var onDelete: (RecadoDTO) -> Void

    @State private var isTextExpanded = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        JKCard {
            VStack(alignment: .leading, spacing: JKSpacing.sm) {
                header

                if let text = recado.text, !text.isEmpty {
                    recadoText(text)
                }

                // MARK: - Ponto de extensão: carrossel de fotos (plano 02-04/02-06)
                // MARK: - Ponto de extensão: chips de menção (plano 02-06)
                // MARK: - Ponto de extensão: barra de reação (plano 02-07)
                // MARK: - Ponto de extensão: prévia dos 2 últimos comentários (plano 02-07)
            }
        }
        .confirmationDialog(
            JKCopy.muralRecadoDeleteAction,
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(JKCopy.muralRecadoDeleteConfirmButton, role: .destructive) {
                onDelete(recado)
            }
            Button(JKCopy.cancelButtonLabel, role: .cancel) {}
        } message: {
            Text(JKCopy.muralRecadoDeleteConfirmMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(recado.authorDisplayName ?? JKCopy.householdUnnamedMember)
                .font(JKTypography.body.weight(.semibold))
                .lineLimit(1)

            Text(recado.createdAt, style: .relative)
                .font(JKTypography.label)
                .foregroundStyle(.secondary)

            Spacer()

            // D-03: o menu de editar/apagar existe SÓ quando `isMine` é verdadeiro — sinal
            // que o servidor já calculou comparando `author_id` com o `sub` do JWT, nunca
            // uma comparação de nome/posição feita aqui.
            if recado.isMine {
                overflowMenu
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                onEdit(recado)
            } label: {
                Label(JKCopy.muralRecadoEditAction, systemImage: "pencil")
            }
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label(JKCopy.muralRecadoDeleteAction, systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: JKLayout.minTapTarget, minHeight: JKLayout.minTapTarget)
                .contentShape(Rectangle())
        }
    }

    private func recadoText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            Text(text)
                .font(JKTypography.body)
                .lineLimit(isTextExpanded ? nil : 5)

            if !isTextExpanded, isLikelyTruncated(text) {
                Button(JKCopy.muralRecadoExpandText) {
                    isTextExpanded = true
                }
                .font(JKTypography.label)
                .foregroundStyle(JKColor.jkAccent)
            }
        }
    }

    /// Heurística de "provavelmente passa de ~5 linhas" — sem medir layout de verdade
    /// (backstop, 02-UI-SPEC.md "long-text | feed (recado text)": "verificado visualmente,
    /// sem teste explícito de contagem de linha definido"). ~40 caracteres por linha é uma
    /// aproximação razoável para `.body` em largura de tela de telefone.
    private func isLikelyTruncated(_ text: String) -> Bool {
        let approxCharsPerLine = 40
        let lineBreaks = text.filter { $0 == "\n" }.count
        return text.count > approxCharsPerLine * 5 || lineBreaks >= 5
    }
}

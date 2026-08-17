import JKLarShared
import SwiftUI

/// `PhotoDownloadDTO` já carrega `id: UUID` (a própria foto) — conformidade aditiva, só do
/// lado do cliente, para o carrossel de foto do design system consumir a lista de URLs
/// diretamente, sem um tipo de wrapper. Nenhum campo novo, nenhuma mudança de comportamento.
extension PhotoDownloadDTO: Identifiable {}

/// `RecadoDTO` já carrega `id: UUID` — conformidade aditiva, só do lado do cliente, para
/// `MuralFeedView` apresentar `RecadoDetailView` com `.sheet(item:)` (plano 02-07 Task 3) em
/// vez de um par `Bool`+recado guardado à parte. Nenhum campo novo, nenhuma mudança de
/// comportamento.
extension RecadoDTO: Identifiable {}

/// Um recado do feed, envolto em `JKCard` (01-UI-SPEC.md § Native Materials).
///
/// Composição completa (planos 02-05/02-06/02-07), nesta ordem — a ordem é contrato do
/// `02-UI-SPEC.md` § Native Materials, não preferência: nome do autor + horário relativo,
/// carrossel de fotos (quando há foto), texto com truncagem em ~5 linhas e "ver mais" inline,
/// chips de menção (quando há menção), barra de reação de conjunto fechado (D-07/D-07b), e
/// prévia dos 2 últimos comentários com link para o detalhe a partir de 3. O menu de overflow
/// `ellipsis` (Editar/Apagar) é mostrado **somente** quando `recado.isMine` — sinal já
/// calculado pelo servidor (D-03), o cliente nunca decide isso comparando nome/posição. O
/// diálogo de confirmação de apagar mora aqui (não no chamador): `onDelete` só é invocado
/// depois que a pessoa confirma no diálogo destrutivo.
struct RecadoCard: View {
    let recado: RecadoDTO
    /// URLs de leitura das fotos deste recado — passadas pela view pai
    /// (`MuralFeedViewModel.photoURLs(for:)`, plano 02-06 Task 3), porque `RecadoCard` não
    /// tem acesso direto ao view model do feed.
    var photoURLs: [PhotoDownloadDTO] = []
    var onEdit: (RecadoDTO) -> Void
    var onDelete: (RecadoDTO) -> Void
    /// Toque num emoji da barra — o chamador (`MuralFeedView`) liga isto a
    /// `viewModel.toggleReaction(recadoID:kind:)`; o cartão em si não fala com a rede.
    var onReact: (ReactionKind) -> Void
    /// Mensagem inline de uma reação que falhou neste recado especificamente — `nil` na
    /// maior parte do tempo; `MuralFeedView` só preenche quando
    /// `viewModel.actionErrorRecadoID == recado.id`, pra uma falha de reação num cartão não
    /// aparecer pendurada embaixo de todos os outros cartões da lista.
    var reactionErrorMessage: String? = nil
    /// Abre `RecadoDetailView` deste recado — único caminho de navegação pra comentários além
    /// da prévia de 2 (02-UI-SPEC.md § Copywriting Contract, "Feed card — comment-count link").
    var onOpenDetail: () -> Void

    @State private var isTextExpanded = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        JKCard {
            VStack(alignment: .leading, spacing: JKSpacing.sm) {
                header

                if !recado.photos.isEmpty {
                    photoCarousel
                }

                if let text = recado.text, !text.isEmpty {
                    recadoText(text)
                }

                if !recado.mentions.isEmpty {
                    JKMentionChipRow(mentions: recado.mentions)
                }

                reactionSection
                    .padding(.top, JKSpacing.md)

                if recado.commentCount > 0 {
                    commentSummarySection
                        .padding(.top, JKSpacing.sm)
                }
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

    /// Barra de reação completa + mensagem de erro inline quando a reação deste cartão
    /// específico falhou — nunca navega, nunca esvazia a lista (mesmo comportamento do
    /// detalhe).
    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            JKReactionBar(reactions: recado.reactions, myReaction: recado.myReaction, onTap: onReact)

            if let reactionErrorMessage {
                Text(reactionErrorMessage)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
            }
        }
    }

    /// De 1 a 2 comentários: só a prévia. A partir de 3: prévia dos 2 mais recentes + o link
    /// de contagem. Tocar em qualquer área do resumo (ou no ícone `bubble.right`) abre o
    /// detalhe — chamado só quando `recado.commentCount > 0` (ver `body`), então esta view
    /// nunca precisa lidar com o caso de zero comentários.
    private var commentSummarySection: some View {
        Button {
            onOpenDetail()
        } label: {
            VStack(alignment: .leading, spacing: JKSpacing.xs) {
                ForEach(recado.latestComments.prefix(2), id: \.id) { comment in
                    JKCommentRow(comment: comment)
                }

                if recado.commentCount >= 3 {
                    HStack(spacing: JKSpacing.xs) {
                        Image(systemName: "bubble.right")
                        Text(JKCopy.muralFeedCommentCountLink(recado.commentCount))
                    }
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkAccent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Carrossel de foto, borda a borda dentro do `JKCard` — cantos superiores herdam o raio
    /// de `JKLayout.cardShape`, inferiores retos onde o texto continua abaixo (02-UI-SPEC.md
    /// § Native Materials). Compensa o `padding(JKSpacing.md)` interno do `JKCard` com padding
    /// negativo nos três lados que tocam a borda superior/laterais, para a imagem chegar até
    /// a borda do cartão. `AsyncImage` com `jkShimmerPlaceholder` enquanto carrega — uma
    /// única foto não mostra pontos de página (o carrossel só desenha o indicador com 2+
    /// itens).
    private var photoCarousel: some View {
        JKPhotoCarousel(items: photoURLs) { photo in
            AsyncImage(url: photo.downloadURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Color.clear.jkShimmerPlaceholder(isActive: true)
                case .failure:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(
            .rect(
                topLeadingRadius: JKLayout.cardCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: JKLayout.cardCornerRadius
            )
        )
        .padding(.top, -JKSpacing.md)
        .padding(.horizontal, -JKSpacing.md)
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

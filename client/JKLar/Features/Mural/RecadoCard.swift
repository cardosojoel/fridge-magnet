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
/// Composição completa (planos 02-05/02-06/02-07/02-12), nesta ordem — a ordem é contrato do
/// `02-UI-SPEC.md` § Native Materials, não preferência: selo de fixado (quando fixado, D-14),
/// nome do autor + horário relativo, carrossel de fotos (quando há foto), texto com truncagem
/// em ~5 linhas e "ver mais" inline, chips de menção (quando há menção), barra de reação de
/// conjunto fechado (D-07/D-07b), e prévia dos 2 últimos comentários com link para o detalhe
/// a partir de 3. O menu de overflow `ellipsis` é mostrado quando há algum item para exibir:
/// o recado é meu (Editar/Apagar, D-03) **ou** algum sinal de permissão calculado no servidor
/// (`canPin`/`canArchive`, D-14/D-15) está verdadeiro — o cliente nunca decide isso comparando
/// papel/nome/posição. Os diálogos de confirmação de apagar e de arquivar moram aqui (não no
/// chamador): `onDelete`/`onArchive` só são invocados depois que a pessoa confirma.
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
    /// Fixar este recado (D-14, plano 02-12) — só chamado quando `recado.canPin` deixou o
    /// item aparecer; a decisão real é do servidor, a cada requisição.
    var onPin: (RecadoDTO) -> Void
    /// Desafixar este recado (D-14) — mesmo contrato de `onPin`.
    var onUnpin: (RecadoDTO) -> Void
    /// Arquivar este recado (D-15) — só invocado DEPOIS da confirmação no diálogo próprio
    /// (estilo padrão, não destrutivo).
    var onArchive: (RecadoDTO) -> Void
    /// Mensagem inline de uma ação que falhou neste recado especificamente — `nil` na maior
    /// parte do tempo; `MuralFeedView` só preenche quando
    /// `viewModel.actionErrorRecadoID == recado.id`, pra uma falha num cartão não aparecer
    /// pendurada embaixo de todos os outros cartões da lista. Nome neutro de propósito
    /// (plano 02-12): o mesmo espaço abaixo da barra recebe tanto o erro de reação quanto o
    /// erro de ação de menu (fixar/desafixar/arquivar) — um nome que dissesse "reação"
    /// mentiria.
    var inlineErrorMessage: String? = nil
    /// Abre `RecadoDetailView` deste recado — único caminho de navegação pra comentários além
    /// da prévia de 2 (02-UI-SPEC.md § Copywriting Contract, "Feed card — comment-count link").
    var onOpenDetail: () -> Void

    @State private var isTextExpanded = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isArchiveConfirmationPresented = false

    var body: some View {
        JKCard {
            VStack(alignment: .leading, spacing: JKSpacing.sm) {
                // Selo de fixado acima do cabeçalho do autor (D-14) — só quando o instante
                // de fixação existe; sem fixação, nada é desenhado (convenção de silêncio
                // na ausência, mesma das fotos e das menções).
                if recado.pinnedAt != nil {
                    JKPinnedBadge()
                }

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
        .confirmationDialog(
            JKCopy.muralRecadoArchiveAction,
            isPresented: $isArchiveConfirmationPresented,
            titleVisibility: .visible
        ) {
            // Deliberadamente SEM papel destrutivo no botão de confirmar (diferença única
            // em relação ao diálogo de apagar acima): arquivar é recuperável (pelo admin),
            // apagar não é — usar o mesmo vermelho para os dois apagaria a distinção
            // justamente no momento em que ela importa (02-UI-SPEC.md § Addendum 2, D-15).
            Button(JKCopy.muralRecadoArchiveConfirmButton) {
                onArchive(recado)
            }
            Button(JKCopy.cancelButtonLabel, role: .cancel) {}
        } message: {
            Text(JKCopy.muralRecadoArchiveConfirmMessage)
        }
    }

    /// Barra de reação completa + mensagem de erro inline quando a reação deste cartão
    /// específico falhou — nunca navega, nunca esvazia a lista (mesmo comportamento do
    /// detalhe).
    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            JKReactionBar(reactions: recado.reactions, myReaction: recado.myReaction, onTap: onReact)

            if let inlineErrorMessage {
                Text(inlineErrorMessage)
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
    /// Data de captura por id de foto (D-11, plano 02-09): o carrossel renderiza a lista de
    /// URLs assinadas (`photoURLs`), que não carrega metadado — `recado.photos` carrega o
    /// `capturedAt` resolvido pelo servidor (plano 02-08), e as duas listas compartilham o
    /// mesmo id de foto. Foto sem entrada no mapa (só um feed inconsistente produziria)
    /// simplesmente não recebe legenda.
    private var capturedAtByPhotoID: [UUID: Date] {
        Dictionary(uniqueKeysWithValues: recado.photos.map { ($0.id, $0.capturedAt) })
    }

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
            // Canto inferior ESQUERDO com recuo de JKSpacing.sm — o centro inferior é dos
            // pontos de página do carrossel; o componente decide sozinho se aparece (só
            // quando o dia de captura difere do dia do post, D-11).
            .overlay(alignment: .bottomLeading) {
                if let capturedAt = capturedAtByPhotoID[photo.id] {
                    JKPhotoDateBadge(capturedAt: capturedAt, postedAt: recado.createdAt)
                        .padding(JKSpacing.sm)
                }
            }
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

            // D-14 amplia a condição de D-03: o menu renderiza quando há ALGUM item para
            // mostrar — o recado é meu (Editar/Apagar) ou algum dos dois sinais de
            // permissão do DTO está verdadeiro (fixar/arquivar). Todos os três sinais são
            // calculados no servidor; nenhuma comparação de papel de membro existe neste
            // arquivo, por desenho (zero-trust) — esconder itens é conveniência, a defesa
            // real é a checagem do handler a cada requisição.
            if recado.isMine || recado.canPin || recado.canArchive {
                overflowMenu
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            // D-03 intacto: Editar continua condicionado à autoria — a ampliação de
            // D-14/D-15 dá ao admin curadoria (fixar/arquivar), nunca edição.
            if recado.isMine {
                Button {
                    onEdit(recado)
                } label: {
                    Label(JKCopy.muralRecadoEditAction, systemImage: "pencil")
                }
            }
            // D-14: item de fixar/desafixar quando o sinal do servidor permite, alternando
            // cópia e glifo conforme o recado já esteja fixado.
            if recado.canPin {
                if recado.pinnedAt == nil {
                    Button {
                        onPin(recado)
                    } label: {
                        Label(JKCopy.muralRecadoPinAction, systemImage: "pin")
                    }
                } else {
                    Button {
                        onUnpin(recado)
                    } label: {
                        Label(JKCopy.muralRecadoUnpinAction, systemImage: "pin.slash")
                    }
                }
            }
            // D-15: arquivar abre o diálogo de confirmação em vez de agir na hora — o
            // diálogo é a rede de segurança de uma ação que só o admin desfaz.
            if recado.canArchive {
                Button {
                    isArchiveConfirmationPresented = true
                } label: {
                    Label(JKCopy.muralRecadoArchiveAction, systemImage: "archivebox")
                }
            }
            // D-03 intacto: Apagar continua só do autor, e o item destrutivo é o último.
            if recado.isMine {
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label(JKCopy.muralRecadoDeleteAction, systemImage: "trash")
                }
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

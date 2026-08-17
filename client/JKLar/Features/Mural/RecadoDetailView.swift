import JKLarShared
import SwiftUI

/// Folha de detalhe do recado (plano 02-07) — cabeçalho (autor, texto, carrossel quando
/// houver), a `JKReactionBar` completa, e a lista plana e cronológica de comentários (D-08)
/// nos quatro estados do `02-UI-SPEC.md`. `.thickMaterial`/`JKLayout.sheetShape`, mesmo
/// precedente visual de `ComposeRecadoView`/`InviteSheet` (Fase 1).
///
/// Entrada de comentário fixa no rodapé: `TextField` + botão `paperplane.fill` (troca para
/// `ProgressView` enquanto `isSubmittingComment`), e o gatilho "Marcar alguém" reusando o
/// seletor estruturado verbatim do plano 02-06 — ver `<planner_assumptions>` do plano 02-07
/// (D-09 exige marcar dentro do comentário; D-06 descarta texto livre).
struct RecadoDetailView: View {
    @State private var viewModel: RecadoDetailViewModel
    @State private var isMentionPickerPresented = false
    @Environment(\.dismiss) private var dismiss

    /// URLs de leitura das fotos deste recado — mesma injeção de `RecadoCard.photoURLs`
    /// (plano 02-06 Task 3): o feed já buscou em lote, a folha não refaz a busca.
    let photoURLs: [PhotoDownloadDTO]

    init(recado: RecadoDTO, photoURLs: [PhotoDownloadDTO] = [], apiClient: APIClient = APIClient()) {
        _viewModel = State(initialValue: RecadoDetailViewModel(recado: recado, apiClient: apiClient))
        self.photoURLs = photoURLs
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: JKSpacing.md) {
                    header

                    if !photoURLs.isEmpty {
                        photoCarousel
                    }

                    if let text = viewModel.recado.text, !text.isEmpty {
                        Text(text)
                            .font(JKTypography.body)
                    }

                    if !viewModel.recado.mentions.isEmpty {
                        JKMentionChipRow(mentions: viewModel.recado.mentions)
                    }

                    reactionSection

                    Divider()

                    commentsSection
                }
                .padding(JKSpacing.lg)
            }

            commentInputBar
        }
        .background(.thickMaterial)
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $isMentionPickerPresented) {
            MentionPickerView(initiallySelected: viewModel.selectedMentions.map(\.userID)) { mentions in
                viewModel.setMentions(mentions)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(viewModel.recado.authorDisplayName ?? JKCopy.householdUnnamedMember)
                .font(JKTypography.body.weight(.semibold))
                .lineLimit(1)
            Text(viewModel.recado.createdAt, style: .relative)
                .font(JKTypography.label)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Mesmo tratamento de `RecadoCard.photoCarousel` (raio único, `aspectRatio(1)`), sem o
    /// padding negativo de borda a borda do cartão do feed — a folha já tem sua própria margem
    /// lateral.
    private var photoCarousel: some View {
        JKPhotoCarousel(items: photoURLs) { photo in
            AsyncImage(url: photo.downloadURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    JKColor.jkCardSurfaceBase
                case .failure:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(JKLayout.cardShape)
    }

    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            JKReactionBar(reactions: viewModel.recado.reactions, myReaction: viewModel.recado.myReaction) { kind in
                Task { await viewModel.toggleReaction(kind: kind) }
            }

            if let actionErrorMessage = viewModel.actionErrorMessage {
                Text(actionErrorMessage)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
            }
        }
    }

    /// Os quatro estados do `02-UI-SPEC.md` "comment-list": carregando (3 `JKCommentRow` com
    /// shimmer), vazio, populado (lista plana, sem cabeçalho de contagem dentro do detalhe —
    /// a contagem só aparece no link de prévia do cartão do feed), erro (preservando a última
    /// lista boa quando houver).
    @ViewBuilder
    private var commentsSection: some View {
        switch viewModel.state {
        case .loading:
            ForEach(0..<3, id: \.self) { _ in
                JKCommentRow(comment: Self.placeholderComment)
                    .jkShimmerPlaceholder(isActive: true)
            }
        case .loaded(let comments):
            if comments.isEmpty {
                Text(JKCopy.muralCommentEmptyState)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comments, id: \.id) { comment in
                    JKCommentRow(comment: comment)
                }
            }
        case .error(let message, let lastGood):
            if let lastGood, !lastGood.isEmpty {
                ForEach(lastGood, id: \.id) { comment in
                    JKCommentRow(comment: comment)
                }
            }
            VStack(spacing: JKSpacing.sm) {
                Text(message)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
                Button(JKCopy.retryButtonLabel) {
                    Task { await viewModel.load() }
                }
                .font(JKTypography.body)
            }
        }
    }

    /// Barra de entrada fixa no rodapé: linha de chips (só quando há seleção), gatilho de
    /// menção, campo de texto (desabilitado durante o envio) e botão de enviar.
    private var commentInputBar: some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            if !viewModel.selectedMentions.isEmpty {
                JKMentionChipRow(mentions: viewModel.selectedMentions)
            }

            HStack(spacing: JKSpacing.sm) {
                mentionTriggerButton

                TextField(JKCopy.muralCommentInputPlaceholder, text: $viewModel.commentText)
                    .font(JKTypography.body)
                    .disabled(viewModel.isSubmittingComment)

                sendButton
            }
        }
        .padding(JKSpacing.md)
        .background(.thickMaterial)
    }

    private var mentionTriggerButton: some View {
        Button {
            isMentionPickerPresented = true
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .frame(minWidth: JKLayout.minTapTarget, minHeight: JKLayout.minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(JKCopy.muralMentionPickerTitle)
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isSubmittingComment {
            ProgressView()
                .frame(width: JKLayout.minTapTarget, height: JKLayout.minTapTarget)
        } else {
            Button {
                Task { await viewModel.submitComment() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: JKLayout.minTapTarget, height: JKLayout.minTapTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.canSubmitComment)
            .accessibilityLabel(JKCopy.muralCommentSendAccessibilityLabel)
        }
    }

    /// Comentário de mentira só pra dar forma ao `JKCommentRow` sob `.redacted(.placeholder)`
    /// — nenhum texto dele chega a ficar visível (o modificador de shimmer aplica
    /// `.accessibilityHidden(true)` e redige o conteúdo), mesma técnica que o feed usa para o
    /// esqueleto de `JKCard`.
    private static let placeholderComment = CommentDTO(
        id: UUID(), authorID: UUID(), authorDisplayName: "Nome",
        text: "Comentário de exemplo", mentions: [], createdAt: Date(), isMine: false
    )
}

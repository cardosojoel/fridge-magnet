import FridgeMagnetShared
import SwiftUI

/// Folha de detalhe do recado (plano 02-07) — cabeçalho (autor, texto, carrossel quando
/// houver), a `FMReactionBar` completa, e a lista plana e cronológica de comentários (D-08)
/// nos quatro estados do `02-UI-SPEC.md`. `.thickMaterial`/`FMLayout.sheetShape`, mesmo
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
                VStack(alignment: .leading, spacing: FMSpacing.md) {
                    header

                    if !photoURLs.isEmpty {
                        photoCarousel
                    }

                    if let text = viewModel.recado.text, !text.isEmpty {
                        Text(text)
                            .font(FMTypography.body)
                    }

                    if !viewModel.recado.mentions.isEmpty {
                        FMMentionChipRow(mentions: viewModel.recado.mentions)
                    }

                    eventSection

                    locationSection

                    reactionSection

                    Divider()

                    commentsSection
                }
                .padding(FMSpacing.lg)
            }

            commentInputBar
        }
        .background(.thickMaterial)
        .presentationCornerRadius(FMLayout.sheetCornerRadius)
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
            Text(viewModel.recado.authorDisplayName ?? FMCopy.householdUnnamedMember)
                .font(FMTypography.body.weight(.semibold))
                .lineLimit(1)
            Text(viewModel.recado.createdAt, style: .relative)
                .font(FMTypography.label)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Data de captura por id de foto (D-11) — mesma derivação trivial de `RecadoCard`
    /// (duplicada só a linha do mapa, nunca a regra de exibição, que mora no componente do
    /// design system): `photoURLs` não carrega metadado, `recado.photos` carrega, e as duas
    /// listas compartilham o id.
    private var capturedAtByPhotoID: [UUID: Date] {
        Dictionary(uniqueKeysWithValues: viewModel.recado.photos.map { ($0.id, $0.capturedAt) })
    }

    /// Mesmo tratamento de `RecadoCard.photoCarousel` (raio único, `aspectRatio(1)`), sem o
    /// padding negativo de borda a borda do cartão do feed — a folha já tem sua própria margem
    /// lateral.
    private var photoCarousel: some View {
        FMPhotoCarousel(items: photoURLs) { photo in
            AsyncImage(url: photo.downloadURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    FMColor.jkCardSurfaceBase
                case .failure:
                    Color.clear
                @unknown default:
                    Color.clear
                }
            }
            .clipped()
            // Inferior esquerdo com recuo de FMSpacing.sm — centro inferior é dos pontos de
            // página; o componente decide sozinho se aparece (D-11).
            .overlay(alignment: .bottomLeading) {
                if let capturedAt = capturedAtByPhotoID[photo.id] {
                    FMPhotoDateBadge(capturedAt: capturedAt, postedAt: viewModel.recado.createdAt)
                        .padding(FMSpacing.sm)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(FMLayout.cardShape)
    }

    /// Linha de evento do lembrete (D-16, plano 02-15) — a MESMA linha do cartão do feed,
    /// na mesma posição relativa (entre os chips de menção e a localização), com o mesmo
    /// texto e sem nenhuma afordância a mais: o contrato diz explicitamente que a linha é
    /// idêntica nos dois lugares, e tocar nela não faz nada. A duplicação aceita é a
    /// mesma já declarada para a localização logo abaixo: a composição de duas linhas se
    /// repete, a regra de formatação não — ela mora na função de cópia da linha de evento
    /// em `FMCopy`.
    @ViewBuilder
    private var eventSection: some View {
        if let eventAt = viewModel.recado.eventAt,
           let offsetSeconds = viewModel.recado.remindOffsetSeconds,
           let offset = ReminderOffset(rawValue: offsetSeconds) {
            HStack(alignment: .firstTextBaseline, spacing: FMSpacing.xs) {
                Image(systemName: "bell.fill")
                Text(FMCopy.muralRecadoEventRow(eventAt: eventAt, offset: offset))
                    .lineLimit(2)
            }
            .font(FMTypography.label)
            .foregroundStyle(.secondary)
        }
    }

    /// Mesma composição de dois elementos do cartão do feed (D-12, plano 02-10), na mesma
    /// posição relativa — depois do carrossel e do texto, antes da barra de reação. A
    /// duplicação aceita é só esta composição de duas linhas: a decisão de cor neutra e a
    /// altura fixa moram no componente do design system e no token, nunca aqui.
    @ViewBuilder
    private var locationSection: some View {
        if let location = viewModel.recado.location {
            VStack(alignment: .leading, spacing: FMSpacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: FMSpacing.xs) {
                    Image(systemName: "mappin.circle.fill")
                    Text(location.text)
                        .lineLimit(2)
                }
                .font(FMTypography.label)
                .foregroundStyle(.secondary)

                FMLocationPreview(lat: location.lat, lng: location.lng)
            }
        }
    }

    private var reactionSection: some View {
        VStack(alignment: .leading, spacing: FMSpacing.xs) {
            FMReactionBar(reactions: viewModel.recado.reactions, myReaction: viewModel.recado.myReaction) { kind in
                Task { await viewModel.toggleReaction(kind: kind) }
            }

            if let actionErrorMessage = viewModel.actionErrorMessage {
                Text(actionErrorMessage)
                    .font(FMTypography.label)
                    .foregroundStyle(FMColor.jkDestructive)
            }
        }
    }

    /// Os quatro estados do `02-UI-SPEC.md` "comment-list": carregando (3 `FMCommentRow` com
    /// shimmer), vazio, populado (lista plana, sem cabeçalho de contagem dentro do detalhe —
    /// a contagem só aparece no link de prévia do cartão do feed), erro (preservando a última
    /// lista boa quando houver).
    @ViewBuilder
    private var commentsSection: some View {
        switch viewModel.state {
        case .loading:
            ForEach(0..<3, id: \.self) { _ in
                FMCommentRow(comment: Self.placeholderComment)
                    .jkShimmerPlaceholder(isActive: true)
            }
        case .loaded(let comments):
            if comments.isEmpty {
                Text(FMCopy.muralCommentEmptyState)
                    .font(FMTypography.label)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(comments, id: \.id) { comment in
                    FMCommentRow(comment: comment)
                }
            }
        case .error(let message, let lastGood):
            if let lastGood, !lastGood.isEmpty {
                ForEach(lastGood, id: \.id) { comment in
                    FMCommentRow(comment: comment)
                }
            }
            VStack(spacing: FMSpacing.sm) {
                Text(message)
                    .font(FMTypography.label)
                    .foregroundStyle(FMColor.jkDestructive)
                Button(FMCopy.retryButtonLabel) {
                    Task { await viewModel.load() }
                }
                .font(FMTypography.body)
            }
        }
    }

    /// Barra de entrada fixa no rodapé: linha de chips (só quando há seleção), gatilho de
    /// menção, campo de texto (desabilitado durante o envio) e botão de enviar.
    private var commentInputBar: some View {
        VStack(alignment: .leading, spacing: FMSpacing.xs) {
            if !viewModel.selectedMentions.isEmpty {
                FMMentionChipRow(mentions: viewModel.selectedMentions)
            }

            HStack(spacing: FMSpacing.sm) {
                mentionTriggerButton

                TextField(FMCopy.muralCommentInputPlaceholder, text: $viewModel.commentText)
                    .font(FMTypography.body)
                    .disabled(viewModel.isSubmittingComment)

                sendButton
            }
        }
        .padding(FMSpacing.md)
        .background(.thickMaterial)
    }

    private var mentionTriggerButton: some View {
        Button {
            isMentionPickerPresented = true
        } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .frame(minWidth: FMLayout.minTapTarget, minHeight: FMLayout.minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(FMCopy.muralMentionPickerTitle)
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isSubmittingComment {
            ProgressView()
                .frame(width: FMLayout.minTapTarget, height: FMLayout.minTapTarget)
        } else {
            Button {
                Task { await viewModel.submitComment() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: FMLayout.minTapTarget, height: FMLayout.minTapTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.canSubmitComment)
            .accessibilityLabel(FMCopy.muralCommentSendAccessibilityLabel)
        }
    }

    /// Comentário de mentira só pra dar forma ao `FMCommentRow` sob `.redacted(.placeholder)`
    /// — nenhum texto dele chega a ficar visível (o modificador de shimmer aplica
    /// `.accessibilityHidden(true)` e redige o conteúdo), mesma técnica que o feed usa para o
    /// esqueleto de `FMCard`.
    private static let placeholderComment = CommentDTO(
        id: UUID(), authorID: UUID(), authorDisplayName: "Nome",
        text: "Comentário de exemplo", mentions: [], createdAt: Date(), isMine: false
    )
}

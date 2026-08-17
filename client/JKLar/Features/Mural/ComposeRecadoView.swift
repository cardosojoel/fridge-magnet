import JKLarShared
import PhotosUI
import SwiftUI

#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Folha de compose no caminho de texto + fotos + menção — apresentada por `MuralFeedView` a
/// partir do FAB (modo novo) ou do item "Editar" do menu de overflow de `RecadoCard` (modo
/// edição).
///
/// `.thickMaterial` + `JKLayout.sheetShape`, mesmo precedente visual de `InviteSheet` (Fase
/// 1). Plano 02-06 Task 2 preenche os dois pontos de extensão que o plano 02-05 deixou
/// marcados: botão de adicionar fotos (`PhotosPicker`, framework `PhotosUI` nativo — **não**
/// exige `NSPhotoLibraryUsageDescription` porque o seletor roda fora do processo do app) com
/// contador/teto/estado por miniatura, e o gatilho do seletor de menção com a linha de chips.
struct ComposeRecadoView: View {
    @State private var viewModel: ComposeRecadoViewModel
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    @State private var isMentionPickerPresented = false
    @Environment(\.dismiss) private var dismiss

    /// Chamado com o `RecadoDTO` criado/atualizado depois de um `submit()` bem-sucedido —
    /// quem apresenta a folha decide o que fazer (inserir no topo do feed, recarregar). A
    /// folha só se fecha sozinha quando `submit()` não deixou nenhum `errorMessage` — uma
    /// falha parcial de envio de foto mantém a folha aberta, com a miniatura afetada e a
    /// retentativa visíveis (D-01: a publicação já aconteceu com as fotos que deram certo,
    /// mas a pessoa precisa continuar vendo o sinal de falha, não ser jogada de volta pro
    /// feed como se nada tivesse acontecido).
    let onSuccess: (RecadoDTO) -> Void

    init(
        mode: ComposeRecadoViewModel.Mode,
        initialText: String = "",
        onSuccess: @escaping (RecadoDTO) -> Void
    ) {
        _viewModel = State(initialValue: ComposeRecadoViewModel(mode: mode, initialText: initialText))
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JKSpacing.lg) {
            Text(title)
                .font(JKTypography.heading)

            // `axis: .vertical` + `lineLimit(1...10)`: o campo cresce com o texto e passa a
            // rolar internamente depois de ~10 linhas visíveis, para a folha não crescer sem
            // limite (02-UI-SPEC.md § Copywriting Contract, "Compose text field placeholder").
            TextField(JKCopy.muralComposeTextPlaceholder, text: $viewModel.text, axis: .vertical)
                .font(JKTypography.body)
                .lineLimit(1...10)
                .disabled(viewModel.isSubmitting)

            photoSection

            mentionSection

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(JKTypography.label)
                    .foregroundStyle(JKColor.jkDestructive)
            }

            submitButton

            Button(JKCopy.cancelButtonLabel) {
                dismiss()
            }
            .disabled(viewModel.isSubmitting)
            .frame(maxWidth: .infinity)
        }
        .padding(JKSpacing.lg)
        .background(.thickMaterial)
        .presentationCornerRadius(JKLayout.sheetCornerRadius)
        .sheet(isPresented: $isMentionPickerPresented) {
            MentionPickerView(initiallySelected: viewModel.selectedMentions.map(\.userID)) { mentions in
                viewModel.setMentions(mentions)
            }
        }
    }

    // MARK: - Fotos (plano 02-06 Task 1/2)

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.sm) {
            if viewModel.stagedPhotos.isEmpty {
                addPhotosButton
                    .padding(.vertical, JKSpacing.xl)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: JKSpacing.sm) {
                        ForEach(viewModel.stagedPhotos) { photo in
                            stagedPhotoThumbnail(photo)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                HStack(spacing: JKSpacing.sm) {
                    addPhotosButton
                    Text(viewModel.stagedPhotoCounterLabel)
                        .font(JKTypography.label)
                        .foregroundStyle(.secondary)
                }
            }

            if let photoCapMessage = viewModel.photoCapMessage {
                Text(photoCapMessage)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addPhotosButton: some View {
        PhotosPicker(
            selection: $photoPickerSelection,
            maxSelectionCount: max(0, ComposeRecadoViewModel.maxPhotos - viewModel.stagedPhotos.count),
            matching: .images
        ) {
            Label(JKCopy.muralComposeAddPhotosCTA, systemImage: "photo.badge.plus")
        }
        .disabled(!viewModel.canAddMorePhotos)
        .onChange(of: photoPickerSelection) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                let inputs = await Self.loadStagedPhotoInputs(from: newItems)
                viewModel.addPhotos(inputs)
                photoPickerSelection = []
            }
        }
    }

    /// Carrega os bytes de cada item selecionado e detecta o `Content-Type` real pelos bytes
    /// (via `ImageIO`, mesmo em iOS/macOS) — nunca confia numa extensão de arquivo, que o
    /// seletor nem sempre expõe. Item cujo carregamento falha é descartado em silêncio (a
    /// pessoa pode selecionar de novo); nenhum estado quebrado chega a `addPhotos`.
    private static func loadStagedPhotoInputs(from items: [PhotosPickerItem]) async -> [ComposeRecadoViewModel.StagedPhotoInput] {
        var inputs: [ComposeRecadoViewModel.StagedPhotoInput] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            inputs.append(.init(data: data, contentType: detectedContentType(for: data)))
        }
        return inputs
    }

    private static func detectedContentType(for data: Data) -> String {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let utTypeIdentifier = CGImageSourceGetType(source) as String?,
            let mimeType = UTType(utTypeIdentifier)?.preferredMIMEType
        else {
            return "image/jpeg"
        }
        return mimeType
    }

    private func stagedPhotoThumbnail(_ photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            thumbnailImage(for: photo)
                .frame(width: JKLayout.stagedPhotoThumbnailSize, height: JKLayout.stagedPhotoThumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: JKLayout.controlCornerRadius, style: .continuous))
                .overlay {
                    stagedPhotoStateOverlay(photo)
                }

            removeStagedPhotoButton(photo)
        }
    }

    @ViewBuilder
    private func thumbnailImage(for photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        #if os(iOS)
        if let uiImage = UIImage(data: photo.data) {
            Image(uiImage: uiImage).resizable().scaledToFill()
        } else {
            Color(.secondarySystemBackground)
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: photo.data) {
            Image(nsImage: nsImage).resizable().scaledToFill()
        } else {
            Color(.controlBackgroundColor)
        }
        #endif
    }

    /// `pending`/`uploading` mostram progresso na própria miniatura (as três etapas de envio
    /// — presign, PUT, confirm — nunca deixam a pessoa sem sinal); `failed` mostra ícone de
    /// retentativa + o rótulo de falha, ligado a `retryUpload(photoID:)`; `uploaded` não
    /// sobrepõe nada.
    @ViewBuilder
    private func stagedPhotoStateOverlay(_ photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        switch photo.uploadState {
        case .pending, .uploading:
            Color.black.opacity(0.35)
            ProgressView()
                .tint(.white)
        case .failed:
            Color.black.opacity(0.35)
            Button {
                Task { await viewModel.retryUpload(photoID: photo.id) }
            } label: {
                VStack(spacing: JKSpacing.xs) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                    Text(JKCopy.muralComposePhotoUploadFailedLabel)
                        .font(JKTypography.label)
                }
                .foregroundStyle(.white)
            }
        case .uploaded:
            EmptyView()
        }
    }

    /// `xmark.circle.fill` em `.secondary` — remover uma foto ainda não publicada é uma
    /// edição desfazível, nunca a remoção de dado real (§Color, "não destrutivo"). Área
    /// tocável de `JKLayout.minTapTarget` mesmo sobre uma miniatura menor.
    private func removeStagedPhotoButton(_ photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        Button {
            viewModel.removePhoto(id: photo.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(minWidth: JKLayout.minTapTarget, minHeight: JKLayout.minTapTarget)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Menção (plano 02-06 Task 2)

    @ViewBuilder
    private var mentionSection: some View {
        Button {
            isMentionPickerPresented = true
        } label: {
            Label(JKCopy.muralComposeMentionPickerTrigger, systemImage: "person.crop.circle.badge.plus")
        }

        if !viewModel.selectedMentions.isEmpty {
            JKMentionChipRow(mentions: viewModel.selectedMentions)
        }
    }

    private var submitButton: some View {
        Button {
            Task {
                await viewModel.submit { recado in
                    onSuccess(recado)
                }
                if viewModel.errorMessage == nil {
                    dismiss()
                }
            }
        } label: {
            if viewModel.isSubmitting {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: JKLayout.minTapTarget)
            } else {
                Text(ctaLabel)
            }
        }
        .buttonStyle(.jkPrimary)
        .disabled(!viewModel.canSubmit)
    }

    private var title: String {
        switch viewModel.mode {
        case .new: JKCopy.muralComposeTitleNew
        case .editing: JKCopy.muralComposeTitleEditing
        }
    }

    private var ctaLabel: String {
        switch viewModel.mode {
        case .new: JKCopy.muralComposeSubmitCTANew
        case .editing: JKCopy.muralComposeSubmitCTAEditing
        }
    }
}

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

/// Tela cheia de compose estilo Instagram (D-13, plano 02-13) — apresentada por
/// `MuralFeedView` a partir do FAB (modo novo) ou do item "Editar" do menu de overflow de
/// `RecadoCard` (modo edição): `fullScreenCover` no iOS, folha grande de dimensões mínimas
/// declaradas no macOS (onde `fullScreenCover` não existe no framework).
///
/// Fundo de tela do app (o mesmo modificador de vidro translúcido do feed), nunca material
/// de folha — a Supersessão item 1 do Addendum 2 do `02-UI-SPEC.md` aposentou o material
/// espesso + arredondamento de folha da versão compacta. A tela inteira rola como uma coisa
/// só; as folhas aninhadas (seletor de
/// menção) mantêm o material de folha que já tinham. Seleção de fotos via `PhotosPicker`
/// (framework `PhotosUI` nativo — **não** exige `NSPhotoLibraryUsageDescription` porque o
/// seletor roda fora do processo do app), com contador/teto/estado por foto (plano 02-06).
struct ComposeRecadoView: View {
    @State private var viewModel: ComposeRecadoViewModel
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    @State private var isMentionPickerPresented = false
    @State private var isLocationSearchPresented = false
    @State private var isReminderConfigPresented = false
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
        initialLocation: RecadoLocationDTO? = nil,
        initialReminder: ComposeRecadoViewModel.SelectedReminder? = nil,
        onSuccess: @escaping (RecadoDTO) -> Void
    ) {
        _viewModel = State(initialValue: ComposeRecadoViewModel(
            mode: mode, initialText: initialText, initialLocation: initialLocation,
            initialReminder: initialReminder
        ))
        self.onSuccess = onSuccess
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // A tela inteira rola como uma coisa só — nenhum elemento interno tem rolagem
            // própria (02-UI-SPEC.md § Addendum 2, Supersessão item 3). Enquanto o envio está
            // em voo, o formulário inteiro desabilita; o sinal de progresso mora na posição de
            // enviar da barra superior.
            ScrollView {
                VStack(alignment: .leading, spacing: JKSpacing.lg) {
                    photoSection

                    // Sem nenhum modificador de limite de linhas — nem mínimo, nem máximo: o
                    // campo cresce com o texto e quem rola é a tela (D-13; a remoção do antigo
                    // teto de ~10 linhas é a Supersessão item 3, a causa literal do "muito
                    // travada" do dogfooding).
                    TextField(JKCopy.muralComposeTextPlaceholder, text: $viewModel.text, axis: .vertical)
                        .font(JKTypography.body)

                    optionRows

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(JKTypography.label)
                            .foregroundStyle(JKColor.jkDestructive)
                    }
                }
                .padding(JKSpacing.lg)
            }
            .disabled(viewModel.isSubmitting)
        }
        .jkGlassBackground()
        #if os(macOS)
        // A tela é quem sabe de quanto espaço precisa (plano 02-13 <planner_assumptions>
        // item 1): as dimensões mínimas da folha grande de macOS vêm dos tokens do contrato
        // (02-UI-SPEC.md § Addendum 2, D-13 "Presentation").
        .frame(
            minWidth: JKLayout.composeSheetMinWidth,
            minHeight: JKLayout.composeSheetMinHeight
        )
        #endif
        .sheet(isPresented: $isMentionPickerPresented) {
            // Folha aninhada mantém o material e o arredondamento de folha que já tem — a
            // supersessão de apresentação vale para o compose, não para as folhas que nascem
            // dele (02-UI-SPEC.md § Addendum 2, Supersessão item 1).
            MentionPickerView(initiallySelected: viewModel.selectedMentions.map(\.userID)) { mentions in
                viewModel.setMentions(mentions)
            }
        }
        .sheet(isPresented: $isLocationSearchPresented) {
            // Folha de busca de localização (D-12, plano 02-10) — aninhada do mesmo jeito
            // que a folha de menção acima; o retorno é o lugar resolvido (nome editável +
            // coordenada instantânea da escolha).
            LocationSearchView { resolved in
                viewModel.setLocation(name: resolved.name, lat: resolved.lat, lng: resolved.lng)
            }
        }
        .sheet(isPresented: $isReminderConfigPresented) {
            // Folha de configuração do lembrete (D-16, plano 02-15) — aninhada ao lado
            // das duas acima (as três convivem; nenhuma vira a outra). Abre pré-preenchida
            // quando já há lembrete escolhido; sem lembrete, os padrões de abertura do
            // contrato moram na própria folha.
            ReminderConfigView(
                initialEventAt: viewModel.selectedReminder?.eventAt,
                initialOffset: viewModel.selectedReminder.flatMap { ReminderOffset(rawValue: $0.remindOffsetSeconds) }
            ) { eventAt, offset in
                viewModel.setReminder(eventAt: eventAt, remindOffsetSeconds: offset.rawValue)
            }
        }
        .task {
            // Leitura do estado de autorizacao na entrada da tela — liga o aviso
            // discreto SÓ quando negado neste aparelho (D-16).
            await viewModel.refreshNotificationAuthorizationState()
        }
    }

    // MARK: - Barra superior (D-13)

    /// Três posições (02-UI-SPEC.md § Addendum 2, D-13 "Top bar"): cancelar à esquerda em
    /// texto simples sem cor de destaque — continua fechando na hora, sem diálogo de descarte
    /// (backstop consciente do contrato: a tela cheia do iOS já remove o fechamento por
    /// gesto, então o risco de perda acidental é menor, não maior); título no centro no papel
    /// de cabeçalho; enviar à direita em texto na cor de destaque (o mesmo uso reservado de
    /// destaque de antes, relocado da folha para a barra — não um uso novo).
    private var topBar: some View {
        ZStack {
            Text(title)
                .font(JKTypography.heading)

            HStack {
                Button(JKCopy.cancelButtonLabel) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(JKTypography.body)
                .disabled(viewModel.isSubmitting)

                Spacer()

                submitButton
            }
        }
        .padding(JKSpacing.md)
    }

    /// A regra de habilitação é **exatamente** `viewModel.canSubmit`, sem nenhuma condição
    /// extra escrita aqui (T-02-77). Enquanto o envio está em voo, esta posição vira um
    /// indicador de progresso inline. A tela só se fecha sozinha quando `submit()` não deixou
    /// nenhum `errorMessage` — uma falha parcial de envio de foto mantém a tela aberta, com
    /// as fotos falhadas e sua retentativa visíveis (D-01), mesmo comportamento da versão em
    /// folha.
    @ViewBuilder
    private var submitButton: some View {
        if viewModel.isSubmitting {
            ProgressView()
        } else {
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
                Text(ctaLabel)
                    .font(JKTypography.body.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(JKColor.jkAccent)
            .disabled(!viewModel.canSubmit)
        }
    }

    // MARK: - Fotos (plano 02-06 Task 1/2; reapresentadas pelo plano 02-13 Task 2)

    /// Fotos lideram o compose (a inversão do Instagram — D-13 corpo item 1): sem nenhuma
    /// foto, o convite grande de largura inteira É o próprio seletor de fotos; com fotos, o
    /// carrossel quadrado de largura inteira no lugar da antiga tira de miniaturas
    /// (Supersessão item 4). O `onChange` da seleção mora aqui, uma vez só — o seletor tem
    /// dois rótulos possíveis (convite grande / linha compacta) e o carregamento dos bytes
    /// não pode rodar em dobro.
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.sm) {
            if viewModel.stagedPhotos.isEmpty {
                photoInvite
            } else {
                stagedPhotoCarousel

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
        .onChange(of: photoPickerSelection) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                let inputs = await Self.loadStagedPhotoInputs(from: newItems)
                viewModel.addPhotos(inputs)
                photoPickerSelection = []
            }
        }
    }

    /// Convite grande sem nenhuma foto anexada: glifo de foto com sinal de mais mais a cópia
    /// de adicionar fotos (papel de corpo, tom secundário), centrados sobre a cor de
    /// superfície de cartão com o arredondamento de controle e a altura mínima declarada
    /// pelo contrato. É o rótulo do próprio seletor de fotos — não um botão separado que
    /// abre um seletor (D-13 corpo item 1); substitui o antigo espaçamento vertical extra em
    /// volta do botão de adicionar (Supersessão item 2).
    private var photoInvite: some View {
        PhotosPicker(
            selection: $photoPickerSelection,
            maxSelectionCount: max(0, ComposeRecadoViewModel.maxPhotos - viewModel.stagedPhotos.count),
            matching: .images
        ) {
            VStack(spacing: JKSpacing.sm) {
                Image(systemName: "photo.badge.plus")
                    .font(JKTypography.heading)
                Text(JKCopy.muralComposeAddPhotosCTA)
                    .font(JKTypography.body)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: JKLayout.composePhotoInviteMinHeight)
            .background(JKColor.jkCardSurfaceBase, in: JKLayout.controlShape)
            .contentShape(JKLayout.controlShape)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canAddMorePhotos)
    }

    /// Linha compacta de adicionar mais fotos + contador, mostrada logo abaixo do carrossel
    /// quando já há fotos anexadas — mesmas cópias e mesma regra de sempre (o seletor
    /// desabilita ao chegar no teto de dez). A escuta da seleção mora em `photoSection`.
    private var addPhotosButton: some View {
        PhotosPicker(
            selection: $photoPickerSelection,
            maxSelectionCount: max(0, ComposeRecadoViewModel.maxPhotos - viewModel.stagedPhotos.count),
            matching: .images
        ) {
            Label(JKCopy.muralComposeAddPhotosCTA, systemImage: "photo.badge.plus")
        }
        .disabled(!viewModel.canAddMorePhotos)
    }

    /// Carrega os bytes de cada item selecionado e lê os dois metadados — o `Content-Type`
    /// real e a data de captura EXIF (D-11) — dos mesmos bytes já carregados, numa única
    /// chamada de `loadTransferable` por item; nunca confia numa extensão de arquivo, que o
    /// seletor nem sempre expõe. Item cujo carregamento falha é descartado em silêncio (a
    /// pessoa pode selecionar de novo); nenhum estado quebrado chega a `addPhotos`.
    private static func loadStagedPhotoInputs(from items: [PhotosPickerItem]) async -> [ComposeRecadoViewModel.StagedPhotoInput] {
        var inputs: [ComposeRecadoViewModel.StagedPhotoInput] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            inputs.append(.init(
                data: data,
                contentType: PhotoMetadataReader.contentType(for: data),
                capturedAt: PhotoMetadataReader.capturedAt(for: data)
            ))
        }
        return inputs
    }

    /// Carrossel quadrado de largura inteira das fotos anexadas — o mesmo componente e a
    /// mesma proporção (1:1) que o cartão do feed já usa (`RecadoCard.photoCarousel`), uma
    /// página por foto; o indicador de pontos só aparece com 2+ itens, regra do próprio
    /// componente. Cantos no arredondamento de controle (aqui não há o cartão do feed em
    /// volta para herdar raio).
    private var stagedPhotoCarousel: some View {
        JKPhotoCarousel(items: viewModel.stagedPhotos) { photo in
            stagedPhotoPage(photo)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(JKLayout.controlShape)
    }

    /// Uma página do carrossel: a imagem dos bytes já carregados (mesma ramificação por
    /// plataforma da antiga miniatura — movida, não reescrita), com a sobreposição de estado
    /// de envio da página e o botão de remover no canto superior direito. Esta sobreposição é
    /// o único sinal de que uma foto falhou (T-02-79) — sem ela, uma foto falhada ficaria
    /// idêntica a uma enviada e a pessoa publicaria achando que anexou o que não anexou.
    private func stagedPhotoPage(_ photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            thumbnailImage(for: photo)
                .clipped()
                .overlay {
                    stagedPhotoStateOverlay(photo)
                }
                // Legenda de data de captura (D-11, plano 02-09) no canto inferior ESQUERDO
                // com recuo de JKSpacing.sm — o centro inferior é dos pontos de página e o
                // superior direito é do estado de envio/remover: as três não competem. A
                // publicação ainda não aconteceu, então "hoje" é o dia iminente do post; o
                // componente decide sozinho se aparece (só quando o dia difere).
                .overlay(alignment: .bottomLeading) {
                    if let capturedAt = photo.capturedAt {
                        JKPhotoDateBadge(capturedAt: capturedAt, postedAt: Date())
                            .padding(JKSpacing.sm)
                    }
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

    /// Os quatro estados de envio por foto, preservados verbatim como sobreposição da página
    /// do carrossel (antes, da miniatura): `pending`/`uploading` escurecem e mostram
    /// progresso — o mesmo desenho nos dois, em ramos separados de propósito, um por estado
    /// (as três etapas de envio — presign, PUT, confirm — nunca deixam a pessoa sem sinal);
    /// `failed` mostra ícone de retentativa + o rótulo de falha, ligado ao método de
    /// retentativa por foto do view-model; `uploaded` não sobrepõe nada.
    @ViewBuilder
    private func stagedPhotoStateOverlay(_ photo: ComposeRecadoViewModel.StagedPhoto) -> some View {
        switch photo.uploadState {
        case .pending:
            Color.black.opacity(0.35)
            ProgressView()
                .tint(.white)
        case .uploading:
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
    /// tocável de `JKLayout.minTapTarget`, no canto superior direito de cada página do
    /// carrossel.
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

    // MARK: - Linhas de opção (D-13, corpo item 3)

    /// Cada opção do compose é uma linha própria de largura inteira abaixo da legenda, com
    /// `JKSpacing.md` entre elas (02-UI-SPEC.md § Addendum 2, D-13 corpo item 3).
    private var optionRows: some View {
        VStack(alignment: .leading, spacing: JKSpacing.md) {
            mentionSection

            // Linha de localização (D-12, plano 02-10) — imediatamente abaixo da linha de
            // marcar alguém, na posição que o plano 02-13 reservou (02-UI-SPEC.md §
            // Addendum 2, D-13 corpo item 3, "Reserved extension point").
            locationSection

            // Linha de lembrete (D-16, plano 02-15) — a ÚLTIMA do bloco, imediatamente
            // depois da localização: a posição é contrato (menção → localização →
            // lembrete), não preferência.
            reminderSection
        }
    }

    // MARK: - Localização (plano 02-10, D-12)

    /// Dois estados (02-UI-SPEC.md § Addendum, D-12 item 1): sem localização, só o botão de
    /// adicionar (mesmo formato de `Label` do gatilho de menção — nenhuma linha de campo);
    /// com localização, o campo do design system com pino de destaque, rótulo editável e
    /// limpar neutro, ligado às mutações do view-model.
    @ViewBuilder
    private var locationSection: some View {
        if let location = viewModel.selectedLocation {
            JKLocationField(
                text: location.text,
                onTextChange: { viewModel.updateLocationText($0) },
                onClear: { viewModel.clearLocation() }
            )
        } else {
            Button {
                isLocationSearchPresented = true
            } label: {
                Label(JKCopy.muralComposeAddLocationCTA, systemImage: "mappin.and.ellipse")
            }
        }
    }

    // MARK: - Lembrete (plano 02-15, D-16)

    /// Dois estados, espelhando exatamente a seção de localização acima: sem lembrete, um
    /// botão com glifo de sino e a cópia de adicionar; com lembrete, o campo do design
    /// system ligado às mutações do view-model, com o toque no resumo reabrindo a folha
    /// pré-preenchida. Logo abaixo do campo, e só quando existirem: o aviso de
    /// notificações desativadas e a dica de combinação inválida — os dois no papel de
    /// rótulo em tom secundário, nunca no tratamento destrutivo (são informação e
    /// orientação, não erro de publicação; o recado salva igual).
    @ViewBuilder
    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: JKSpacing.xs) {
            if let reminder = viewModel.selectedReminder,
               let offset = ReminderOffset(rawValue: reminder.remindOffsetSeconds) {
                JKReminderField(
                    summary: JKCopy.muralComposeReminderSummary(eventAt: reminder.eventAt, offset: offset),
                    onTapSummary: { isReminderConfigPresented = true },
                    onClear: { viewModel.clearReminder() }
                )
            } else {
                Button {
                    isReminderConfigPresented = true
                } label: {
                    Label(JKCopy.muralComposeAddReminderCTA, systemImage: "bell")
                }
            }

            if viewModel.selectedReminder != nil, viewModel.isNotificationsDenied {
                Text(JKCopy.muralComposeReminderNotificationsOffNotice)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            }

            if let hint = viewModel.reminderInvalidHint {
                Text(hint)
                    .font(JKTypography.label)
                    .foregroundStyle(.secondary)
            }
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

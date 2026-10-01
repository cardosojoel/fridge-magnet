import FridgeMagnetShared
import SwiftUI

/// Folha aninhada de configuração do lembrete (D-16, plano 02-15) — mesmo molde visual de
/// `LocationSearchView` (material espesso, raio de canto de folha, título no papel de
/// cabeçalho, padding do espaçamento grande, retorno por closure), com UMA diferença
/// declarada pelo contrato: altura de folha **média** por detente, porque o conteúdo são
/// dois controles e não uma lista. Cancelar é o gesto nativo da folha — folhas aninhadas
/// mantêm o fechamento por gesto; só a tela de compose o perdeu (plano 02-13).
///
/// O passado é inselecionável no próprio controle de data (`in: Date.now...`), não apenas
/// recusado depois. A combinação cujo disparo (evento − antecedência) cairia no passado
/// bloqueia no CTA com a dica visível — e não desabilitando itens do menu: estado mais
/// simples, e a dica explica o MOTIVO, coisa que um item acinzentado não faz (decisão do
/// `02-UI-SPEC.md` § Addendum 3, item 4).
struct ReminderConfigView: View {
    @State private var eventAt: Date
    @State private var offset: ReminderOffset
    @Environment(\.dismiss) private var dismiss

    /// Chamado só por "Concluir", com a combinação já válida — devolve o par ao compose;
    /// o dismiss por gesto não devolve nada.
    let onConfirm: (Date, ReminderOffset) -> Void

    /// Valores de abertura do contrato: sem lembrete anterior, a **próxima hora cheia** e
    /// a antecedência padrão ("15 min antes"); com lembrete anterior, os valores
    /// guardados.
    init(
        initialEventAt: Date? = nil,
        initialOffset: ReminderOffset? = nil,
        onConfirm: @escaping (Date, ReminderOffset) -> Void
    ) {
        _eventAt = State(initialValue: initialEventAt ?? Self.nextFullHour(after: Date()))
        _offset = State(initialValue: initialOffset ?? .fifteenMinutes)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            Text(FMCopy.muralReminderSheetTitle)
                .font(FMTypography.heading)

            DatePicker(
                FMCopy.muralReminderEventPickerLabel,
                selection: $eventAt,
                in: Date.now...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .font(FMTypography.body)

            // As seis opções vêm do conjunto fechado do pacote compartilhado, na ordem de
            // declaração — nunca seis literais na folha. Menu, não segmentado: seis
            // opções não cabem num controle segmentado na largura de um telefone.
            Picker(FMCopy.muralReminderOffsetPickerLabel, selection: $offset) {
                ForEach(ReminderOffset.allCases, id: \.self) { option in
                    Text(FMCopy.muralReminderOffsetLabel(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(FMTypography.body)

            if !isCombinationValid {
                Text(FMCopy.muralComposeReminderInvalidHint)
                    .font(FMTypography.label)
                    .foregroundStyle(.secondary)
            }

            Button(FMCopy.doneButtonLabel) {
                onConfirm(eventAt, offset)
                dismiss()
            }
            .buttonStyle(.jkPrimary)
            .disabled(!isCombinationValid)
        }
        .padding(FMSpacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thickMaterial)
        .presentationCornerRadius(FMLayout.sheetCornerRadius)
        .presentationDetents([.medium])
    }

    /// O disparo calculado (evento − antecedência) precisa estar no futuro — o CTA
    /// desabilita exatamente enquanto a dica está visível.
    private var isCombinationValid: Bool {
        eventAt.addingTimeInterval(-TimeInterval(offset.rawValue)) > Date()
    }

    /// A próxima hora cheia a partir do instante de referência — o valor de abertura do
    /// seletor quando não há lembrete anterior.
    static func nextFullHour(after reference: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: reference)
        guard let flooredHour = calendar.date(from: components),
              let next = calendar.date(byAdding: .hour, value: 1, to: flooredHour) else {
            return reference
        }
        return next
    }
}

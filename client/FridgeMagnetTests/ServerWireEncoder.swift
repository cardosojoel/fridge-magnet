import Foundation

/// Encoder que espelha o formato de fio do servidor real — datas em ISO8601, o padrão do
/// `ContentConfiguration` do Vapor 4 (`JSONEncoder.custom(dates: .iso8601)`).
///
/// Todo fixture de teste que simula uma RESPOSTA do servidor deve ser codificado por aqui,
/// nunca por `JSONEncoder()` cru: com o encoder cru, o fixture e o decoder do `APIClient`
/// usavam o mesmo default da Foundation (data como número) e o round-trip passava — mas
/// contra o Vapor real qualquer DTO com `Date` falhava em decodificar. Foi exatamente esse
/// furo que derrubou a lista de membros e o feed no primeiro login real (2026-08-17); este
/// helper existe para os testes nunca mais validarem um contrato que o servidor não fala.
enum ServerWire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

import Foundation

/// Gera códigos de convite de 6 caracteres (D-05) por um gerador criptograficamente seguro
/// — nunca um valor semeado por relógio nem uma sequência derivada de id, que são o vetor
/// documentado em 01-RESEARCH.md "Don't Hand-Roll > Invite code generation" (T-06-01).
///
/// Alfabeto de 31 caracteres, sem `0`, `O`, `1`, `I` e `L` — os cinco que a família vai
/// confundir ao digitar um código a partir de papel.
///
/// Unicidade não é responsabilidade deste tipo: é garantida pelo índice único da coluna
/// `code`; quem chama `generate()` trata uma colisão no INSERT gerando de novo, nunca
/// sobrescrevendo a linha existente (`HouseholdController.createInvite`).
enum InviteCodeGenerator {
    static let alphabet: [Character] = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let codeLength = 6

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        var characters: [Character] = []
        characters.reserveCapacity(codeLength)
        for _ in 0..<codeLength {
            guard let character = alphabet.randomElement(using: &generator) else {
                preconditionFailure("alphabet nunca pode estar vazio")
            }
            characters.append(character)
        }
        return String(characters)
    }
}

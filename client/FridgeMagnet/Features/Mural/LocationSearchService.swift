import Foundation
import MapKit
import Observation

/// Lugar resolvido a partir de uma escolha na busca de endereço (D-12, plano 02-10) — tipo
/// de fronteira **interna** do cliente: a conversão para o DTO de request do backend acontece
/// no view-model do compose, nunca aqui, para este arquivo não conhecer a forma de request
/// da rede.
struct ResolvedLocation: Sendable, Equatable {
    let name: String
    let lat: Double
    let lng: Double
}

/// Erro tipado da resolução de uma escolha de busca — no molde de `PhotoUploadError`: quem
/// trata compara caso de enum, nunca string de mensagem.
enum LocationSearchError: Error, Equatable {
    case noResults
}

/// Costura de protocolo da resolução "escolha de busca → coordenada". Existe por um motivo
/// único e explícito: sem ela, a resolução de coordenada só existe contra a infraestrutura
/// real de mapas da Apple e a asserção "escolher um resultado preenche o estado do compose"
/// fica sem teste — a lacuna de Wave 0 que o `02-ADDENDUM-RESEARCH.md` nomeia, e o mesmo
/// raciocínio que separou `PhotoUploadTransport` do `APIClient`. Isolada ao ator principal:
/// toda resolução nasce de um toque de interface e alimenta estado de view.
@MainActor
protocol LocalSearchResolving: Sendable {
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation
}

/// Implementação real sobre a busca local do MapKit: resolve a completion escolhida num
/// item de mapa e devolve nome (com recuo para o título da completion quando o item não tem
/// nome) mais a coordenada do posicionamento. Resultado vazio lança o erro tipado de "sem
/// resultado" — nunca devolve coordenada zero.
struct MapKitLocalSearchResolver: LocalSearchResolving {
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation {
        let request = MKLocalSearch.Request(completion: completion)
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw LocationSearchError.noResults
        }
        let coordinate = item.placemark.coordinate
        return ResolvedLocation(
            name: item.name ?? completion.title,
            lat: coordinate.latitude,
            lng: coordinate.longitude
        )
    }
}

/// Busca de endereço por texto digitado (D-12, plano 02-10) — invólucro `@Observable` sobre
/// o completador de busca local do MapKit (API de delegado, não async/await), publicando
/// resultados e erro para SwiftUI observar direto, no mesmo molde de bridging de
/// `ComposeRecadoViewModel` (02-ADDENDUM-RESEARCH.md, Pattern 1).
@Observable
@MainActor
final class LocationSearchService: NSObject, MKLocalSearchCompleterDelegate {
    /// Interno (não privado) de propósito: os casos de teste exercitam os métodos de
    /// delegado passando o próprio completador do serviço — não é preciso rede real para
    /// provar a publicação de estado.
    let completer: MKLocalSearchCompleter

    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var errorMessage: String?

    private let resolver: LocalSearchResolving

    init(resolver: LocalSearchResolving = MapKitLocalSearchResolver()) {
        self.resolver = resolver
        self.completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Decisão de ausência: a propriedade de região de viés do completador fica SEM
        // definição, de propósito. Defini-la a partir da posição corrente do aparelho
        // arrastaria, em cadeia, um gerenciador de posição, um pedido de autorização em
        // tempo de execução e uma string de uso nova no Info.plist — nada disso é
        // necessário para o caso de D-12, que é digitar um endereço conhecido, não
        // descobrir o que há por perto. A busca é por texto digitado, nunca enviesada.
    }

    /// Repassa o fragmento digitado ao completador e limpa o estado de erro — cada nova
    /// consulta parte limpa; os resultados chegam pelo método de delegado abaixo.
    func updateQuery(_ fragment: String) {
        errorMessage = nil
        completer.queryFragment = fragment
    }

    /// Resolve a completion escolhida em nome + coordenada, delegando ao resolvedor
    /// injetado (costura testável por duplo).
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation {
        try await resolver.resolve(completion)
    }

    // MARK: - Delegado do completador
    //
    // O completador documenta a entrega dos callbacks de delegado na fila principal —
    // `MainActor.assumeIsolated` reentra no ator de forma síncrona (e falha alto, em vez de
    // corromper estado em silêncio, se esse contrato de plataforma um dia mudar). Um salto
    // assíncrono aqui não compila no modo estrito do Swift 6: o completador não é `Sendable`
    // e não pode ser capturado por uma tarefa que cruza isolamento — por isso os fechamentos
    // abaixo capturam só `self` (classe isolada ao ator principal, logo `Sendable`) e leem o
    // próprio completador do serviço, que é o mesmo objeto que o parâmetro entrega.

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.results = self.completer.results
            self.errorMessage = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            // A cópia vem de FMCopy, nunca da mensagem crua do erro; a lista fica como
            // estava — a área de resultados continua presente, vazia ou não.
            self.errorMessage = FMCopy.muralLocationSearchError
        }
    }
}

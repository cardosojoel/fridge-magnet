import MapKit
import XCTest
@testable import FridgeMagnet

/// Resolvedor falso configurável (plano 02-10 Task 1) — a costura `LocalSearchResolving`
/// exercitada por um duplo de verdade, não só declarada: sem ela, a resolução de coordenada
/// só existiria contra a infraestrutura real da Apple e a asserção "escolher um resultado
/// produz nome + coordenada" ficaria sem teste (lacuna de Wave 0 do 02-ADDENDUM-RESEARCH.md).
private struct FakeLocalSearchResolver: LocalSearchResolving {
    enum Outcome {
        case place(ResolvedLocation)
        case noResults
    }

    let outcome: Outcome

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> ResolvedLocation {
        switch outcome {
        case .place(let place): return place
        case .noResults: throw LocationSearchError.noResults
        }
    }
}

private struct FakeSearchFailure: Error {}

@MainActor
final class LocationSearchServiceTests: XCTestCase {
    // MARK: updateQuery(_:)

    func testUpdateQueryForwardsFragmentToCompleterAndClearsError() {
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .noResults))
        // Provoca um erro primeiro, pelo próprio método de delegado de falha.
        sut.completer(sut.completer, didFailWithError: FakeSearchFailure())
        XCTAssertNotNil(sut.errorMessage, "pré-condição: a falha do completador publicou erro")

        sut.updateQuery("Avenida Paulista")

        XCTAssertEqual(sut.completer.queryFragment, "Avenida Paulista", "o fragmento é repassado ao completador")
        XCTAssertNil(sut.errorMessage, "cada nova consulta limpa o estado de erro")
    }

    // MARK: Delegado — atualização de resultados

    func testCompleterDidUpdateResultsPublishesReceivedListAndKeepsErrorNil() {
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .noResults))
        sut.completer(sut.completer, didFailWithError: FakeSearchFailure())
        XCTAssertNotNil(sut.errorMessage, "pré-condição: erro publicado antes da atualização")

        sut.completerDidUpdateResults(sut.completer)

        XCTAssertEqual(sut.results, sut.completer.results, "a lista publicada é exatamente a do completador")
        XCTAssertNil(sut.errorMessage, "uma atualização de resultados deixa o estado de erro nulo")
    }

    // MARK: Delegado — falha

    func testCompleterFailurePublishesSearchErrorCopyAndLeavesResultsAsTheyWere() {
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .noResults))
        let resultsBefore = sut.results

        sut.completer(sut.completer, didFailWithError: FakeSearchFailure())

        XCTAssertEqual(sut.errorMessage, FMCopy.muralLocationSearchError, "a cópia de erro vem de FMCopy, nunca da mensagem crua do erro")
        XCTAssertEqual(sut.results, resultsBefore, "a falha não esvazia a lista — a área de lista continua presente, como estava")
    }

    // MARK: resolve(_:) — costura de protocolo

    func testResolveThroughFakeResolverReturningPlaceProducesNameLatLng() async throws {
        let place = ResolvedLocation(name: "Consultório Dra. Ana", lat: -23.561414, lng: -46.655881)
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .place(place)))

        let resolved = try await sut.resolve(MKLocalSearchCompletion())

        XCTAssertEqual(resolved.name, "Consultório Dra. Ana")
        XCTAssertEqual(resolved.lat, -23.561414)
        XCTAssertEqual(resolved.lng, -46.655881)
    }

    func testResolveThroughFakeResolverWithoutPlaceThrowsTypedNoResults() async {
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .noResults))

        do {
            _ = try await sut.resolve(MKLocalSearchCompletion())
            XCTFail("esperava LocationSearchError.noResults")
        } catch let error as LocationSearchError {
            XCTAssertEqual(error, .noResults, "erro tipado, nunca comparação de string de mensagem")
        } catch {
            XCTFail("erro inesperado: \(error)")
        }

        XCTAssertNil(sut.errorMessage, "uma falha de resolução não publica estado de erro de busca no serviço")
        XCTAssertTrue(sut.results.isEmpty, "nenhum estado inconsistente é publicado")
    }

    // MARK: Ausência de viés por posição do aparelho

    func testCompleterRegionIsNeverNarrowedByDevicePosition() {
        let sut = LocationSearchService(resolver: FakeLocalSearchResolver(outcome: .noResults))

        // A região padrão do completador abrange o mundo inteiro (documentação da Apple) —
        // qualquer estreitamento a partir da posição do aparelho reduziria este span e
        // arrastaria, em cadeia, um pedido de permissão que D-12 não precisa. O gate de
        // aceitação do plano confirma por grep que a propriedade nunca é atribuída; este
        // caso prova o mesmo fato em tempo de execução.
        XCTAssertGreaterThan(sut.completer.region.span.latitudeDelta, 90, "região padrão de mundo inteiro — nunca enviesada")
    }
}

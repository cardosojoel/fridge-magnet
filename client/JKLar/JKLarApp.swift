import SwiftUI

/// Ponto de entrada único do app multiplataforma (iOS + macOS Tahoe).
///
/// Uma só `WindowGroup`, uma só cena — não existe divergência de lifecycle entre as duas
/// plataformas nesta fatia. `RootView` é o roteador de estado injetado aqui; qualquer
/// divergência real de plataforma (ex.: HealthKit, que não existe no macOS) vai morar em
/// `#if os(iOS)` dentro de arquivos específicos, nunca em uma segunda cena ou target.
@main
struct JKLarApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

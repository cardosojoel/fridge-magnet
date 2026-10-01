// swift-tools-version:6.0
import PackageDescription

// Pacote SPM local `FridgeMagnetShared` — contrato de API (DTOs Codable+Sendable) compartilhado
// entre o cliente SwiftUI (client/) e o backend Vapor (backend/). Ver SKELETON.md
// "Modelos compartilhados": retrofit depois significaria mexer em todo DTO das 10 fases.
let package = Package(
    name: "FridgeMagnetShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FridgeMagnetShared", targets: ["FridgeMagnetShared"])
    ],
    targets: [
        .target(name: "FridgeMagnetShared")
    ]
)

// swift-tools-version:6.0
import PackageDescription

// Backend Vapor do JK Lar. Todas as dependências abaixo constam como "OK / Approved" na
// tabela "Package Legitimacy Audit" de 01-RESEARCH.md (orgs oficiais vapor/vapor,
// vapor/fluent, vapor/fluent-postgres-driver, vapor/jwt, vapor/apns) — nenhum checkpoint de
// legitimidade exigido. Versões pinadas em `from:` na tag major corrente verificada nas
// páginas de releases em 2026-08-16 (vapor 4.122.0, fluent 4.13.0,
// fluent-postgres-driver 2.12.0, jwt 5.1.2, apns 5.0.0). `swift-server-community/APNSwift`
// (identidade `apnswift`) e `swift-crypto` já são dependências transitivas de `vapor/apns` —
// declarados aqui de novo, de propósito, só para expor os produtos `APNS`/`APNSCore`/`Crypto`
// diretamente ao target `App` (que fala com `app.apns` e monta a chave `.p8` em
// `configure.swift`/`Push/`), sem depender de visibilidade transitiva "por acaso".
let package = Package(
    name: "App",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.2"),
        .package(url: "https://github.com/vapor/apns.git", from: "5.0.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "6.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(path: "../Shared"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "APNS", package: "apnswift"),
                .product(name: "APNSCore", package: "apnswift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "JKLarShared", package: "Shared"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [] }

// swift-tools-version:6.0
import PackageDescription

// Backend Vapor do JK Lar. Todas as dependências abaixo constam como "OK / Approved" na
// tabela "Package Legitimacy Audit" de 01-RESEARCH.md (orgs oficiais vapor/vapor,
// vapor/fluent, vapor/fluent-postgres-driver, vapor/jwt) — nenhum checkpoint de
// legitimidade exigido. Versões pinadas em `from:` na tag major corrente verificada nas
// páginas de releases em 2026-08-16 (vapor 4.122.0, fluent 4.13.0,
// fluent-postgres-driver 2.12.0, jwt 5.1.2).
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

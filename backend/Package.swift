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
//
// `soto-project/soto` (produto de acesso a S3 abaixo, único da lista de dependências deste
// pacote) — único pacote externo novo do plano 02-04 (armazenamento de foto em Cloudflare R2,
// via API S3). Não coberto pela checagem automática de legitimidade (`package-legitimacy
// check` não cobre SPM, ver 02-RESEARCH.md §Package Legitimacy Audit) — auditoria manual: org
// dedicada `soto-project`, ~9 anos, 100+ releases, Apache 2.0, 11 repos irmãos (`soto-core`,
// `soto-codegenerator`, etc.), badge de maturidade "graduated" da Swift Server Working Group.
// Aprovado no `checkpoint:human-verify` da Task 2 do plano 02-04 (re-verificado ao vivo em
// 2026-08-17, tag `v7.15.0` confirmada como a mais recente). Só o target `App` depende desse
// produto — nunca entra no bundle do cliente.

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
        .package(url: "https://github.com/soto-project/soto.git", from: "7.15.0"),
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
                .product(name: "SotoS3", package: "soto"),
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

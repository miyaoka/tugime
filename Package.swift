// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "tugime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TugimeCore", targets: ["TugimeCore"]),
        .executable(name: "tugime-cli", targets: ["tugime-cli"]),
    ],
    dependencies: [
        // 1.0 まではマイナー版でも破壊的変更があるため revision で固定する
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            revision: "04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a"
        ),
    ],
    targets: [
        .target(
            name: "TugimeCore",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "tugime-cli",
            dependencies: ["TugimeCore"]
        ),
        .testTarget(
            name: "TugimeCoreTests",
            dependencies: ["TugimeCore"]
        ),
    ]
)

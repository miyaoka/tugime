// swift-tools-version: 6.2

import PackageDescription

// AzooKey の Zenzai（ニューラルの変換モデル）は C++ の llama.cpp を使うので、その型を見るターゲットはすべて C++ の相互運用を有効にする
let cxx: SwiftSetting = .interoperabilityMode(.Cxx)

let package = Package(
    name: "tugime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TugimeCore", targets: ["TugimeCore"]),
        .executable(name: "tugime-cli", targets: ["tugime-cli"]),
        .executable(name: "tugime", targets: ["TugimeIME"]),
    ],
    dependencies: [
        // 1.0 まではマイナー版でも破壊的変更があるため revision で固定する
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            revision: "04ce2ec3afe2bd6f92fcae1dc15a2357d332c27a",
            traits: ["Zenzai"]
        ),
    ],
    targets: [
        .target(
            name: "TugimeCore",
            dependencies: [
                .product(name: "KanaKanjiConverterModuleWithDefaultDictionary", package: "AzooKeyKanaKanjiConverter"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: [cxx]
        ),
        .executableTarget(
            name: "tugime-cli",
            dependencies: ["TugimeCore"],
            swiftSettings: [cxx]
        ),
        .executableTarget(
            name: "TugimeIME",
            dependencies: ["TugimeCore"],
            // 入力メソッドの呼び出しはすべてメインスレッドで届くので、既定の隔離をメインアクターにする（SE-0466）
            swiftSettings: [.defaultIsolation(MainActor.self), cxx],
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .testTarget(
            name: "TugimeCoreTests",
            dependencies: ["TugimeCore"],
            swiftSettings: [cxx]
        ),
    ]
)

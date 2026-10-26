// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "tugime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TugimeCore", targets: ["TugimeCore"]),
        .executable(name: "tugime-cli", targets: ["tugime-cli"]),
        .executable(name: "tugime", targets: ["TugimeIME"]),
    ],
    targets: [
        // 表示の変換のモデルを動かす llama.cpp。azooKey/llama.cpp の b4846 のビルド済みフレームワーク
        .binaryTarget(
            name: "llama",
            url: "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip",
            checksum: "db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a"
        ),
        .target(name: "SystemDictionaryLayout"),
        // システム辞書を組み立てる道具。scripts/fetch-dictionary.ts が呼ぶ
        .executableTarget(
            name: "tugime-dictionary",
            dependencies: ["SystemDictionaryLayout"]
        ),
        .target(
            name: "TugimeCore",
            dependencies: ["llama", "SystemDictionaryLayout"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "tugime-cli",
            dependencies: ["TugimeCore"]
        ),
        // 変換の方式とモデルを比べる検証の道具。配布物には入れない。測定は手元で実行する
        .target(
            name: "TugimeEval",
            dependencies: ["TugimeCore"]
        ),
        .executableTarget(
            name: "tugime-eval",
            dependencies: ["TugimeCore", "TugimeEval"]
        ),
        .executableTarget(
            name: "TugimeIME",
            dependencies: ["TugimeCore"],
            // 入力メソッドの呼び出しはすべてメインスレッドで届くので、既定の隔離をメインアクターにする（SE-0466）
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .testTarget(
            name: "TugimeCoreTests",
            dependencies: ["TugimeCore"],
            // テストは 1 つの本物の変換器を共有するので、同時に使わないようメインアクターで動かす
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // 検証の道具の読み込みと判定。変換エンジンを通す測定そのものはテストにしない
        .testTarget(
            name: "TugimeEvalTests",
            dependencies: ["TugimeCore", "TugimeEval"]
        ),
    ]
)

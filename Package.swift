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
        // 例文集の読み込み。CLI とテストだけが使い、入力メソッドには入れない
        .target(name: "TugimeCorpus"),
        .executableTarget(
            name: "tugime-cli",
            dependencies: ["TugimeCore", "TugimeCorpus"],
            swiftSettings: [cxx]
        ),
        // 変換の方式とモデルを比べる検証の道具。問題の読み込み・判定・集計・比較・打鍵の計測。配布物には入れない。測定は手元で実行する
        .target(
            name: "TugimeEval",
            dependencies: ["TugimeCore"],
            swiftSettings: [cxx]
        ),
        .executableTarget(
            name: "tugime-eval",
            dependencies: ["TugimeCore", "TugimeEval"],
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
            dependencies: ["TugimeCore", "TugimeCorpus"],
            // テストは 1 つの本物の変換器を共有するので、同時に使わないようメインアクターで動かす
            swiftSettings: [.defaultIsolation(MainActor.self), cxx]
        ),
        // 検証の道具の読み込みと判定。変換エンジンを通す測定そのものはテストにしない
        .testTarget(
            name: "TugimeEvalTests",
            dependencies: ["TugimeCore", "TugimeEval"],
            swiftSettings: [cxx]
        ),
    ]
)

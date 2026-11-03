import { root } from "./root";

/// リリースの swift build。.app も辞書を組み立てる道具も同じ指定で組み立て、依存の解決とコンパイルの結果を使い回す。
/// SwiftPM の既定のビルドの仕組みは toolchain の版で違う。native はリソースを .app の Contents/Resources から探さないので、swiftbuild に固定する。
/// 対象は Apple Silicon だけなので arm64 だけを組み立てる。swiftbuild は指定しないと Intel 向けも含めた universal にする
export const swiftBuild = [
  "swift",
  "build",
  "--package-path",
  root,
  "-c",
  "release",
  "--build-system",
  "swiftbuild",
  "--arch",
  "arm64",
];

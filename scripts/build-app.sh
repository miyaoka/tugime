#!/bin/bash
# tugime.app を dist/ に組み立てて ad-hoc で署名する。鍵束は使わない。
set -euo pipefail

bundle_id=io.github.miyaoka.inputmethod.tugime
version=${TUGIME_VERSION:-0.0.0}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/tugime.app"

# SwiftPM の既定のビルドの仕組みは toolchain の版で違う。native はリソースを .app の Contents/Resources から探さないので、swiftbuild に固定する。
# 対象は Apple Silicon だけなので arm64 だけを組み立てる。swiftbuild は指定しないと Intel 向けも含めた universal にする
build=(swift build --package-path "$root" -c release --build-system swiftbuild --arch arm64)

echo "== Zenzai のモデル"
zenz=$("$root/scripts/fetch-zenz.sh")

echo "== swift build"
"${build[@]}" --product tugime
bin=$("${build[@]}" --show-bin-path)

echo "== 組み立て $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/zenz" "$app/Contents/Frameworks"
cp "$bin/tugime" "$app/Contents/MacOS/tugime"
# Zenzai の推論に使う llama.cpp。実行ファイルは @rpath/llama.framework を探すので、Frameworks を探し場所に足す
cp -R "$bin/llama.framework" "$app/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/tugime"
cp "$zenz" "$app/Contents/Resources/zenz/"
for bundle in "$bin"/*.bundle; do
    cp -R "$bundle" "$app/Contents/Resources/"
done
sed -e "s/__BUNDLE_ID__/$bundle_id/g" -e "s/__VERSION__/$version/g" "$root/App/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
# 入力ソースの一覧に出るモードの表示名
cp -R "$root/App/en.lproj" "$root/App/ja.lproj" "$app/Contents/Resources/"
swift "$root/scripts/make-icons.swift" "$app/Contents/Resources"
swift "$root/scripts/collect-notices.swift" "$root" "$app/Contents/Resources" "$app/Contents/Resources/ThirdPartyNotices.txt"

echo "== ad-hoc 署名"
codesign --force --timestamp=none --sign - "$app"
codesign --verify --strict "$app"
echo "== 完了 $app"

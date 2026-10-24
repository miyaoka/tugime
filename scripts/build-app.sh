#!/bin/bash
# .app を dist/ に組み立てて ad-hoc で署名する。鍵束は使わない。
# 無指定は開発版にする。手元で組み立てたものが配布版と同じ bundle id を名乗り、入れた配布版を上書きしないようにするため
set -euo pipefail

bundle_id=io.github.miyaoka.inputmethod.tugime
name=tugime
case "${TUGIME_BUILD_CHANNEL:-}" in
    stable) ;;
    "")
        bundle_id="$bundle_id.dev"
        name="tugime Dev"
        ;;
    *)
        echo "TUGIME_BUILD_CHANNEL は stable か無指定: $TUGIME_BUILD_CHANNEL" >&2
        exit 1
        ;;
esac
version=${TUGIME_VERSION:-0.0.0}
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/$name.app"

# SwiftPM の既定のビルドの仕組みは toolchain の版で違う。native はリソースを .app の Contents/Resources から探さないので、swiftbuild に固定する。
# 対象は Apple Silicon だけなので arm64 だけを組み立てる。swiftbuild は指定しないと Intel 向けも含めた universal にする
build=(swift build --package-path "$root" -c release --build-system swiftbuild --arch arm64)

echo "== 表示の変換のモデル"
model=$("$root/scripts/fetch-genmai.sh")

echo "== swift build"
"${build[@]}" --product tugime
bin=$("${build[@]}" --show-bin-path)

echo "== 組み立て $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/model" "$app/Contents/Frameworks"
cp "$bin/tugime" "$app/Contents/MacOS/tugime"
# モデルの推論に使う llama.cpp。実行ファイルは @rpath/llama.framework を探すので、Frameworks を探し場所に足す
cp -R "$bin/llama.framework" "$app/Contents/Frameworks/"
# 配られている llama.framework は Intel 向けも含む。対象は Apple Silicon だけなので arm64 だけを残す
llama=$(readlink -f "$app/Contents/Frameworks/llama.framework/llama")
if [[ "$(lipo -archs "$llama")" != "arm64" ]]; then
    lipo -thin arm64 "$llama" -output "$llama"
fi
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/tugime"
cp "$model" "$app/Contents/Resources/model/"
for bundle in "$bin"/*.bundle; do
    cp -R "$bundle" "$app/Contents/Resources/"
done
sed -e "s/__BUNDLE_ID__/$bundle_id/g" -e "s/__VERSION__/$version/g" -e "s/__NAME__/$name/g" "$root/App/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
# 入力ソースの一覧に出るモードの表示名
for lproj in en.lproj ja.lproj; do
    mkdir -p "$app/Contents/Resources/$lproj"
    sed -e "s/__NAME__/$name/g" "$root/App/$lproj/InfoPlist.strings" > "$app/Contents/Resources/$lproj/InfoPlist.strings"
    plutil -lint "$app/Contents/Resources/$lproj/InfoPlist.strings"
done
swift "$root/scripts/make-icons.swift" "$app/Contents/Resources"
swift "$root/scripts/collect-notices.swift" "$root" "$app/Contents/Resources" "$app/Contents/Resources/ThirdPartyNotices.txt"

echo "== ad-hoc 署名"
# 入れ子のフレームワークは外側の署名では署名されない。arm64 だけにして中身が変わったので署名し直す
codesign --force --timestamp=none --sign - "$app/Contents/Frameworks/llama.framework"
# App Sandbox で動かし、通信の権限は持たせない。入力メソッドとして接続するための名前の登録だけを許す
entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
sed -e "s/__BUNDLE_ID__/$bundle_id/g" "$root/App/tugime.entitlements" > "$entitlements"
plutil -lint "$entitlements"
codesign --force --timestamp=none --sign - --entitlements "$entitlements" "$app"
codesign --verify --strict "$app"
echo "== 完了 $app"

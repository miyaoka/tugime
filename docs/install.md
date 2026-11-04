# インストール方法

Homebrew を使わないときのインストール方法。mise と GitHub CLI は、配布物が tugime の release workflow で組み立てられたものかを確かめてから入れる。初めて入れたときは、最後に [入力ソースを追加する](../README.md#入力ソースを追加する)。

## mise で入れる

[mise](https://mise.jdx.dev/) は、tugime の release workflow が署名していない配布物や、署名のあとで書き換えられた配布物を入れずに止める。mise は 2026.10.5 以降を使う。それより前の版は、下のコマンドの `workflow` の指定に対応していない。更新は `mise up` だけである。

```bash
mise use -g 'packslip:github.com/miyaoka/tugime[workflow="release.yml@refs/heads/main",postinstall="\"$MISE_TOOL_INSTALL_PATH/install.sh\" \"$MISE_TOOL_INSTALL_PATH/tugime.app\""]'
```

## GitHub CLI で入れる

[GitHub CLI](https://cli.github.com/) を使う。次のコマンドは、一時ディレクトリに最新版を取得し、tugime の release workflow が組み立てたものかを確かめ、確かめられたときだけ展開して入れる。更新するときも同じコマンドである。

```bash
dir=$(mktemp -d) &&
gh release download --repo miyaoka/tugime --pattern tugime-macos-arm64.tar.gz --dir "$dir" &&
gh attestation verify "$dir/tugime-macos-arm64.tar.gz" --repo miyaoka/tugime --cert-identity https://github.com/miyaoka/tugime/.github/workflows/release.yml@refs/heads/main &&
tar -xzf "$dir/tugime-macos-arm64.tar.gz" -C "$dir" &&
bash "$dir/install.sh"
```

## ソースから組み立てて入れる

[開発](development.md#ソースから組み立てて入れる) にある。

---
title: "インストールと初期設定"
description: "Amulet CLIのインストール手順と、最初のシークレットを保存するまでの最速ガイド。"
order: 2
---

このページでは、Amuletをお使いの環境にインストールし、最初の秘密情報を保存して読み出すまでの手順を解説します。

:::note
ターミナルの操作や、なぜAmuletが安全なのかといった「概念」について知りたい方は、先に **[概念と基礎知識](concepts)** をご覧ください。
:::

---

## 1. インストール

お使いのOSに合わせて、以下のコマンドを実行してください。

### macOS
[Homebrew](https://brew.sh/) を使用するのが最も簡単です。

```sh
brew tap tsukasa-art/amulet
brew install amulet
```

### Windows
[Scoop](https://scoop.sh/) を使用してインストールできます。

```powershell
# バケットを追加してインストール
scoop bucket add amulet https://github.com/tsukasa-art/scoop-amulet.git
scoop install amulet
```

### Linux (または curl で直接インストール)
GitHub Releases から直接バイナリをダウンロードして `~/.local/bin` に配置します。

```sh
curl -fL -o ~/.local/bin/amulet \
  https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
chmod +x ~/.local/bin/amulet
```

`~/.local/bin` はほとんどのモダンな Linux ディストリビューションでデフォルトの `$PATH` に含まれています。インストール後に `amulet` が見つからない場合は、`export PATH="$HOME/.local/bin:$PATH"` をシェルのプロファイルに追加してください。

---

## 2. 最初のシークレットを封印する (Seal)

インストールができたら、試しに一つ秘密情報を保存してみましょう。
ここでは `MY_SECRET` という名前で、適当な文字列を保存します。

```bash
# 「my-password-123」という値を暗号化して保存
echo -n "my-password-123" | amulet seal MY_SECRET --file secrets.vault
```

コマンドを打つと、**パスフレーズ** の入力を求められます。
このパスフレーズは、後でデータを取り出す際に必要になるので、忘れないようにしてください。

::: tip
`secrets.vault` というファイルが作成されます。これは暗号化されているため、GitHubにコミットしても安全です。
:::

---

## 3. シークレットを読み出す (Unseal)

保存した情報を取り出してみます。

```bash
amulet unseal MY_SECRET --file secrets.vault
```

パスフレーズを入力すると、画面に `my-password-123` と表示されます。
これで、基本的な使い方はマスターです！

---

## 4. 便利な設定：パスフレーズの自動入力

毎回パスフレーズを打つのが面倒な場合は、環境変数 `VAULT_PASSPHRASE` に設定しておくことができます。

```bash
export VAULT_PASSPHRASE="your-passphrase"
amulet unseal MY_SECRET --file secrets.vault
```

::: caution
共有マシンや、他人が見る可能性のある環境では、環境変数にパスフレーズを置くことは避けてください。
:::

---

## 次のステップ

*   **[使い方リファレンス](usage)**: コマンドの詳細なオプションを確認する。
*   **[デプロイメント](deployment)**: サーバーやDockerでAmuletを動かす方法。
*   **[セキュリティ設計](security)**: Amuletがどのようにデータを守っているか詳しく知る。

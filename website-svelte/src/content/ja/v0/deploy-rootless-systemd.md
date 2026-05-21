---
title: "ルートレス・デプロイ (user systemd)"
description: "systemctl --userを使用し、非rootユーザーのサービスとしてAmuletをデプロイする方法。"
order: 7
---

このガイドでは、**非 root ユーザーのサービス** (`systemctl --user`) として Amulet をデプロイする手順を解説します。これは、アプリケーションが既にルートレスで動作している場合（例：rootless Podman、ユーザー所有のプロセス等）に最適な選択肢です。

> **[Ubuntu 本番環境デプロイ](deploy-ubuntu.md) を優先すべきケース:** アプリケーションが `/etc/systemd/system` 下の専用システムユーザーとして root 所有のサービスで動作している場合。そのガイドでは `LoadCredential` を使用しており、一般的なサーバーデプロイに適しています。

---

## どのような時にこのガイドを使うか

| シナリオ | 参照すべきガイド |
|---------|---------------|
| アプリが `/etc/systemd/system` 下のシステムユーザーで動作 | [deploy-ubuntu.md](deploy-ubuntu.md) |
| アプリがルートレスで動作 (rootless Podman, ユーザープロセス) | **このガイド** |
| アプリが root 権限の Docker / Podman で動作 | [deploy-ubuntu.md](deploy-ubuntu.md) または [デプロイメント・ガイド](deployment.md) |

root 所有のサービスとルートレス Podman コンテナを混ぜて使うと、権限エラーの原因になりがちです。コンテナが一般ユーザーで動作しているなら、systemd サービスもユーザー空間に合わせるのがスムーズです。

---

## 前提条件

- Ubuntu 22.04+ (または systemd 247+ 搭載の Linux。ユーザーサービス自体は古いバージョンでも動きますが、`LoadCredential` のような高度な機能を使うには 247+ が必要です)
- `amulet` バイナリがインストール済みであること — [インストール](getting-started) 参照
- アプリケーションが対象ユーザーとして既に正しく動作していること

---

## 1. バイナリの配置

`sudo` 不要で済むよう、ユーザーのローカルディレクトリにインストールします：

```sh
curl -fL -o /tmp/amulet https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
chmod +x /tmp/amulet
mkdir -p ~/.local/bin
install -m 0755 /tmp/amulet ~/.local/bin/amulet
~/.local/bin/amulet version
```

`~/.local/bin` が `PATH` に含まれていない場合は追加します：

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> **スクリプト内ではフルパスを使うこと。** `systemctl --user` サービスは、`~/.local/bin` を含まない最小限の `PATH` で動作します。ラッパースクリプト内では必ず `/home/ユーザー名/.local/bin/amulet` のようにフルパス（または `$HOME` を使った絶対パス）を記述してください。

---

## 2. .env から vault を作成

```sh
mkdir -p ~/.config/amulet

amulet import \
  --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault

chmod 600 ~/.config/amulet/secrets.vault
```

インポート内容の確認：

```sh
amulet list --file ~/.config/amulet/secrets.vault
```

> **`.env` フォーマットの注意:** `import` は単純な `KEY=VALUE` 行を想定しています。`export API_KEY=foo` のように `export` が付いている行は**非対応**です。インポート前に `export` プレフィックスを除去してください。

確認後、平文の `.env` を処理します：

```sh
# A: その場で値を消去（空行で上書き）
amulet import --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault --wipe

# B: ファイルごと削除
rm /path/to/your/.env
```

---

## 3. パスフレーズの保存

パスフレーズをユーザー専用のファイルに書き込みます。不一致を防ぐため、`printf "%s"` で改行なしで保存します：

```sh
bash -c 'read -rsp "Amulet passphrase: " PASS; echo; printf "%s" "$PASS" > ~/.config/amulet/passphrase'
chmod 600 ~/.config/amulet/passphrase
```

正しく保存されたか確認（末尾改行なしの 1 行であることを確認）：

```sh
wc -c ~/.config/amulet/passphrase
```

---

## 4. Vault の場所を統一する

プロジェクトディレクトリ内に `secrets.vault` が散在している場合は、混乱を避けるために一箇所に集約します：

```sh
# プロジェクト内のコピーをリネーム（バックアップ化）。サービスは ~/.config/amulet/secrets.vault を使用。
mv ~/myapp/secrets.vault ~/myapp/secrets.vault.bak
```

異なるディレクトリに同じ名前の vault があると、一方を更新しても他方が古いままになるミスが頻発します。

---

## 5. 起動ラッパースクリプトの作成

このスクリプトが全シークレットを unseal し、エクスポートしてからアプリを起動します。絶対パスを使用してください。

```sh
cat > ~/.local/bin/myapp-start.sh <<'EOF'
#!/bin/bash
set -euo pipefail

VAULT="$HOME/.config/amulet/secrets.vault"
PASSPHRASE_FILE="$HOME/.config/amulet/passphrase"

# 全キーを unseal してエクスポート
while IFS= read -r key; do
  value="$(cat "$PASSPHRASE_FILE" | /home/youruser/.local/bin/amulet unseal "$key" --file "$VAULT")"
  export "$key=$value"
done < <(/home/youruser/.local/bin/amulet list --file "$VAULT")

# アプリを起動
exec /path/to/your/app
EOF

chmod 750 ~/.local/bin/myapp-start.sh
```

`/home/youruser` は実際のホームディレクトリパスに置き換えてください（systemd の `ExecStart=` は `~` や `$HOME` を展開しないため）。

---

## 6. ユーザーサービスの作成

```sh
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/myapp.service <<'EOF'
[Unit]
Description=My App (rootless)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/youruser/myapp
ExecStart=/home/youruser/.local/bin/myapp-start.sh

[Install]
WantedBy=default.target
EOF
```

リロードと起動：

```sh
systemctl --user daemon-reload
systemctl --user enable myapp
systemctl --user start myapp
systemctl --user status myapp --no-pager -l
```

---

## 7. リンガー設定 (OS 起動時の自動開始)

デフォルトでは、ユーザーサービスは「ログイン後」にしか自動開始されません。誰もログインしていなくても OS 起動時に開始されるように設定します：

```sh
loginctl enable-linger "$USER"
```

確認：

```sh
loginctl show-user "$USER" | grep Linger
# 期待値: Linger=yes
```

---

## 8. 動作確認

```sh
systemctl --user status myapp
# ヘルスチェックエンドポイントを叩く等
curl -fsS http://127.0.0.1/your-health-endpoint
```

---

## デプロイ後のシークレット更新

### 通常の更新（対話的）

```sh
echo -n "new_secret_value" | \
  amulet seal SECRET_KEY --file ~/.config/amulet/secrets.vault

systemctl --user restart myapp
```

### SSH 断線が懸念される場合（一時ファイル経由）

```sh
# 一時ファイルを作成（絶対にコミットしないこと）
cat > /tmp/amulet-update.env <<'EOF'
SECRET_KEY=new_value
ANOTHER_KEY=another_value
EOF

amulet import \
  --env-file /tmp/amulet-update.env \
  --file ~/.config/amulet/secrets.vault \
  < ~/.config/amulet/passphrase

rm -f /tmp/amulet-update.env

systemctl --user restart myapp
```

インポート後は直ちに `/tmp/amulet-update.env` を削除してください。

---

## セキュリティ・サマリー

| 対策 | 効果 |
|------|------|
| vault とパスフレーズの `chmod 600` | 所有ユーザーのみが読み取り可能 |
| スクリプト内の `amulet` フルパス指定 | `PATH` 操作による攻撃を回避 |
| `loginctl enable-linger` | ログインなしでも OS 起動時にサービスを開始 |
| Locked モード (デフォルト) | vault はこのマシンの `machine_id` にバインドされ、他所では復号不能 |
| 単一の vault パス (`~/.config/amulet/`) | 古いコピーが残って混乱するのを防ぐ |
| `/proc/<pid>/environ` について | 同じホストの root は環境変数を読み取れます。ホストレベルのアクセス制御は引き続き必要です |

---

## 関連情報

- [Ubuntu 本番環境デプロイ](deploy-ubuntu.md) — `LoadCredential` を使ったシステムサービス (root 権限あり)
- [デプロイメント・ガイド](deployment.md) — Locked vs Portable 判断表、移行、Docker Compose
- [セキュリティリファレンス](security.md) — vault フォーマット、暗号仕様、脅威モデル

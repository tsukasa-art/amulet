# Amulet — rootless デプロイ（user systemd）

このガイドでは **非 root ユーザーサービス**（`systemctl --user`）配下で
Amulet をデプロイする方法を説明します。アプリがすでに rootless で動作している
（rootless Podman、ユーザー所有のプロセスマネージャーなど）場合に適した方法です。

> **root 所有のサービス（`/etc/systemd/system`）を使う場合は
> [docs/deploy-ubuntu-ja.md](deploy-ubuntu-ja.md) を使用してください。**
> そちらのガイドは `LoadCredential` を利用し、一般的なサーバーデプロイに適しています。

> **先にインストール手順を確認する場合:** [README_JA.md のインストール](../README_JA.md#インストール) を参照してください。

---

## このガイドを使うべき場合

| 状況 | 使用するガイド |
|------|--------------|
| アプリが `/etc/systemd/system` 配下のシステムユーザーで動く | [deploy-ubuntu-ja.md](deploy-ubuntu-ja.md) |
| アプリが rootless で動く（rootless Podman、ユーザープロセスなど） | **このガイド** |
| Docker / root デーモン Podman でコンテナが動く | [deploy-ubuntu-ja.md](deploy-ubuntu-ja.md) または [deployment-ja.md](deployment-ja.md) |

root 所有のサービスと rootless Podman コンテナを混在させると、権限の競合が
起きやすくなります。コンテナが一般ユーザーで動いているなら、systemd サービスも
ユーザースペースに統一するのが基本方針です。

---

## 前提条件

- Ubuntu 22.04+（または systemd 247+ が動く Linux。user サービス自体はそれ以前でも動作します — `LoadCredential` のみ 247+ 必須）
- `amulet` バイナリがインストール済み — [README_JA.md のインストール](../README_JA.md#インストール) を参照
- 対象ユーザーでアプリがすでに正常に起動できること

---

## 1. amulet バイナリを配置する

ユーザーのローカル bin ディレクトリにインストールすることで、`sudo` 不要で使えます:

```sh
curl -fL -o /tmp/amulet https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
chmod +x /tmp/amulet
mkdir -p ~/.local/bin
install -m 0755 /tmp/amulet ~/.local/bin/amulet
~/.local/bin/amulet version
```

`~/.local/bin` が `PATH` に含まれていない場合は追加します:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> **スクリプト内ではフルパスを使用してください。** `systemd --user` のサービスは
> `~/.local/bin` を含まない最小限の `PATH` で動作します。ラッパースクリプト内では
> `amulet` だけでなく、`/home/youruser/.local/bin/amulet` のように絶対パスで
> 指定してください。

---

## 2. .env ファイルから vault を作成する

```sh
mkdir -p ~/.config/amulet

amulet import \
  --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault

chmod 600 ~/.config/amulet/secrets.vault
```

インポート結果を確認します:

```sh
amulet list --file ~/.config/amulet/secrets.vault
```

> **`.env` ファイルのフォーマット注意:** `import` は `KEY=VALUE` 形式の行のみを受け付けます。
> `export API_KEY=foo` のように `export` が付いた行は**サポートされていません** —
> インポート前に `export` プレフィックスを取り除いてください。

vault が正しく作成されたことを確認してから、平文ファイルを削除または上書きします:

```sh
# Option A: 値を空行で上書き（ファイル構造を残す）
amulet import --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault --wipe

# Option B: ファイルごと削除
rm /path/to/your/.env
```

---

## 3. パスフレーズを保存する

パスフレーズをユーザーのみ読めるファイルに書き込みます。末尾改行を含まないよう
`printf "%s"` を使います（`amulet unseal` がファイルを読む際に不一致が起きるのを防ぐため）:

```sh
bash -c 'read -rsp "Amulet passphrase: " PASS; echo; printf "%s" "$PASS" > ~/.config/amulet/passphrase'
chmod 600 ~/.config/amulet/passphrase
```

> プロンプト表示後、入力中は文字が表示されません。入力後 Enter を押してください。

ファイルを確認します（末尾改行なしの 1 行であること）:

```sh
wc -c ~/.config/amulet/passphrase
```

---

## 4. vault の場所を 1 か所に統一する

プロジェクトディレクトリに `secrets.vault` が残っている場合は退避させ、
`~/.config/amulet/secrets.vault` を唯一の正規ファイルにします:

```sh
# プロジェクト内のコピーをバックアップ名に変更。サービスは ~/.config/amulet/secrets.vault を使う
mv ~/myapp/secrets.vault ~/myapp/secrets.vault.bak
```

異なる場所に同名の vault ファイルが存在すると、片方への更新がもう片方に反映されず
混乱の原因になります。

---

## 5. 起動ラッパースクリプトを作成する

ラッパーはアプリ起動前にすべてのシークレットを unseal して export します。
user サービスは最小限の `PATH` しか持たないため、パスはすべて絶対パスで書きます。

```sh
cat > ~/.local/bin/myapp-start.sh <<'EOF'
#!/bin/bash
set -euo pipefail

VAULT="$HOME/.config/amulet/secrets.vault"
PASSPHRASE_FILE="$HOME/.config/amulet/passphrase"

# 全キーを unseal して export する
while IFS= read -r key; do
  value="$(cat "$PASSPHRASE_FILE" | /home/youruser/.local/bin/amulet unseal "$key" --file "$VAULT")"
  export "$key=$value"
done < <(/home/youruser/.local/bin/amulet list --file "$VAULT")

# アプリを起動
exec /path/to/your/app
EOF

chmod 750 ~/.local/bin/myapp-start.sh
```

`/home/youruser` は実際のホームディレクトリの絶対パスに置き換えてください
（systemd の `ExecStart=` では `~` や `$HOME` は展開されません）。

---

## 6. user サービスを作成する

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

反映と起動:

```sh
systemctl --user daemon-reload
systemctl --user enable myapp
systemctl --user start myapp
systemctl --user status myapp --no-pager -l
```

---

## 7. Linger を有効にする（OS 起動時の自動起動）

デフォルトでは user サービスはログイン後にのみ自動起動します。
ログインなしで OS 起動時から自動起動させるには linger を有効にします:

```sh
loginctl enable-linger "$USER"
```

確認:

```sh
loginctl show-user "$USER" | grep Linger
# 期待値: Linger=yes
```

再起動後、ログインする前にアプリが起動していることを確認してください。

---

## 8. 動作確認

```sh
systemctl --user status myapp
# アプリが応答することを確認（例）:
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

### SSH が切断されやすい場合（テンポラリファイルを使った一括更新）

SSH 越しの対話的 `seal` は入力途中で接続が切れると中断されます。
一括更新や長時間の作業では、代わりにテンポラリファイルを使う方が安全です:

```sh
# 新しい値をテンポラリファイルに書き込む（このファイルはコミットしないこと）
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

> `/tmp/amulet-update.env` は import 直後に削除してください。
> Linux の `/tmp` はデフォルトで全ユーザーから参照可能です。

---

## セキュリティまとめ

| 対策 | 効果 |
|------|------|
| vault とパスフレーズファイルに `chmod 600` | 所有ユーザーのみ読み取り可能 |
| スクリプト内で `amulet` をフルパス指定 | `PATH` の操作に影響されない |
| `loginctl enable-linger` | ログインなしで OS 起動時からサービスが起動する |
| Locked vault（デフォルト） | vault はこのマシンの `machine_id` に紐付け。別ホストでは復号不可 |
| 正規 vault パスを 1 か所に統一（`~/.config/amulet/`） | 古いコピーとサイレントに乖離するリスクを排除 |
| `/proc/<pid>/environ` について | 同一ホスト上の root は export された環境変数を読み取れます — ホストレベルのアクセス制御は引き続き必要です |

---

## 関連ドキュメント

- [docs/deploy-ubuntu-ja.md](deploy-ubuntu-ja.md) — `LoadCredential` を使った root サービス構成（systemd システムユーザー、rootless 不要）
- [docs/deployment-ja.md](deployment-ja.md) — Locked vs Portable の比較、マイグレーション、Docker Compose
- [docs/security-ja.md](security-ja.md) — vault フォーマット、暗号仕様、脅威モデル

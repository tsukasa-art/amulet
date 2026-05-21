---
title: "Ubuntu 本番環境デプロイ (systemd)"
description: "systemdのLoadCredentialを使用し、パスフレーズを安全に注入してUbuntuにAmuletをデプロイする方法。"
order: 6
---

このガイドでは、Ubuntu 24.04 LTS (systemd 255) を対象に、`LoadCredential` を使用してパスフレーズを環境変数やコマンドラインに露出させずに注入するデプロイ手順を解説します。

> **対象:** Ubuntu 22.04+ (systemd 247+)。Ubuntu 20.04 (systemd 245) は `LoadCredential` をサポートしていません。その場合は [Ubuntu 20.04 でのフォールバック](#ubuntu-2004-でのフォールバック) を参照してください。

---

## なぜ `LoadCredential` なのか

`LoadCredential` は、サービスプロセスの実行中のみ、パスフレーズを `$CREDENTIALS_DIRECTORY` 内の tmpfs（メモリ上）ファイルとしてマウントします。パスフレーズがコマンドライン引数や環境変数に載ることはなく、サービス停止時には自動的に消去されます。

復号されたシークレットは、アプリケーションプロセスの環境変数としてエクスポートされます。Linux では root 権限があれば `/proc/<pid>/environ` から環境変数を読み取れますが、これは OS の仕様です。そのため、サーバーレベルでのアクセス制御（非 root ユーザーでの実行、`PermitRootLogin no` 等）は引き続き重要です。

---

## 1. SSH のセキュリティ強化

サーバーにシークレットを置く前に、`/etc/ssh/sshd_config` で以下の設定を確認してください：

```
PermitRootLogin no
PasswordAuthentication no
```

> **注意:** 設定を反映（reload）する前に、必ず別の SSH セッションを sudo ユーザーで開いておき、締め出しを防いでください。

```sh
sudo systemctl reload ssh
```

---

## 2. Vault ファイルの配置

`secrets.vault` をサーバーにコピーし、アプリケーションユーザーのみが読み取れるように権限を設定します：

```sh
sudo mkdir -p /etc/amulet
sudo cp secrets.vault /etc/amulet/secrets.vault
sudo chown root:myapp /etc/amulet/secrets.vault
sudo chmod 640 /etc/amulet/secrets.vault
```

`myapp` はアプリケーションを実行するシステムユーザー名に置き換えてください。

---

## 3. パスフレーズの保存

パスフレーズを root のみが読み取れるファイルに書き込みます。シェル履歴に残るのを避けるため、標準入力から読み取ります。`printf "%s"` を使うことで末尾の改行を防ぎ、`amulet unseal` 時の不一致を回避します：

```sh
sudo mkdir -p /etc/amulet
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" > /etc/amulet/passphrase'
sudo chmod 600 /etc/amulet/passphrase
sudo chown root:root /etc/amulet/passphrase
```

---

## 4. 起動ラッパースクリプトの作成

シークレットを復号し、環境変数がセットされた状態でアプリケーションを起動するスクリプトを作成します。systemd の `PATH` に依存しないよう、`amulet` はフルパスで指定します：

```sh
# /usr/local/bin/myapp-start.sh
#!/bin/sh
export API_KEY=$(cat "$CREDENTIALS_DIRECTORY/amulet-pass" \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault)
exec /opt/myapp/bin/myapp
```

`myapp` ユーザーが実行できるよう権限を設定します：

```sh
sudo chown root:myapp /usr/local/bin/myapp-start.sh
sudo chmod 750 /usr/local/bin/myapp-start.sh
```

アプリケーションが必要とするシークレットの数だけ `export` 行を追加してください。

---

## 5. systemd ユニットの作成

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My App
After=network.target

[Service]
User=myapp
LoadCredential=amulet-pass:/etc/amulet/passphrase
ExecStart=/usr/local/bin/myapp-start.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now myapp
sudo systemctl status myapp
```

---

## セキュリティ・サマリー

| 対策 | 効果 |
|------|------|
| パスフレーズファイルの `chmod 600` | root のみが読み取り可能 |
| `LoadCredential` | パスフレーズは tmpfs 上に配置され、終了時に消去 |
| ラッパーの `chown root:myapp 750` | root と `myapp` グループのみが実行可能 |
| `User=myapp` | アプリケーションは非 root ユーザーで動作 |
| Locked モード (デフォルト) | vault はこのマシンの `machine_id` にバインドされ、他所では復号不能 |
| `PermitRootLogin no` | SSH 経由で root が直接ログインすることを禁止 |
| `PasswordAuthentication no` | SSH 鍵を必須とし、パスワード総当たり攻撃を遮断 |

---

## デプロイ後のシークレット更新

### 通常の更新（1つのキー）

```sh
echo -n "new_secret_value" | \
  sudo amulet seal SECRET_KEY --file /etc/amulet/secrets.vault
sudo systemctl restart myapp
```

### SSH 断線が懸念される場合（一時ファイル経由の一括更新）

対話的な `seal` プロンプトは SSH が切れると中断されます。多数の更新を VPS 上で行う場合は、一旦新しい値を一時ファイルに書き出してからインポートすることで、非対話的に一括完了できます：

```sh
# 一時ファイルを作成（インポート後すぐに削除すること）
sudo bash -c 'cat > /tmp/amulet-update.env' <<'EOF'
SECRET_KEY=new_value
ANOTHER_KEY=another_value
EOF

sudo amulet import \
  --env-file /tmp/amulet-update.env \
  --file /etc/amulet/secrets.vault \
  < /etc/amulet/passphrase

sudo rm -f /tmp/amulet-update.env
sudo systemctl restart myapp
```

> `/tmp` は多くの環境で全ユーザーが読み取れます。インポート後は直ちに削除してください。

---

## 物理サーバー：TPM2 によるさらなる強化

TPM2 チップを搭載したベアメタルサーバーでは、`LoadCredentialEncrypted` を使うことでパスフレーズを TPM にバインドし、他のマシンでは一切読み取れないようにできます：

```sh
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" \
  | systemd-creds encrypt --name=amulet-pass - /etc/amulet/passphrase.cred'
sudo chmod 600 /etc/amulet/passphrase.cred
```

サービスユニットの設定を変更します：

```ini
LoadCredentialEncrypted=amulet-pass:/etc/amulet/passphrase.cred
```

> VPS 環境では通常 TPM2 チップは公開されていません。その場合は通常の `LoadCredential` を使用してください。

---

## Ubuntu 20.04 でのフォールバック

Ubuntu 20.04 は systemd 245 を搭載しており、`LoadCredential` に対応していません。これはあくまで最終手段であり、**22.04+ へアップグレードして `LoadCredential` を使うことを強く推奨します。**

`xargs -I{}` はシークレットにスペースやクォートが含まれる場合に脆弱です。このパターンは API キーのような単一の文字列のみに使用してください：

```ini
[Service]
ExecStart=/bin/sh -c 'cat /etc/amulet/passphrase \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault \
  | xargs -I{} env API_KEY={} /opt/myapp/bin/myapp'
```

> Ubuntu 20.04 は 2025年4月に標準サポートが終了します。24.04 LTS への移行を検討してください。

---

## 関連情報

- [デプロイメント・ガイド](deployment.md) — Locked vs Portable 判断表、移行、Docker Compose
- [セキュリティリファレンス](security.md) — vault フォーマット、暗号仕様、脅威モデル

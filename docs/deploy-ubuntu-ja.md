# Amulet — Ubuntu 本番デプロイ（systemd）

このガイドでは Ubuntu 24.04 LTS（systemd 255）上で `LoadCredential` を使い、
vault パスフレーズを環境変数やコマンドライン引数に露出させずに注入する方法を説明します。

> **対象:** Ubuntu 22.04+（systemd 247+）。Ubuntu 20.04（systemd 245）は
> `LoadCredential` 非対応です — [Ubuntu 20.04 の代替手順](#ubuntu-2004-の代替手順) を参照してください。

---

## なぜ `LoadCredential` を使うのか

`LoadCredential` は、サービスプロセスが起動している間だけパスフレーズを
`$CREDENTIALS_DIRECTORY` 以下に tmpfs ファイルとしてマウントします。
パスフレーズはコマンドライン引数にも通常の環境変数にも渡らず、
サービス停止時に自動的に削除されます。

unseal したシークレットはアプリプロセスの環境変数として渡されます。
Linux では root が `/proc/<pid>/environ` からプロセスの環境変数を読み取れます。
これはサーバ運用として想定内の挙動であり、ホストレベルのアクセス制御
（非 root アプリユーザ・`PermitRootLogin no`）と組み合わせることが前提です。

---

## 1. SSH を堅牢化する

シークレットをサーバに置く前に、`/etc/ssh/sshd_config` で以下の設定を確認します:

```
PermitRootLogin no
PasswordAuthentication no
```

> **注意:** 設定変更前に sudo ユーザで別の SSH セッションを開いたまま作業してください。
> 締め出し防止のためです。

```sh
sudo systemctl reload ssh
```

---

## 2. vault ファイルを配置する

`secrets.vault` をサーバにコピーし、アプリユーザのみが読めるよう権限を設定します:

```sh
sudo mkdir -p /etc/amulet
sudo cp secrets.vault /etc/amulet/secrets.vault
sudo chown root:myapp /etc/amulet/secrets.vault
sudo chmod 640 /etc/amulet/secrets.vault
```

`myapp` はアプリケーションを実行するシステムユーザ名に置き換えてください。

---

## 3. パスフレーズを保存する

シェル履歴に残らないよう stdin から読み込んでファイルに書き込みます。
`printf "%s"` は末尾改行を付けないため、`amulet unseal` がクレデンシャルファイルを
読む際にパスフレーズのミスマッチが起きません:

```sh
sudo mkdir -p /etc/amulet
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" > /etc/amulet/passphrase'
sudo chmod 600 /etc/amulet/passphrase
sudo chown root:root /etc/amulet/passphrase
```

---

## 4. 起動スクリプトを作成する

シークレットを unseal してアプリケーションを起動するラッパースクリプトです。
systemd の `PATH` に依存しないよう `amulet` はフルパスで指定します:

```sh
# /usr/local/bin/myapp-start.sh
#!/bin/sh
export API_KEY=$(cat "$CREDENTIALS_DIRECTORY/amulet-pass" \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault)
exec /opt/myapp/bin/myapp
```

グループビットで `myapp` が実行できるよう所有者を設定します:

```sh
sudo chown root:myapp /usr/local/bin/myapp-start.sh
sudo chmod 750 /usr/local/bin/myapp-start.sh
```

アプリケーションが必要とするシークレットの数だけ `export` 行を追加してください。

---

## 5. systemd サービスを作成する

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

## セキュリティまとめ

| 対策 | 効果 |
|------|------|
| パスフレーズファイルを `chmod 600` | root のみ読み取り可能 |
| `LoadCredential` | パスフレーズは tmpfs に配置され、サービス停止時に自動削除 |
| ラッパーを `chown root:myapp 750` | root と `myapp` グループのみ実行可能 |
| `User=myapp` | アプリが非 root で実行される |
| Locked vault（デフォルト） | vault はこのマシンの `machine_id` に束縛され、別ホストでは復号不可 |
| `PermitRootLogin no` | SSH での root 直接ログインを遮断 |
| `PasswordAuthentication no` | SSH 鍵認証のみ許可、パスワードブルートフォースをブロック |

---

## 物理サーバ向け: TPM2 を使ったより強固な構成

TPM2 チップを搭載したベアメタルサーバでは、`LoadCredentialEncrypted` を使うと
パスフレーズファイルが TPM に束縛され、別マシンでは読み取り不能になります。
シェル履歴への露出を避けるため、手順 3 と同様に stdin 経由で入力します:

```sh
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" \
  | systemd-creds encrypt --name=amulet-pass - /etc/amulet/passphrase.cred'
sudo chmod 600 /etc/amulet/passphrase.cred
```

サービスユニットの該当行を変更します:

```ini
LoadCredentialEncrypted=amulet-pass:/etc/amulet/passphrase.cred
```

> シン VPS 環境では通常 TPM2 チップが利用できません。VPS では通常の
> `LoadCredential` を使ってください。

---

## Ubuntu 20.04 の代替手順

Ubuntu 20.04 は systemd 245 を搭載しており `LoadCredential` に対応していません。
これは最後の手段です — **22.04+ へアップグレードして `LoadCredential` を使うことを強く推奨します。**

`xargs -I{}` はシークレットに空白・クォート・改行が含まれると壊れやすいです。
API キーのような単一行のシークレットにのみ使用してください:

```ini
[Service]
ExecStart=/bin/sh -c 'cat /etc/amulet/passphrase \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault \
  | xargs -I{} env API_KEY={} /opt/myapp/bin/myapp'
```

> Ubuntu 20.04 は 2025 年 4 月にサポートが終了しています。24.04 LTS への
> アップグレードを強く推奨します。

---

## 関連ドキュメント

- [docs/deployment-ja.md](deployment-ja.md) — Locked/Portable 判断表・移行手順・Docker Compose
- [docs/security-ja.md](security-ja.md) — vault フォーマット・暗号仕様・脅威モデル

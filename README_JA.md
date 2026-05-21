![Amulet](assets/logo.jpg)

# Amulet — ハードウェア紐付きゼロトレース秘密情報管理ツール

## 概要

Amulet は、秘密情報（API キー・トークン・パスワード等）を **seal したホストの OS が報告するマシン識別子**（`machine_id` — Linux では `/etc/machine-id`、macOS では IOPlatformUUID、Windows では MachineGuid から読む）に暗号化バインドする CLI ツールです。

- 秘密は `.env` には書かず、**暗号化した vault ファイル**に入れます。
- 秘密の値はコマンドライン引数に載せません。必要なときは **stdin** から渡します。
- 復号失敗は**理由を表示せず**終了コード 1 で終わります（仕様です）。
- コーディング支援 AI やほかのツールへの、うっかり漏洩を構造的に減らす設計です。

**stdin / stdout / パイプが初めての方:** [docs/getting-started-ja.md](docs/getting-started-ja.md) を先に読んでください。

---

## なぜ Amulet か

| | 既存の秘密管理プラットフォーム | Amulet |
|---|---|---|
| セットアップ | サーバー・クラウド契約が必要 | バイナリ1本 |
| チーム共有 | ✅ | ❌ 設計外（1台向け） |
| ネットワーク依存 | あり | なし（完全ローカル） |
| ハードウェアバインド | なし | ✅ Locked Mode |
| AI エージェント対策 | 間接的 | 構造的に設計 |

**向いている場面:** 個人開発・フリーランス・AI 開発（バイブコーディング）・サーバーを立てたくない。  
**向いていない場面:** チームで秘密共有 → Infisical・Vault 等。CI・クラウドネイティブが主体 → クラウドの Secrets Manager との併用を推奨。

---

## インストール

[GitHub Releases](https://github.com/tsukasa-art/amulet/releases) から最新バイナリをダウンロードしてください:

| OS | ファイル |
|---|---|
| Linux (x86_64) | `amulet-linux-x86_64` |
| macOS (Apple Silicon) | `amulet-macos-aarch64` |
| macOS (Intel) | `amulet-macos-x86_64` |
| Windows (x86_64) | `amulet-windows-x86_64.exe` |

**Linux / macOS:**
```sh
# Linux x86_64
chmod +x ./amulet-linux-x86_64
sudo install -m 0755 ./amulet-linux-x86_64 /usr/local/bin/amulet

# macOS Apple Silicon
# chmod +x ./amulet-macos-aarch64
# sudo install -m 0755 ./amulet-macos-aarch64 /usr/local/bin/amulet

# macOS Intel
# chmod +x ./amulet-macos-x86_64
# sudo install -m 0755 ./amulet-macos-x86_64 /usr/local/bin/amulet

amulet version
```

**Windows:** `chmod` 不要。`amulet.exe` にリネームして `PATH` の通ったフォルダへ移動してください。

### 本番サーバーへの導入

本番サーバーには、サーバー上で直接ダウンロードする方法とローカルから転送する方法があります。

**方法 A: サーバー上で直接ダウンロード**
```sh
# サーバー上で実行（Linux x86_64）
curl -fL -o /tmp/amulet \
  https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
sudo install -m 0755 /tmp/amulet /usr/local/bin/amulet
amulet version
```

**方法 B: ローカルから転送**
```sh
# ローカル -> サーバー
scp ./amulet-linux-x86_64 user@your-server:/tmp/amulet

# サーバー上で配置して確認
ssh user@your-server "sudo install -m 0755 /tmp/amulet /usr/local/bin/amulet && amulet version"
```

> **前提:** ターミナルでコマンドを実行できること。**初めての方**は [docs/getting-started-ja.md](docs/getting-started-ja.md) を参照してください。

---

## クイックスタート

> AI ツール（Cursor・Claude Code 等）を使って開発する場合、AI が `.env` パターンを提案することがあります。代わりに Amulet を使いましょう。

**1. vault を初期化する**

```sh
amulet init --file secrets.vault
```

**2. 秘密を登録する**

```sh
echo -n "your-secret-value" | amulet seal OPENAI_API_KEY --file secrets.vault
# パスフレーズはターミナルでプロンプト（エコーオフ）。秘密はパイプ経由。
```

**3. 秘密を読み出す**

```sh
# 対話
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# スクリプト・CI（stdin 第1行がパスフレーズ）
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# Python
python3 -c "
import os, subprocess
r = subprocess.run(['amulet','unseal','OPENAI_API_KEY','--file','secrets.vault'],
    input=os.environ['VAULT_PASSPHRASE']+'\n', text=True, capture_output=True, check=True)
print(r.stdout)
"

# Node.js / TypeScript — wrappers/node/amulet.ts を参照
```

**4. キー名だけ記録する（`.env.example` の代わりに）**

```
# 必要なシークレット（値は secrets.vault に保存）
OPENAI_API_KEY
DATABASE_PASSWORD
```

**5. `secrets.vault` は git にコミットして OK。`.env` は作らない。**

### 何も出力されず終了コード 1 になるとき

次を順に確認してください: パスフレーズ（`seal` 時と同じか）→ vault のパス（`--file` が正しいか）→ キー名（大文字・小文字含め正確か、`amulet list` で確認）→ Locked モード（seal 時と同じ machine_id を持つ環境か）。

---

## 動作モード

| モード | seal 時の入力 | 復号できるマシン |
|--------|-------------|----------------|
| **Locked**（デフォルト） | パスフレーズ + OS のマシン識別子 | 同じ machine_id を持つ環境 |
| **Portable**（`--portable`） | パスフレーズのみ | どのマシンでも可 |

ラップトップや本番サーバには Locked、CI ランナー・コンテナ・移行には Portable を推奨します。詳細は [docs/security-ja.md](docs/security-ja.md) と [docs/deployment-ja.md](docs/deployment-ja.md) を参照してください。

---

## ドキュメント

**ドキュメントサイト:** [amulet.tsukasa-art.com](https://amulet.tsukasa-art.com)

| ファイル | 内容 |
|---------|------|
| [docs/usage-ja.md](docs/usage-ja.md) | 全コマンドの引数・例・Node.js ラッパー |
| [docs/security-ja.md](docs/security-ja.md) | vault フォーマット・暗号仕様・脅威モデル |
| [docs/deployment-ja.md](docs/deployment-ja.md) | Locked/Portable 判断表・移行手順・Docker Compose |
| [docs/deploy-ubuntu-ja.md](docs/deploy-ubuntu-ja.md) | Ubuntu 24.04 LTS 本番デプロイ（systemd `LoadCredential`） |
| [docs/deploy-rootless-systemd-ja.md](docs/deploy-rootless-systemd-ja.md) | rootless デプロイ（user systemd・rootless Podman・非 root プロセス向け） |
| [docs/getting-started-ja.md](docs/getting-started-ja.md) | ターミナル・PATH・stdin/stdout 入門 |
| [docs/troubleshooting-ja.md](docs/troubleshooting-ja.md) | サイレント失敗のデバッグ・起動タイムアウト・パスフレーズローテーション・OS 再インストール |
| [docs/migration-away-ja.md](docs/migration-away-ja.md) | シークレットのエクスポートとプロジェクトからの Amulet 削除 |

---

## 実装について

Amulet v1.0.0 は **Rust** で実装されています（v0.x は Zig で実装）。

**なぜ Zig をやめたのか？**  
Zig はクロスコンパイルや C の資産を活かせるなど魅力的な開発体験を提供してくれますが、パッケージエコシステムはまだ pre-1.0 の段階にあります。Argon2id や XChaCha20-Poly1305 に相当するオーディット済みの暗号ライブラリが存在しません。また、マイナーリリース間で API の破壊的変更が入り、新しい macOS SDK への対応もリリース後しばらく遅れる傾向があり、OS アップグレード後に CI が壊れることがありました。セキュリティツールで暗号プリミティブをゼロから実装し、進化し続けるツールチェーンに追従し続けることは、リスクを減らすどころか増やすことになると判断しました。

**なぜ C ではなく Rust なのか？**  
C は同等の低レベル制御を提供しますが、コンパイル時のメモリ安全性保証がありません。シークレット管理ツールにとってこれは重要です。コンパイラによる `memset` の最適化除去や、バッファの境界外読み出しで鍵素材が静かに漏れる可能性があります。Rust はガベージコレクタなしに、所有権・use-after-free・double-free の不変条件をコンパイル時に強制します。

**なぜ Go・Python・Node ではないのか？**  
Amulet は `zeroize`（drop 時の確実なメモリ消去）と `mlock`（スワップへの流出防止）を必要とします。これらはマネージドランタイム言語では確実に制御できません。

---

## ビルド・テスト

```sh
cargo build --release   # ビルド
cargo test              # ユニットテスト
```

**対応 OS:** Linux（systemd ホスト）、macOS、Windows

---

## リリース（メンテナ向け）

`v` で始まるタグを push すると [Release ワークフロー](.github/workflows/release.yml) が走ります。手順は [RELEASING-ja.md](RELEASING-ja.md)（[English](RELEASING.md)）を参照してください。

---

## プロジェクト構成

```
amulet/
├── src/
│   ├── machine_id.rs   # OS別 machine_id 取得
│   ├── crypto.rs       # Argon2id + XChaCha20-Poly1305 暗号コア
│   ├── vault.rs        # vault ファイル I/O とロック
│   └── main.rs         # CLI ディスパッチ
├── docs/
│   ├── usage-ja.md                    # CLI リファレンス
│   ├── usage.md
│   ├── security-ja.md                 # vault フォーマット・暗号仕様・脅威モデル
│   ├── security.md
│   ├── deployment-ja.md               # 環境別運用・移行・Docker Compose
│   ├── deployment.md
│   ├── deploy-ubuntu-ja.md            # Ubuntu 本番デプロイ（root systemd + LoadCredential）
│   ├── deploy-ubuntu.md
│   ├── deploy-rootless-systemd-ja.md  # rootless デプロイ（user systemd・rootless Podman）
│   ├── deploy-rootless-systemd.md
│   ├── troubleshooting-ja.md          # サイレント失敗のデバッグ・タイムアウト・ローテーション
│   ├── troubleshooting.md
│   ├── getting-started-ja.md          # ターミナル入門
│   ├── getting-started.md
│   ├── migration-away-ja.md           # シークレットのエクスポートと Amulet の削除
│   └── migration-away.md
├── wrappers/
│   └── node/
│       └── amulet.ts       # Node.js/TypeScript ラッパー
├── PLAN_JA.md
├── CHECKLIST_JA.md
├── RELEASING-ja.md         # メンテナ: バージョンタグと GitHub Release
├── RELEASING.md
└── README_JA.md
```

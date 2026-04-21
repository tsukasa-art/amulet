# Amulet — ハードウェア紐付きゼロトレース秘密情報管理ツール

## 概要

Amulet は、秘密情報（APIキー、トークン、パスワード等）を **特定の物理マシン** に暗号化バインドする CLI ツールです。

- `.env` ファイルを一切使わない
- 秘密情報を argv や環境変数に渡さない（stdin 経由のみ）
- 復号失敗時は詳細なエラーを出さずサイレントに終了コード 1 で終了
- AI エージェントやサブプロセスへの情報漏洩を構造的に防ぐ

---

## なぜ Amulet か

Infisical・HashiCorp Vault・AWS Secrets Manager などの既存ツールはチーム共有・監査ログ・細かいアクセス制御に優れていますが、サーバーのセットアップと運用コストが伴います。

Amulet はその逆を狙っています。

| | 既存の秘密管理プラットフォーム | Amulet |
|---|---|---|
| セットアップ | サーバー・クラウド契約が必要 | バイナリ1本 |
| チーム共有 | ✅ 得意 | ❌ 設計外（1台向け） |
| ネットワーク依存 | あり | なし（完全ローカル） |
| ハードウェアバインド | なし | ✅ Locked Mode |
| AI エージェント対策 | 間接的 | 構造的に設計 |

**Amulet が向いている場面**
- 個人開発・フリーランス・一人チーム
- サーバーを立てずにローカルで完結させたい
- AI エージェントやバイブコーディングで秘密が漏れるのを構造的に防ぎたい
- 軽量なツールをすぐ使い始めたい

**Amulet が向いていない場面**
- チームで秘密を共有・ローテーションしたい → Infisical・Vault 等を検討
- CI・コンテナ環境が主体 → クラウドの Secrets Manager との併用を推奨

---

## インストール

[GitHub Releases](https://github.com/Tuki-Sana/amulet/releases) から最新バイナリをダウンロードしてください：

| OS | ファイル |
|---|---|
| Linux (x86_64) | `amulet-linux-x86_64` |
| macOS (Apple Silicon) | `amulet-macos-aarch64` |
| macOS (Intel) | `amulet-macos-x86_64` |
| Windows (x86_64) | `amulet-windows-x86_64.exe` |

**Linux / macOS:**
```sh
chmod +x amulet-linux-x86_64
mv amulet-linux-x86_64 /usr/local/bin/amulet
```

**Windows:** `amulet.exe` にリネームして `PATH` の通ったディレクトリに配置してください。

---

## クイックスタート（バイブコーディング・AI 開発向け）

> AI ツール（Cursor・Claude Code 等）を使って開発する場合、AI が `.env` パターンを提案することがあります。このプロジェクトでは代わりに Amulet を使います。Amulet は秘密情報を漏洩しやすい経路から遠ざけますが、チャットへの貼り付けや AI の古い提案は別の問題です — 運用習慣も合わせて意識してください。

**1. vault を初期化する**

```sh
amulet init --file secrets.vault
```

**2. シークレットを登録する（`.env` への書き込みの代わりに）**

```sh
echo -n "sk-xxxxxxxx" | amulet seal OPENAI_API_KEY --file secrets.vault
```

**3. コードから使う**

```typescript
// ❌ やらないこと
const key = process.env.OPENAI_API_KEY;

// ✅ Amulet を使う
await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
  await callOpenAI(secret);
});
```

**4. 必要なキー名だけ記録する（`.env.example` の代わりに）**

```
# 必要なシークレット（値は vault に保存）
OPENAI_API_KEY
DATABASE_PASSWORD
```

**5. `secrets.vault` は git にコミットして OK。`.env` は作らない。**

---

## 動作モード

### Locked Mode（デフォルト）

vault を作成したマシン以外では復号できない。

```
KDF 入力 = Argon2id(passphrase ‖ 0x00 ‖ machine_id, salt)
```

- Linux: `/etc/machine-id`（fallback: `/var/lib/dbus/machine-id`）
- macOS: `IOPlatformUUID`（`ioreg` 経由）
- Windows: `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`（`reg query` 経由）

### Portable Mode（`--portable` 付きで seal した場合）

machine_id を KDF に混ぜない。別マシンへの移行や検証用途向け。

```
KDF 入力 = Argon2id(passphrase, salt)
```

- vault ヘッダの `flags` bit 0 が 1 にセットされる
- `unseal` 時はヘッダを自動読み取りモード判定（ユーザーが `--portable` を指定する必要なし）
- セキュリティが低下するため、seal 時に警告メッセージを stderr に出力する

---

## Vault ファイルフォーマット（バイナリ）

```
[1 byte]  version  = 0x01
[1 byte]  flags    (bit 0 = portable mode)
[16 byte] Argon2id salt  （CSPRNG ランダム、seal ごとに生成）
[12 byte] ChaCha20-Poly1305 nonce （CSPRNG ランダム、seal ごとに生成）
[4 byte]  ciphertext 長（big-endian u32）
[N byte]  ciphertext + 16 byte Poly1305 認証タグ
```

---

## 暗号仕様

| 項目 | 仕様 |
|------|------|
| KDF | Argon2id（m=64MiB, t=3, p=1） |
| 暗号化 | ChaCha20-Poly1305 |
| 鍵長 | 256 bit（32 byte） |
| ソルト | 16 byte CSPRNG（vault ヘッダに保存） |
| Nonce | 12 byte CSPRNG（vault ヘッダに保存、再利用なし） |
| AAD | version バイト（フォーマット変更検知用） |

---

## CLI 使い方

### 初期化

```sh
amulet init --file secrets.vault
```

空の vault ファイルを作成する。

### 秘密情報の書き込み（seal）

```sh
# Locked Mode（デフォルト）: パスフレーズを /dev/tty でプロンプト入力、秘密情報は stdin から
echo -n "sk-xxxxxxxx" | amulet seal OPENAI_API_KEY --file secrets.vault

# Portable Mode: --portable フラグを追加（警告が stderr に出力される）
echo -n "sk-xxxxxxxx" | amulet seal --portable OPENAI_API_KEY --file secrets.vault
```

> `seal` はパスフレーズを `/dev/tty` から読み取ります（エコーオフ）。秘密情報は stdin のみ。

### 秘密情報の読み出し（unseal）

stdin の第1行をパスフレーズとして読み取ります。vault ヘッダから Locked / Portable モードを自動判定します。

**対話入力**（ターミナルで直接使う場合）

```sh
# --tty: /dev/tty からエコーオフでパスフレーズを入力（seal と同じ動作）
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# --tty なし: stdin 第1行をそのまま読む（プロンプト・エコーオフなし）
amulet unseal OPENAI_API_KEY --file secrets.vault
```

> `--tty` なしでターミナルから入力すると、パスフレーズが画面にエコーされます。手元で使う場合は `--tty` を推奨します。

**パイプ入力**（スクリプトや CI で使う場合）

```sh
# パスフレーズをパイプで渡す
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# シェル変数に代入
SECRET=$(printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault)
```

> CI では `printf` の代わりに CI プラットフォームのシークレット注入（GitHub Actions secrets 等）を使用してください。ターミナルで手動 `export` するとシェル履歴に残るため避けること。

**スクリプトでの終了コード確認**

```sh
if ! printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > /dev/null; then
  echo "unseal failed" >&2
  exit 1
fi
```

- 成功時: 秘密情報を stdout に出力（末尾改行なし）
- 失敗時: 何も出力せず終了コード 1 で終了（診断メッセージなし）

### Node.js / TypeScript からの利用

```typescript
import { withSecret } from './wrappers/node/amulet';

// パスフレーズの受け取り方は「漏れやすい経路を避ける」が基本方針。
// CI/CD のシークレット注入（GitHub Actions secrets 等）は許容範囲内。
// ターミナルでの手動 export や .env への平文書き込みは、シェル履歴・AI ツールの文脈に残るため避けること。
const passphraseBuf = Buffer.from(process.env.VAULT_PASSPHRASE!, 'utf8');

await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
  // secret は Buffer 型。このコールバック内でのみ有効。
  // 文字列にキャストしない。
  await callExternalApi(secret);
});
// コールバック完了後、secret Buffer は自動的にゼロ埋めされる。
// コールバックが例外をスローした場合もゼロ埋めは保証される。
```

> `withSecret` の `binaryPath` オプションで `amulet` バイナリのパスを指定できます（デフォルトは PATH 検索）。

---

## ファイル命名規則

| ファイル | 命名例 | 説明 |
|----------|--------|------|
| vault（暗号化済みバイナリ） | `secrets.vault`, `prod.vault` | `*.vault` 拡張子推奨。git 管理可。 |
| 一時 .env（開発用ブリッジ） | `.env.tmp`, `.secrets.env` | 必ず `.gitignore` に追加。平文がディスクに出ることを意識すること。 |

`*.vault` ファイルは暗号化済みバイナリなので git にコミットして問題ありません。  
平文 `.env` を生成する場合は開発用ブリッジと位置づけ、`trap` による削除と `.gitignore` 登録を徹底してください。

---

## Docker Compose / Podman Compose との連携

vault を Compose ベースのワークフローに統合するには、**一時ファイル経由**が最も安定した方法です。

```sh
TMP_ENV=$(mktemp)
chmod 0600 "$TMP_ENV"
trap "rm -f '$TMP_ENV'" EXIT

printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > "$TMP_ENV"

docker compose --env-file "$TMP_ENV" up
# Podman の場合: podman compose --env-file "$TMP_ENV" up
```

> **注意:** 一時ファイルはディスクに短時間平文が出ます。「開発用ブリッジ」と位置づけ、`trap` による削除を必ず設定してください。本番環境では CI のシークレット注入（GitHub Actions secrets 等）を使用してください。

プロセス置換（`<(amulet unseal …)`）も機能しますが、bash 依存で Compose の実行環境によって挙動が変わるため、上記の一時ファイル方式を推奨します（上級者向け）。

---

## 環境別運用ガイド：Locked vs Portable

Locked Mode では、vault は別マシンに持ち出せても**別マシンでは復号できません**（ciphertext のコピー自体は可能）。デフォルトはローカル／単一ホスト向けの設計で、CI やコンテナでは Portable や他ツールとの組み合わせが基本です。

| 環境 | 推奨モード | 理由 |
|------|-----------|------|
| 本番の固定サーバ | **Locked** | machine_id が安定している。vault をコピーされても別マシンでは復号不可 |
| 開発者の個人PC | **Locked**（各自） | 各開発者が自分のマシンで seal する |
| CI（GitHub Actions 等） | **Portable** | ランナーが毎回変わり machine_id が安定しない |
| コンテナ / Kubernetes | **Portable** | Pod の machine_id が安定しないことが多い |
| 移行・検証用途 | **Portable** | 別マシンでの復号が意図的に必要な場合 |

> **OS 再インストール・ハードウェア交換時の注意:** machine_id が変わると Locked vault は復号不能になります（Linux: OS 再インストール、macOS: マザーボード交換）。runbook に復旧手順を記載してください。

**チームでの運用パターン**

シンプルで拡張しやすい基本方針：

- 本番ホスト: サーバ上で seal・unseal（Locked）
- CI・ステージング: CI プラットフォームのシークレット注入か、強いパスフレーズを使った Portable vault
- Locked vault はマシン間で共有しない — 各環境が自前で seal する

---

## 移行・複数端末・障害時の注意

### vault ファイルのバックアップと「復号できるバックアップ」は別物

Locked vault のファイルをコピーしてもバックアップにはなりません。別マシンでは machine_id が異なるため復号できないからです。

| バックアップの種類 | 内容 | Locked での復旧 |
|------------------|------|----------------|
| vault ファイルのコピー | 暗号化済みバイナリ | ❌ 別マシンでは復号不可 |
| 旧マシンで unseal した平文 | 秘密情報の生データ | ✅ 新マシンで re-seal できる |
| Portable vault のコピー | パスフレーズさえあれば復号可 | ✅ どのマシンでも復号可 |

### 計画的なマシン移行

旧マシンが生きている間に次の手順を踏んでください：

```sh
# 旧マシンで unseal して平文を取り出す
printf "mypassphrase\n" | amulet unseal SECRET_KEY --file secrets.vault

# 新マシンで re-seal（Locked なら新マシンの machine_id にバインドされる）
echo -n "<取り出した値>" | amulet seal SECRET_KEY --file secrets.vault
```

### 突然の故障

旧マシンが起動しなくなった場合、Locked vault は**復号できません**。事前の対策が必要です：

- 秘密情報を別の安全な場所（パスワードマネージャー等）にも保管しておく
- または Portable vault を別途作成してオフラインバックアップとして保管する

### 複数端末での開発

同じ Locked vault を複数端末で共有することはできません。以下のいずれかを選んでください：

- **端末ごとに別 vault** — 各端末で seal する（Locked のまま、端末ごとに独立）
- **Portable vault を共有** — パスフレーズを安全に共有し、全端末で同じ vault を使う
- **開発だけ Portable、本番は Locked** — 環境で使い分ける

---

## セキュリティ設計原則

| 原則 | 内容 |
|------|------|
| No .env Policy | ディスクへの平文書き込みは開発用途でも一切実装しない |
| Silent Failure | 復号失敗時は詳細エラーなし、終了コード 1 のみ |
| No Leakage | ログ・エラーに秘密情報・machine_id・鍵断片を含まない |
| Immediate Erasure | `std.crypto.utils.secureZero` で使用直後にメモリ抹消 |
| Stdin Only | 秘密情報は argv・環境変数経由で受け取らない |

---

## ビルド・テスト

```sh
# ビルド（ReleaseSafe 推奨）
zig build -Doptimize=ReleaseSafe

# machine-ID 取得の動作確認
zig build probe

# 全ユニットテスト
zig build test
```

**対応 OS:** Linux（systemd ホスト）、macOS、Windows

---

## プロジェクト構成

```
amulet/
├── src/
│   ├── probe_id.zig   # OS別 machine-ID 取得
│   ├── crypto.zig     # Argon2id + ChaCha20-Poly1305 暗号コア
│   ├── main.zig       # CLI (seal / unseal / init)
│   └── schema.zig     # comptime キー名バリデーション
├── wrappers/
│   └── node/
│       └── amulet.ts  # Node.js/TypeScript ラッパー
├── PLAN.md
├── CHECKLIST.md
└── README_JA.md
```

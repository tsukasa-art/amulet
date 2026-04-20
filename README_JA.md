# Amulet — ハードウェア紐付きゼロトレース秘密情報管理ツール

## 概要

Amulet は、秘密情報（APIキー、トークン、パスワード等）を **特定の物理マシン** に暗号化バインドする CLI ツールです。

- `.env` ファイルを一切使わない
- 秘密情報を argv や環境変数に渡さない（stdin 経由のみ）
- 復号失敗時は詳細なエラーを出さずサイレントに終了コード 1 で終了
- AI エージェントやサブプロセスへの情報漏洩を構造的に防ぐ

---

## 動作モード

### Locked Mode（デフォルト）

vault を作成したマシン以外では復号できない。

```
KDF 入力 = Argon2id(passphrase ‖ 0x00 ‖ machine_id, salt)
```

- Linux: `/etc/machine-id`（fallback: `/var/lib/dbus/machine-id`）
- macOS: `IOPlatformUUID`（`ioreg` 経由）

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

**対応 OS:** Linux（systemd ホスト）、macOS

---

## プロジェクト構成

```
amulet/
├── src/
│   ├── probe_id.zig   # Phase 2: OS別 machine-ID 取得
│   ├── crypto.zig     # Phase 3a: Argon2id + ChaCha20-Poly1305 暗号コア
│   ├── main.zig       # Phase 3b: CLI (seal / unseal / init)
│   └── schema.zig     # comptime キー名バリデーション
├── wrappers/
│   └── node/
│       └── amulet.ts  # Phase 4: Node.js/TypeScript ラッパー
├── PLAN.md
├── CHECKLIST.md
└── README_JA.md
```

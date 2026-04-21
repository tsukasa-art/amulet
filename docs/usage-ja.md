# Amulet — CLI 使い方リファレンス

## コマンド早見表

| コマンド | 書式 | パスフレーズ |
|---------|------|------------|
| `init` | `amulet init [--file <vault>]` | 不要 |
| `seal` | `amulet seal [--portable] <key> [--file <vault>]` | 必要（TTY） |
| `unseal` | `amulet unseal [--tty] <key> [--file <vault>]` | 必要（stdin または TTY） |
| `verify` | `amulet verify [--tty] <key> [--file <vault>]` | 必要（stdin または TTY） |
| `re-seal` | `amulet re-seal <key> [--file <vault>]` | 必要（旧・新、TTY） |
| `import` | `amulet import --env-file <path> [--portable] [--manifest <path>] [--wipe] [--file <vault>]` | 必要（TTY） |
| `list` | `amulet list [--file <vault>]` | 不要 |
| `delete` | `amulet delete <key> [--file <vault>]` | 不要 |
| `rename` | `amulet rename <old> <new> [--file <vault>]` | 不要 |
| `probe` | `amulet probe` | 不要 |
| `version` | `amulet version` | 不要 |
| `help` | `amulet help` \| `-h` \| `--help` | 不要 |

`--file <vault>` を省略すると、カレントディレクトリの `amulet.vault` が使われます。

---

## init

```sh
amulet init --file secrets.vault
```

空の vault ファイルを作成します（Unix では mode `0600`）。パスフレーズは聞かれません。ファイルが既に存在する場合は終了コード 1 で失敗します。

---

## seal

```sh
# Locked Mode（デフォルト）: このマシンのハードウェア ID にバインド
echo -n "your-secret-value" | amulet seal OPENAI_API_KEY --file secrets.vault

# Portable Mode: パスフレーズのみ、ハードウェアバインドなし
echo -n "your-secret-value" | amulet seal --portable OPENAI_API_KEY --file secrets.vault
```

- パスフレーズは `/dev/tty` でプロンプト（エコーオフ）。秘密は **stdin** のみから読み取ります（argv には載りません）。
- キーが既に存在する場合はエントリを上書きします。
- `--portable` は stderr に警告を出力し、vault ヘッダにフラグをセットします（`unseal` 時に自動読み取り）。

> **シェル履歴:** `echo '…' | …` は履歴に残ることがあります。自動化では CI のシークレット注入など安全な方法を推奨します。
> bash では `HISTCONTROL` を `ignorespace` または `ignoreboth` に設定した上でコマンドを先頭スペース付きで入力すると記録を抑制できますが、これはシェルや設定に依存し全環境で有効ではありません。zsh での相当オプションは `setopt HIST_IGNORE_SPACE` です。確実な方法を求めるなら、`echo` の使用自体を避け、シークレットストアやファイル経由での入力を選んでください。

---

## unseal

```sh
# 対話: /dev/tty でエコーオフプロンプト
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# スクリプト・CI: stdin 第1行がパスフレーズ
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# シェル変数に代入
SECRET=$(printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault)
```

- Locked / Portable モードは vault ヘッダから**自動判定**（フラグ不要）。
- 成功時: 秘密を **stdout** に出力（末尾改行なし）、終了コード 0。
- 失敗時: **何も出力せず**終了コード 1。

**スクリプトでの終了コード確認:**

```sh
if ! printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > /dev/null; then
  echo "unseal failed" >&2; exit 1
fi
```

**何も出力されずに失敗するとき:** 次を順に確認してください。
1. **パスフレーズ** — `seal` 時と同じか。パイプで渡す場合は末尾改行まで一致しているか。
2. **vault のパス** — `--file` が正しいファイルを指し、ファイルが存在するか。
3. **キー名** — 大文字・小文字を含め正確か（`amulet list` で確認）。
4. **Locked モード** — このマシンで seal したエントリか。別マシンからコピーしただけでは失敗します。
5. **終了コード** — `echo $?`（Unix）または `echo $LASTEXITCODE`（PowerShell）が `1` か確認。

---

## verify

```sh
# stdin からパスフレーズを渡す
printf "mypassphrase\n" | amulet verify OPENAI_API_KEY --file secrets.vault

# /dev/tty でエコーオフプロンプト
amulet verify --tty OPENAI_API_KEY --file secrets.vault
```

復号後すぐに平文を破棄します。成功時は何も出力せず終了コード 0、失敗時は終了コード 1。ヘルスチェックや CI の起動前確認で秘密の値を露出せずに使えます。

---

## re-seal

```sh
amulet re-seal OPENAI_API_KEY --file secrets.vault
```

現在のパスフレーズ・新しいパスフレーズ・確認入力の 3 つを `/dev/tty` でエコーオフプロンプトします。新パスフレーズと確認が一致しない場合は stderr に一文出力して終了コード 1。モード（Locked/Portable）は元のエントリから引き継ぎます。

---

## import

```sh
# 基本インポート
amulet import --env-file .env --file secrets.vault

# キー名だけのマニフェストを生成（値は含まない）
amulet import --env-file .env --file secrets.vault --manifest .env.example

# インポート成功後に .env の値をゼロ上書き（ベストエフォート）
amulet import --env-file .env --file secrets.vault --wipe

# Portable モード
amulet import --env-file .env --file secrets.vault --portable
```

- `KEY=VALUE` 行を読み込みます（空行・`#` コメントはスキップ）。
- クォートや `export KEY=…` 形式は非対応 — インポート前に除去してください。
- パスフレーズは全エントリで1回のみプロンプトします。
- 既存キーは上書きされます。

`--manifest <path>` はキー名を1行1件で出力します（既存ファイルは上書き）。`.env` の代わりにこのファイルを git にコミットすると、必要な秘密の一覧をチームで共有できます。

`--wipe` は vault 書き込み成功後に `.env` の各値部分をスペースで上書きします。ベストエフォートであり、SSD では物理消去は保証されません。wipe に失敗した場合は警告を stderr に出力して終了コード 1 で終了します。

---

## list

```sh
amulet list --file secrets.vault
```

登録済みキー名を1行1件で出力します。パスフレーズ不要。vault が無い・読めない・壊れている場合は終了コード 1。

---

## delete

```sh
amulet delete OPENAI_API_KEY --file secrets.vault
```

該当エントリを vault から削除します（パスフレーズ不要）。キーが無い・vault が無い・ファイルが無効な場合は終了コード 1。

---

## rename

```sh
amulet rename OLD_KEY_NAME NEW_KEY_NAME --file secrets.vault
```

vault インデックス上のキー名だけを変更します（パスフレーズ不要・blob の再暗号化なし）。旧キーが無い・新キーが既に存在する・vault が無効な場合は終了コード 1。

---

## probe

```sh
amulet probe
```

Locked モードの seal と同じ取得元のマシン識別子を出力します（トラブルシュート用）。この OS で取得できない場合は終了コード 2。

---

## バージョン・ヘルプ

```sh
amulet version    # リリースタグを表示（例: v0.1.2）
amulet help       # -h または --help と同義
```

---

## Node.js / TypeScript からの利用

`wrappers/node/amulet.ts` をプロジェクトにコピーして使います。内部で `amulet unseal` を起動し、結果を不透明な `Buffer` としてコールバックに渡し、終了後に自動でゼロ埋めします。

```typescript
import { withSecret } from './wrappers/node/amulet';

const passphraseBuf = Buffer.from(process.env.VAULT_PASSPHRASE!, 'utf8');

await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
  // secret は Buffer 型。このコールバック内でのみ有効。
  // 文字列にキャストしない。コールバックの外に持ち出さない。
  await callExternalApi(secret);
});
// コールバック完了後（例外時も）、Buffer は自動的にゼロ埋めされます。
```

`binaryPath` オプションで `amulet` バイナリのパスを指定できます（デフォルトは PATH 検索）。

---

## ファイル命名規則

| ファイル | 命名例 | 説明 |
|----------|--------|------|
| vault（暗号化済み） | `secrets.vault`, `prod.vault` | git 管理可。`*.vault` 拡張子推奨。 |
| 一時 .env | `.env.tmp`, `.secrets.env` | `.gitignore` に必ず追加。平文がディスクに出る点を意識すること。 |

平文 `.env` を生成する場合は開発用ブリッジと位置づけ、`trap` による削除と `.gitignore` 登録を徹底してください。

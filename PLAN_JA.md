# Amulet — マスタープラン
ハードウェア紐付きゼロトレース秘密情報管理システム

---

## ビジョン

Amulet は、秘密情報を特定の物理マシンに暗号化バインドする CLI ツールです。
平文の秘密情報はディスクに一切書き込まれません。`.env` ファイルも不要です。
AI エージェントやサブプロセスへの漏洩経路を構造的に排除します。
マシン違い・パスフレーズ違い・バイナリ改ざん時の復号は、すべてサイレントに失敗します。

---

## マイルストーン

### M1 — 環境調査（フェーズ2） ✅

暗号コードに着手する前に、各対象 OS でのハードウェア ID 取得を検証します。

| OS     | 取得元                              | コマンド / API                                                        |
|--------|-------------------------------------|-----------------------------------------------------------------------|
| Linux  | `/etc/machine-id`                   | `std.fs.File.readAll`                                                 |
| macOS  | IOPlatformUUID（IOKit レジストリ）  | `ioreg -rd1 -c IOPlatformExpertDevice` をシェルアウトして取得         |

成果物: 両プラットフォームでトリム済み UUID を表示し、取得不可なら非ゼロ終了する単体プログラム `probe_id.zig`

---

### M2 — 暗号コア（フェーズ3a） ✅

ファイル: `src/crypto.zig`

**鍵導出（KDF）**
- アルゴリズム: **Argon2id**（メモリハード、サイドチャネル耐性あり）
- Locked Mode の入力: `passphrase ‖ 0x00 ‖ machine_id` + vault ヘッダの 16 バイトランダムソルト
- Portable Mode の入力: `passphrase` のみ + 同じ 16 バイトランダムソルト（machine_id は混入しない）
- ソルト: 常に CSPRNG による 16 バイト乱数。`seal` 時に生成し vault ヘッダに保存。両モード共通。
- パラメータ（初期値、調整可能）:
  - `m_cost`: 65536 KiB（64 MiB）
  - `t_cost`: 3 回
  - `parallelism`: 1
- 出力: 32 バイト導出鍵

**暗号化**
- アルゴリズム: **ChaCha20-Poly1305**（推奨 — 全プラットフォームで定数時間、ハードウェア依存なし）
- AES-256-GCM はハードウェア AES 環境向けのコンパイル時代替として利用可能
- Nonce: `std.crypto.random` による 12 バイト乱数
- AAD: vault フォーマットのバージョンバイト（将来の互換性のため）

**vault ファイルフォーマット**（バイナリ固定レイアウト）

```
[1 byte]  version = 0x01
[1 byte]  flags   (bit 0 = portable mode)
[16 byte] Argon2id ソルト
[12 byte] ChaCha20-Poly1305 nonce
[4 byte]  暗号文長（big-endian u32）
[N byte]  暗号文 + 16 バイト Poly1305 認証タグ
```

**メモリ安全性**
- 鍵マテリアルはすべて `[32]u8` スタック配列に格納
- `std.crypto.utils.secureZero` を `defer` ブロックで最終使用直後に呼び出す
- 秘密情報のヒープ割り当てなし（KDF 入力バッファはゼロ埋め後に解放）

---

### M3 — CLI（フェーズ3b） ✅

ファイル: `src/main.zig`

```
amulet seal   [--portable] <key> [--file <vault>]
amulet unseal               <key> [--file <vault>]
amulet init                      [--file <vault>]
```

**`seal`** — stdin から秘密情報を読み取り（argv 経由は不可）、暗号化して vault に追記・更新します。`--portable` を指定すると vault ヘッダの `flags` bit 0 がセットされます。パスフレーズは `/dev/tty` からエコーオフで入力します。

**`unseal`** — vault ヘッダの `flags` バイトを読んで Locked / Portable モードを自動判定します。`--portable` フラグは不要（受け付けません）。復号した秘密情報を stdout のみに出力します。失敗時は診断メッセージなしで終了コード 1 で即終了します。

**`init`** — 空の vault ファイルをパーミッション 0600 で新規作成します。

**stdin プロトコル**:
- `seal`: `/dev/tty` でパスフレーズ入力後、stdin の全バイトを秘密情報として読み取ります（末尾改行は含まれない）。
- `unseal`: stdin の第 1 行をパスフレーズとして読み取り、秘密情報を stdout に出力します。

**vault 内エントリ形式**（マルチキー対応）:

```
[2 byte big-endian]  キー名長
[キー名長 byte]      キー名（平文）
[4 byte big-endian]  crypto blob 長
[blob 長 byte]       crypto blob（上記バイナリフォーマット）
```

---

### M4 — 統合ラッパー（フェーズ4） ✅

ファイル: `wrappers/node/amulet.ts`

Node.js/TypeScript モジュールの仕様:
1. `amulet unseal <key>` を子プロセスとして spawn する
2. stdout（秘密情報）を `Buffer` に読み込む（`string` には変換しない）
3. コンシューマーコールバックに渡す
4. コールバック完了後に `Buffer` をゼロ埋め（`buf.fill(0)`）する
5. ログ出力・文字列化は一切行わない

Node.js ラッパーが生の鍵マテリアルに直接アクセスすることはなく、不透明な `Buffer` 参照のみを扱います。

---

## OS 別戦略まとめ

| 懸念事項             | Linux                                   | macOS                               |
|----------------------|-----------------------------------------|-------------------------------------|
| マシン ID 取得元     | `/etc/machine-id`（128 bit hex + 改行） | `IOPlatformUUID`（`ioreg` 経由）    |
| 可用性               | systemd ホストで保証                    | 全モダン macOS で保証               |
| 安定性               | 再起動で維持、再インストールで変わる    | 再起動で維持、マザーボード交換で変わる |
| フォールバック       | `/var/lib/dbus/machine-id`              | 不要                                |
| Portable モード回避  | `--portable` で machine_id をスキップ   | 同左                                |

---

## 非目標（スコープ外）

- Windows サポート（対象外）
- ネットワーク紐付き鍵管理（TPM/HSM 統合は将来の検討事項）
- 秘密情報のローテーション自動化
- マルチユーザーによる vault 共有

# Amulet — 実装チェックリスト

コミットのたびに確認するセキュリティ・正確性の項目です。実装済みになったらチェックを入れ、リファクタリングで該当コードに触れた場合は再開してください。

---

## メモリ安全性

- [x] 秘密情報バッファはすべてスタック確保の `[N]u8` 配列 — 鍵マテリアルのヒープ割り当てなし
- [x] すべての秘密情報バッファに `defer std.crypto.utils.secureZero(u8, &buf)` を宣言直後に記述
- [x] `secureZero` の適用対象: パスフレーズ入力・machine_id バイト列・導出鍵（kdf_input 含む）・復号後の平文（解放前）
- [x] 秘密情報を `const` バインディングでスコープ外まで保持しない（コンパイラがゼロ化をスキップする最適化を防ぐ）
- [x] nonce とソルトの生成には `std.crypto.random.bytes` を使用 — カウンタやタイムスタンプは不可

---

## エラー処理とサイレント失敗

- [x] 復号エラー（`AuthenticationFailed`、マシン違い、ファイル未存在など）はすべて **stderr への出力なし**、終了コード **1** で即終了
- [x] `seal` エラー（ディスク満杯、権限エラーなど）は汎用メッセージ（"seal failed: …"）のみ出力 — 秘密情報・キー名・導出鍵は一切含まない
- [x] `std.debug.panic` と `unreachable` の経路を監査 — 攻撃者制御入力でいずれも発生しないことを確認
- [x] 鍵マテリアルを含むエラー共用体のペイロードを `{any}` や `{s}` でフォーマットしない

---

## 情報漏洩防止

- [x] `std.log` を使用しない — どのビルドモードでもログ出力なし
- [x] vault ファイルパスを復号エラーメッセージに含めない
- [x] machine_id の値をログ・出力・ユーザー向けメッセージに含めない
- [x] Argon2id ソルトを vault ヘッダ外に出力・公開しない
- [x] `amulet unseal` は秘密情報を **stdout（fd 1）にのみ** 書き込む — stderr（fd 2）には書かない

---

## KDF パラメータ

- [x] Argon2id `m_cost` = 65536 KiB（64 MiB）— GPU 攻撃への耐性
- [x] Argon2id `t_cost` = 3 回 — 時間・メモリトレードオフ攻撃への耐性
- [x] ソルトは CSPRNG による 16 バイト乱数（vault ヘッダに保存）— どちらのモードでもハードコードしない
- [x] `--portable` モードでは、同じ 16 バイト CSPRNG ソルトを Argon2id に使用し、machine_id を KDF 入力に混入しない。vault ヘッダ `flags` bit 0 をセット
- [x] 導出鍵は正確に 32 バイト

---

## 暗号化の正確性

- [x] nonce は CSPRNG による 12 バイト乱数 — `seal` 呼び出しをまたいで **再利用しない**（毎回新規生成）
- [x] Poly1305 タグ（16 バイト）を検証してから平文の 1 バイトも呼び出し元に返さない（`ChaCha20Poly1305.decrypt` は AEAD として一括検証）
- [x] AAD（バージョンバイト）を認証 — フォーマットバージョンが異なる vault は認証失敗
- [x] 復号試行前に vault フォーマットバージョンバイトを確認
- [x] 暗号文長フィールドをメモリ割り当て前に `max_plaintext_len`（64 KiB）と照合して検証

---

## マシン ID バインディング

- [x] machine_id を KDF 入力として使用する前に空白・改行をトリム（Linux: `std.mem.trim`、macOS: UUID を直接抽出）
- [x] Linux: まず `/etc/machine-id` を試み、次に `/var/lib/dbus/machine-id` にフォールバック。両方なければ終了コード 1（弱い値へのサイレントフォールバックなし）
- [x] macOS: `ioreg` 出力から UUID をパース。パース失敗時は終了コード 1
- [x] machine_id をパスフレーズと `passphrase ‖ 0x00 ‖ machine_id` として結合（null セパレータで長さ拡張攻撃を防ぐ）
- [x] KDF 呼び出し後に machine_id バイトをゼロ埋め（`deriveKey` 内の `kdf_input` secureZero と `main.zig` の呼び出し元両方で実施）

---

## CLI と入力処理

- [x] 秘密情報の値は **stdin からのみ** 読み取る — argv・環境変数・ファイル経由は不可
- [x] キー名（argv）は vault の暗号文に含まれない — 平文エントリインデックスとして crypto blob の外側に保存
- [x] `seal` の `--portable` フラグ使用時は stderr に警告を出力: "WARNING: portable mode reduces security"
- [x] `unseal` は vault ヘッダの `flags` バイトを読んでモードを自動判定 — `--portable` フラグは受け付けない
- [x] `unseal` は未知の `flags` ビットを拒否（将来の拡張に備えたフォワードコンパティビリティ）
- [x] vault ファイルを `O_NOFOLLOW` で開く — シンボリックリンク攻撃を防止
- [x] vault ファイルの新規作成時にパーミッションを `0600` に設定（`init` コマンドと `seal` の一時ファイル両方）

---

## ビルドとリリース

- [x] リリースビルドは `-Doptimize=ReleaseSafe` を使用（`ReleaseFast` 不可）— 安全性チェックを維持。CI と README で明示。
- [ ] `std.builtin.mode` アサーション: `Debug` ビルドかつ `--portable` 未指定時にパニック（開発時ガード）— **スキップ**: 開発中に Locked を Debug で試せなくなるコストが大きい。ReleaseSafe の強制は CI と README で代替。
- [x] リリース時のデバッグシンボル削除 — `build.zig` に `-Dstrip` オプションを追加済み。リリースワークフロー（`release.yml`）で `-Dstrip=true` を適用。
- [x] CI が Linux・macOS・Windows の全ランナーで `zig build test` を実行（`.github/workflows/ci.yml`）

---

## 統合ラッパー（Node.js）

- [x] 秘密情報を `Buffer` として保持し、`string` に変換しない
- [x] コンシューマーコールバック完了後に `finally` ブロックで `Buffer.fill(0)` を呼び出す（コールバックが例外をスローしても保証）
- [x] 子プロセスの stdout は上限 64 KiB で受信 — 不正な vault による OOM を防止
- [x] 子プロセスの stderr を破棄（ログ出力しない）
- [x] ラッパーは秘密情報を文字列型パラメータとして受け取らず、文字列型として返さない

---

## 脅威モデル早見表

| 脅威                              | 対策                                                    |
|-----------------------------------|---------------------------------------------------------|
| AI エージェントが環境変数を読む   | `.env` なし — 秘密情報は vault ファイルのみに存在       |
| プロセスリスト / argv の盗み見    | 秘密情報は argv でなく stdin から読み取る               |
| vault を別マシンにコピー          | Locked Mode で Argon2id が machine_id にバインド        |
| 弱いパスフレーズ                  | 高メモリコストの Argon2id ストレッチング                |
| コールドブート / メモリダンプ     | 使用後に `secureZero`、ヒープ割り当てなし               |
| ログインジェクション / 情報漏洩   | 秘密情報のログ出力なし、サイレント失敗                  |
| vault ファイルへのシンボリックリンク攻撃 | open 時に `O_NOFOLLOW`                           |
| nonce の再利用                    | `seal` 呼び出しごとに CSPRNG で新規 nonce 生成          |

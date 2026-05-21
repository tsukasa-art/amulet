# Amulet — 実装チェックリスト（Rust v1.0）

コミットのたびに確認するセキュリティ・正確性の項目です。
実装済みになったらチェックを入れ、リファクタリストで該当コードに触れた場合は再確認してください。

---

## メモリ安全性

- [ ] 秘密情報バッファには `#[derive(Zeroize, ZeroizeOnDrop)]` を付与した構造体を使う — スコープ離脱時に自動ゼロ化
- [ ] `ZeroizeOnDrop` の適用対象: `Passphrase`・`MachineId`・`DerivedKey`・`Plaintext` の各ラッパー型
- [ ] 手動ゼロ化が必要な場所では `zeroize::Zeroize::zeroize()` を `drop()` の直前に呼ぶ
- [ ] 中間バッファ（`kdf_input`・`ciphertext` 等）も `Zeroize` を実装した型で保持する
- [ ] nonce とソルトの生成には `OsRng` を使用 — `rand::thread_rng` やカウンタ・タイムスタンプは不可
- [ ] `clone()` で秘密情報を複製しない — 複製先がゼロ化されない可能性がある
- [ ] 秘密情報を `Debug` トレイト経由で出力できない — `#[derive(Debug)]` を付与しない、または `fmt::Debug` を空実装する

---

## mlock（スワップ防止）

- [ ] passphrase・derived_key・plaintext バッファを確保後、`memsec::mlock(ptr, len)` を呼ぶ
- [ ] `mlock` 失敗時は `eprintln!("warning: mlock failed, secrets may appear in swap")` のみ — 終了しない
- [ ] 対応する `munlock` をバッファ解放前に呼ぶ（`ZeroizeOnDrop` のカスタム `Drop` 実装で行う）
- [ ] `mlock` は POSIX のみ有効。Windows では `VirtualLock` が等価（`memsec` が内部で分岐）

---

## エラー処理とサイレント失敗

- [ ] `AmuletError::DecryptFailed` の `#[error("")]` — メッセージが空文字であることを確認
- [ ] 復号失敗（パスフレーズ誤り・machine_id 不一致・改ざん）は stderr に何も出さず `exit(1)`
- [ ] `seal` 失敗は汎用メッセージ（"seal failed: …"）のみ — 秘密情報・キー名・導出鍵を含まない
- [ ] `thiserror` の `#[from]` で自動変換されるエラーに秘密情報が混入しないことを確認
- [ ] `unwrap()` / `expect()` はリリースビルドで panic → `exit(1)` になることを確認（panic handler）
- [ ] `panic!()` の引数に秘密情報を渡さない

---

## 情報漏洩防止

- [ ] `log` クレート・`println!` マクロをプロダクションコードで使用しない
- [ ] vault ファイルパスを復号エラーメッセージに含めない
- [ ] machine_id の値をログ・出力・ユーザー向けメッセージに含めない
- [ ] Argon2id ソルトを vault 外に出力・公開しない
- [ ] `unseal` は秘密情報を **stdout（fd 1）にのみ** 書き込む — `eprintln!` 経由で fd 2 に出さない
- [ ] エラー型の `Display` 実装が秘密情報を含まないことを確認（`thiserror` のフォーマット文字列を監査）

---

## KDF パラメータ

- [ ] `argon2::Argon2::new(Algorithm::Argon2id, Version::V0x13, params)` を使用
- [ ] `m_cost` = 65536（64 MiB）
- [ ] `t_cost` = 3
- [ ] `p_cost` = 1
- [ ] ソルトは `OsRng` による 16 バイト乱数 — ハードコード・再利用不可
- [ ] Locked mode: `password = passphrase ‖ [0x00] ‖ machine_id`（`[0x00]` は null セパレータ）
- [ ] Portable mode: `password = passphrase` のみ — machine_id を混入しない
- [ ] `--portable` 指定時は `flags` bit 0 をセット
- [ ] 導出鍵は正確に 32 バイト（`output_len = 32`）

---

## 暗号化の正確性

- [ ] 新規 seal には `XChaCha20Poly1305`（24 バイト nonce）を使用 — `ChaCha20Poly1305` は旧 blob 読み取り専用
- [ ] blob version バイトを先読みし、`0x01` → `ChaCha20Poly1305`、`0x02` → `XChaCha20Poly1305` で分岐
- [ ] nonce は `OsRng` による 24 バイト乱数 — `seal` 呼び出しごとに新規生成
- [ ] AAD にバージョンバイト（`&[version]`）を渡す — バージョン違いの blob は認証失敗
- [ ] `decrypt()` は Poly1305 タグ検証後にのみ平文を返す（`chacha20poly1305` クレートの仕様）— 追加の検証不要
- [ ] 暗号文長フィールドを読んだ直後に `<= MAX_SECRET_LEN` を検証してからアロケート — OOM 防止
- [ ] `re-seal` は旧 blob を復号し、`0x02` で再暗号化する（アルゴリズム自動アップグレード）

---

## マシン ID バインディング

- [ ] machine_id を KDF 入力に混ぜる前に空白・改行をトリム（`str::trim()`）
- [ ] Linux: `/etc/machine-id` → `/var/lib/dbus/machine-id` の順にフォールバック。両方なければ `exit(1)`
- [ ] macOS: `ioreg -rd1 -c IOPlatformExpertDevice` をシェルアウトし UUID を抽出。パース失敗は `exit(1)`
- [ ] Windows: `reg query HKLM\SOFTWARE\Microsoft\Cryptography /v MachineGuid` をシェルアウト。失敗は `exit(1)`
- [ ] 弱い値（空文字・"00000000-…"）への暗黙フォールバックをしない
- [ ] KDF 呼び出し後に `kdf_input`（`passphrase ‖ [0x00] ‖ machine_id`）を `zeroize()` する

---

## ファイル操作

- [ ] vault 読み取りは `O_NOFOLLOW`（POSIX）で開く — シンボリックリンク攻撃を防止
- [ ] vault 新規作成（`init`・一時ファイル）は Unix で `mode 0600` を設定
- [ ] 書き込み操作（seal / delete / rename / re-seal / import）は一時ファイルに書いて `rename()` で置換（アトミック）
- [ ] 一時ファイルのパーミッションも `0600`

---

## ファイルロック（fs2）

- [ ] 書き込み操作（seal / delete / rename / re-seal / import / init）前に `lock_exclusive()` を取得
- [ ] 読み取り操作（unseal / list / verify）前に `lock_shared()` を取得
- [ ] `probe` / `version` / `help` は vault を操作しないのでロック不要
- [ ] ロック取得失敗は `"vault is locked by another process"` を stderr に出力して `exit(1)`
- [ ] ロックは `Drop` で自動解放される（`fs2::FileExt` はファイルクローズ時に解放）

---

## CLI と入力処理

- [ ] 秘密情報の値は **stdin からのみ** 読み取る — `clap` の引数・環境変数経由は不可
- [ ] キー名は vault の暗号文に含めない — 平文インデックスとして blob の外側に保存
- [ ] `seal --portable` 実行時は stderr に警告: `"WARNING: portable mode reduces security"`
- [ ] `unseal` は blob の `flags` バイトを読んでモードを自動判定 — `--portable` フラグは受け付けない
- [ ] `unseal` は未知の `flags` ビット（bit 1 以上）があれば認証失敗扱いにする（フォワードコンパティビリティ）
- [ ] キー名の長さを `1..=255` バイトで検証（0 または 256 以上は `exit(2)`）
- [ ] パスフレーズは `/dev/tty` からエコーオフで読む（`seal` / `re-seal` / `verify --tty` / `unseal --tty`）
- [ ] stdin からのパスフレーズ読み取りは最大 `MAX_PASSPHRASE_LEN`（1024 バイト）で切る

---

## ビルドとリリース

- [ ] `Cargo.toml` の `[profile.release]` に `strip = true` を設定
- [ ] CI（`.github/workflows/ci.yml`）が Linux・macOS・Windows の全ランナーで `cargo test` を実行
- [ ] リリースワークフロー（`.github/workflows/release.yml`）が 4 ターゲットすべてでクロスビルドを実行
- [ ] `cargo clippy -- -D warnings` が警告ゼロで通ること
- [ ] `cargo audit` でアドバイザリがないことを確認（CI に組み込む）
- [ ] release ビルドで panic が `exit(1)` になることを確認（panic handler の動作テスト）

---

## 統合ラッパー（Node.js）— 変更なし・確認のみ

- [ ] 秘密情報を `Buffer` として保持し `string` に変換しない
- [ ] コンシューマーコールバック完了後（例外時も）に `Buffer.fill(0)` を呼ぶ
- [ ] 子プロセスの stdout 受信を 64 KiB に制限
- [ ] 子プロセスの stderr を破棄（ログ出力しない）

---

## 脅威モデル早見表

| 脅威 | 対策 |
|------|------|
| AI エージェントが環境変数を読む | `.env` なし — 秘密情報は vault のみ |
| プロセスリスト / argv の盗み見 | 秘密情報は argv でなく stdin から読む |
| vault を別ホストにコピー | Locked mode で Argon2id が machine_id にバインド |
| 弱いパスフレーズ | Argon2id m=64MiB で GPU 攻撃を困難に |
| メモリダンプ / コールドブート | `ZeroizeOnDrop` + `mlock()` |
| スワップへの漏洩 | `mlock()` でページを RAM に固定 |
| 情報漏洩 / ログインジェクション | 秘密情報のログ出力なし・サイレント失敗 |
| シンボリックリンク攻撃 | 読み取り open 時に `O_NOFOLLOW` |
| nonce の再利用 | `seal` ごとに `OsRng` で 24B nonce 生成 |
| 並列書き込みによる vault 破損 | `fs2::lock_exclusive()` で排他制御 |
| vault エントリの削除・改ざん検出不可 | 既知制限（v1.x で対処予定） |

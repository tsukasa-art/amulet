# Amulet — Rust 移行設計書（v1.0）

> アーキテクチャ図は [ARCHITECTURE_JA.md](ARCHITECTURE_JA.md) を参照。
> セキュリティチェックリストは [CHECKLIST_RUST_JA.md](CHECKLIST_RUST_JA.md) を参照。

---

## 方針

- **Zig 実装（v0.2.0）と同一の外部インターフェース**を維持する
- vault フォーマット v1 を完全に読み書きできる（後方互換）
- 新規 seal は blob version `0x02`（XChaCha20-Poly1305）で書く
- v1.x のチーム機能（X25519 レシピエント）を見越した設計にするが、実装はしない
- セキュリティ上の改善（XChaCha20・mlock・ファイルロック）は v1.0 に含める

---

## クレート構成

```toml
[package]
name    = "amulet"
version = "1.0.0"
edition = "2024"
rust-version = "1.74"

[dependencies]
# 暗号（RustCrypto 系・第三者監査済み）
argon2           = "0.5"
chacha20poly1305 = "0.10"   # XChaCha20Poly1305 を使用
zeroize          = { version = "1.8", features = ["derive"] }

# CLI
clap = { version = "4", features = ["derive"] }

# エラー型
thiserror = "2"

# セキュリティ
memsec = "0.7"   # mlock() ラッパー
fs2    = "0.4"   # ファイルロック（advisory lock）

[profile.release]
strip   = true
opt-level = 3
```

---

## モジュール構成

```
src/
├── main.rs        # CLI ディスパッチ（clap）・machine_id 取得・エラー出力
├── vault.rs       # vault I/O・フォーマット検出・エントリ CRUD・ファイルロック
├── crypto.rs      # Argon2id KDF + XChaCha20-Poly1305 AEAD + zeroize
└── machine_id.rs  # OS 別マシン識別子取得（Linux / macOS / Windows）
```

**依存方向（循環なし）:**

```
main.rs → vault.rs → crypto.rs
main.rs → machine_id.rs
```

---

## vault バイナリフォーマット

### フォーマット検出

```
先頭バイト列             → 判定
ファイルが 0 バイト       → v1 空 vault
0x02 0x?? で始まる blob  → 後述の blob version で判断
```

グローバルヘッダは存在しない（Zig 版と同じ）。空ファイル = 空 vault。

### エントリ構造（変更なし）

```
[2B big-endian]  key_name_len
[N bytes]        key_name（平文インデックス）
[4B big-endian]  blob_len
[blob_len bytes] Encrypted Blob（下記）
```

### Encrypted Blob

| フィールド | サイズ | v0.01 (ChaCha20) | v0x02 (XChaCha20) |
|-----------|--------|-----------------|------------------|
| version   | 1B     | `0x01`          | `0x02`           |
| flags     | 1B     | bit0=portable   | bit0=portable    |
| salt      | 16B    | Argon2id salt   | 同左              |
| nonce     | 12B    | ChaCha20 nonce  | —（存在しない）   |
| nonce     | 24B    | —（存在しない）   | XChaCha20 nonce  |
| ct_len    | 4B     | big-endian u32  | 同左              |
| ciphertext| N bytes| 暗号文          | 同左              |
| tag       | 16B    | Poly1305 tag    | 同左              |

**読み取り:** version バイトを先読みし、`0x01` → ChaCha20、`0x02` → XChaCha20 で分岐。  
**書き込み:** 常に `0x02`（XChaCha20）。  
**`re-seal`:** 復号して `0x02` で再暗号化（アルゴリズム自動アップグレード）。

---

## 暗号設計

### KDF（変更なし）

```
アルゴリズム : Argon2id
m_cost       : 65536 KiB（64 MiB）
t_cost       : 3
parallelism  : 1
出力長        : 32 bytes

Locked mode  : password = passphrase ‖ 0x00 ‖ machine_id
Portable mode: password = passphrase のみ
salt         : CSPRNG 16 bytes（seal 時生成・blob に保存）
```

### AEAD

```
アルゴリズム : XChaCha20-Poly1305（chacha20poly1305::XChaCha20Poly1305）
nonce        : CSPRNG 24 bytes（seal 呼び出しごとに新規生成）
AAD          : version バイト 1 byte（フォーマットバージョン認証）
旧 blob 読み : ChaCha20Poly1305（12B nonce）で復号
```

---

## セキュリティ設計

### zeroize 対象

`zeroize::Zeroize` / `#[derive(Zeroize, ZeroizeOnDrop)]` を適用するもの：

| 変数 | 型 | タイミング |
|------|----|----------|
| passphrase | `Vec<u8>` | 使用直後（ZeroizeOnDrop） |
| machine_id | `Vec<u8>` | KDF 呼び出し直後 |
| kdf_input  | `Vec<u8>` | KDF 呼び出し直後 |
| derived_key| `[u8; 32]`| AEAD 呼び出し直後 |
| plaintext  | `Vec<u8>` | stdout 書き込み直後 |

### mlock()

```rust
// memsec::mlock() で機密バッファをスワップ不可に固定
// 失敗（権限不足・ulimit）は stderr に警告を出力して続行（致命的エラーにしない）
memsec::mlock(ptr, len)
    .unwrap_or_else(|_| eprintln!("warning: mlock failed, secrets may appear in swap"));
```

対象: passphrase・derived_key・plaintext バッファ。

### ファイルロック（fs2）

```rust
use fs2::FileExt;

// 書き込み操作（seal / delete / rename / re-seal / import）
file.lock_exclusive()?;   // ブロッキング

// 読み取り操作（unseal / list / verify）
file.lock_shared()?;      // 並列 read は許可

// ロック失敗
// → stderr: "vault is locked by another process"
// → exit(1)
```

### ファイル操作

| 操作 | 方式 |
|------|------|
| vault 読み取り | `O_NOFOLLOW`（POSIX）でシンボリックリンク攻撃を防止 |
| vault 書き込み | 一時ファイルに書き → `rename()`（アトミック） |
| vault 新規作成（init） | `mode 0600`（Unix） |

### Panic ハンドラ

```rust
// release ビルドでは panic を無音の exit(1) に
// debug ビルドでは通常の panic（スタックトレース）
#[cfg(not(debug_assertions))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    std::process::exit(1);
}
```

---

## 制限値（Zig 版から引き継ぎ）

```rust
const MAX_SECRET_LEN:     usize = 64 * 1024;  // 64 KiB
const MAX_PASSPHRASE_LEN: usize = 1024;
const MAX_KEY_NAME_LEN:   usize = 255;
const DEFAULT_VAULT_PATH: &str  = "amulet.vault";
```

---

## エラーハンドリング方針

```rust
#[derive(thiserror::Error, Debug)]
enum AmuletError {
    // unseal / verify 失敗: 理由を一切表示しない（仕様）
    #[error("")]
    DecryptFailed,

    // seal 失敗: 汎用メッセージのみ（秘密情報を含まない）
    #[error("seal failed: {0}")]
    Io(#[from] std::io::Error),

    // vault 破損
    #[error("invalid vault format")]
    InvalidVault,

    // ロック競合
    #[error("vault is locked by another process")]
    VaultLocked,

    // 引数不正
    #[error("")]  // clap が usage を出力するので空
    Usage,
}
```

**stderr に出力してよい情報:**
- 汎用エラーメッセージ（"seal failed"・"init failed" 等）
- `--portable` 警告
- mlock 失敗警告
- ロック競合メッセージ

**stderr に出力してはいけない情報:**
- 秘密情報の値・断片
- machine_id の値
- vault ファイルパス（復号エラー時）
- キー名（復号エラー時）

---

## CLI インターフェース（全コマンド）

Zig 版と完全互換。追加・削除・変更なし。

| コマンド | パスフレーズ | ファイルロック |
|---------|------------|--------------|
| `init`    | 不要 | exclusive |
| `seal`    | TTY | exclusive |
| `unseal`  | stdin / TTY | shared |
| `verify`  | stdin / TTY | shared |
| `re-seal` | TTY（旧・新・確認） | exclusive |
| `import`  | TTY | exclusive |
| `list`    | 不要 | shared |
| `delete`  | 不要 | exclusive |
| `rename`  | 不要 | exclusive |
| `probe`   | 不要 | なし（vault 操作なし） |
| `version` | 不要 | なし |
| `help`    | 不要 | なし |

---

## 既知の制限（設計上のトレードオフ）

### キー名は平文

vault ファイル内のキー名（`OPENAI_API_KEY` 等）は暗号化されない。

**意図的な設計:** `amulet list` をパスフレーズなしで実行できるようにするため。vault を git 管理したとき、チームが「どの秘密が必要か」を把握できる（`.env.example` の代替）。

脅威モデル上の前提: **キー名は公開情報に準ずる**（Dockerfile・CI 設定・README に書く情報と同等）。値のみが機密。

### グローバル vault MAC がない

vault ファイル全体を認証する MAC がない。各エントリの blob は Poly1305 で認証されているが、攻撃者がファイルアクセスを得た場合：

- エントリの**削除**が検出できない
- エントリの**並び替え**が検出できない

機密性（値の漏洩）は保護される。完全性（エントリの存在確認）は v1.x で対処予定。

### advisory lock

`fs2` による POSIX advisory lock は強制ロックではない。ロックを無視するプロセスは vault に直接アクセスできる。同一ユーザーの複数プロセスが同時に vault を操作するケースを防ぐ目的。

---

## 実装順序

1. `Cargo.toml` + モジュールスケルトン（空の `mod`）
2. `machine_id.rs`（OS 別 machine_id 取得）
3. `crypto.rs`（Argon2id + XChaCha20 + zeroize + mlock）
4. `vault.rs`（v1/v2 フォーマット読み取り・v2 書き込み・ファイルロック・アトミック書き込み）
5. `main.rs`（全 12 コマンド実装）
6. テスト（unit + integration）
7. `.github/workflows/` 更新（Zig → Rust）
8. `README_JA.md` / `README.md` 更新

---

## v1.x への拡張ポイント

以下は v1.0 には含まないが、設計で塞がないようにする：

- blob version `0x03` 以降でレシピエントモード（X25519）を追加予定
- `machine_id.rs` の取得ロジックはそのまま再利用
- `vault.rs` のエントリ構造体に `recipient_headers: Vec<RecipientHeader>` フィールドを追加できる形にする

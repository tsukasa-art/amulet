# Amulet — アーキテクチャ設計

> このドキュメントは Rust 書き直し（v1.0）および将来のチーム機能（v1.x）の設計基盤です。

---

## 1. モジュール構成

```mermaid
graph TD
    subgraph bin["amulet バイナリ"]
        MAIN["main.rs\nCLI ディスパッチ\n全コマンドのエントリポイント"]
        VAULT["vault.rs\nVault I/O\nフォーマット検出・エントリ読み書き"]
        CRYPTO["crypto.rs\n暗号コア\nArgon2id KDF + ChaCha20-Poly1305"]
        MACHINE["machine_id.rs\nOS マシン識別子\nLinux / macOS / Windows"]
    end

    subgraph crates["外部クレート（RustCrypto 系・監査済み）"]
        CLAP["clap 4\nCLI パース"]
        ARGON2["argon2\nArgon2id KDF"]
        CHACHA["chacha20poly1305\nAEAD 暗号化"]
        ZEROIZE["zeroize\nセキュアメモリゼロ化"]
        THISERROR["thiserror\nエラー型定義"]
    end

    MAIN -->|"seal / unseal / init ..."| VAULT
    MAIN -->|"machine_id 取得"| MACHINE
    VAULT -->|"encrypt / decrypt"| CRYPTO
    CRYPTO --> ARGON2
    CRYPTO --> CHACHA
    CRYPTO --> ZEROIZE
    MAIN --> CLAP
    MAIN --> THISERROR
    VAULT --> THISERROR
    CRYPTO --> THISERROR
```

**設計方針:**
- `main.rs` が machine_id を取得し、vault 操作に渡す（Zig 版と同じ責務分離）
- `crypto.rs` は pure 関数のみ。副作用なし
- `vault.rs` はフォーマット検出・I/O のみ。暗号知識を持たない
- `machine_id.rs` は他モジュールに依存しない

---

## 2. seal データフロー

```mermaid
flowchart TD
    STDIN(["stdin\n平文シークレット"])
    TTY(["TTY\nパスフレーズ（エコーオフ）"])
    OS(["OS\nmachine_id"])

    subgraph crypto["crypto.rs"]
        SALT["CSPRNG\n16 バイト salt 生成"]
        NONCE["CSPRNG\n12 バイト nonce 生成"]
        KDF["Argon2id\nm=64MiB / t=3 / p=1\npassphrase ‖ 0x00 ‖ machine_id + salt\n→ derived_key 32 バイト"]
        AEAD["ChaCha20-Poly1305\nAAD = version byte\n→ ciphertext + 16B tag"]
    end

    VAULT_FILE[("vault ファイル\nエントリ追記 / 上書き")]
    ZERO["zeroize\npassphrase / machine_id\nderived_key / plaintext"]

    TTY -->|"passphrase"| KDF
    OS -->|"machine_id\n（Locked mode のみ）"| KDF
    SALT --> KDF
    KDF -->|"derived_key"| AEAD
    STDIN -->|"plaintext"| AEAD
    NONCE --> AEAD
    AEAD -->|"blob"| VAULT_FILE
    KDF -.->|"使用後"| ZERO
    AEAD -.->|"使用後"| ZERO
```

---

## 3. unseal データフロー

```mermaid
flowchart TD
    VAULT_FILE[("vault ファイル\nキー名でエントリ検索")]
    TTY(["stdin / TTY\nパスフレーズ"])
    OS(["OS\nmachine_id"])

    subgraph vault["vault.rs"]
        FLAGS["flags バイト読み取り\nLocked / Portable 自動判定"]
    end

    subgraph crypto["crypto.rs"]
        KDF["Argon2id\nsalt（blob より取得）\n→ derived_key 32 バイト"]
        AEAD["ChaCha20-Poly1305\nPoly1305 タグ検証後に復号\n失敗 → サイレント終了コード 1"]
    end

    STDOUT(["stdout\n平文シークレット"])
    ZERO["zeroize\npassphrase / machine_id\nderived_key / plaintext"]

    VAULT_FILE --> FLAGS
    FLAGS -->|"mode 判定"| KDF
    TTY -->|"passphrase"| KDF
    OS -->|"machine_id\n（Locked mode のみ）"| KDF
    KDF -->|"derived_key"| AEAD
    VAULT_FILE -->|"ciphertext + tag"| AEAD
    AEAD -->|"plaintext"| STDOUT
    AEAD -.->|"stdout 書き込み後"| ZERO
    KDF -.->|"使用後"| ZERO
```

---

## 4. vault バイナリフォーマット（v1 — 現行・後方互換対象）

```mermaid
block-beta
  columns 1
  A["[2B]  key_name_len （big-endian u16）"]
  B["[N]   key_name （平文インデックス）"]
  C["[4B]  blob_len （big-endian u32）"]
  D["━━━ Encrypted Blob ━━━"]
  E["[1B]  version = 0x01"]
  F["[1B]  flags   bit0=portable / 他ビット=0 必須"]
  G["[16B] Argon2id salt （CSPRNG）"]
  H["[12B] ChaCha20-Poly1305 nonce （CSPRNG）"]
  I["[4B]  ciphertext_len （big-endian u32）"]
  J["[N]   ciphertext"]
  K["[16B] Poly1305 認証タグ"]
```

**ファイル全体:** エントリの連続。先頭にグローバルヘッダなし。0 バイトの空ファイル = 空 vault。

---

## 5. 将来設計 — v1.x レシピエントモード（公開鍵チーム共有）

> v1.0 には含まない。vault フォーマット v2 として追加予定。

```mermaid
flowchart TD
    subgraph setup["セットアップ（一人一回）"]
        KEYGEN["amulet keygen\nX25519 キーペア生成\n~/.config/amulet/identity"]
        PUB["公開鍵\nチームに共有・git 管理可"]
        PRIV["秘密鍵\nローカル保存\n（パスフレーズ保護）"]
        KEYGEN --> PUB
        KEYGEN --> PRIV
    end

    subgraph seal_team["seal --recipient alice.pub --recipient bob.pub"]
        DEK["DEK 生成\n（ランダム 32B）"]
        EPH["Ephemeral X25519 keypair"]
        WRAP_A["X25519（eph_priv, alice_pub）\n→ HKDF → wrap DEK for Alice"]
        WRAP_B["X25519（eph_priv, bob_pub）\n→ HKDF → wrap DEK for Bob"]
        ENC["ChaCha20-Poly1305（DEK）\n→ ciphertext"]
        DEK --> ENC
        EPH --> WRAP_A
        EPH --> WRAP_B
        WRAP_A --> BLOB["blob\nrecipient headers × N\n+ ciphertext"]
        WRAP_B --> BLOB
        ENC --> BLOB
    end

    subgraph unseal_alice["unseal（Alice）"]
        ALICE_PRIV["Alice の秘密鍵"]
        UNWRAP["X25519（alice_priv, eph_pub）\n→ HKDF → DEK 復元"]
        DEC["ChaCha20-Poly1305 復号\n→ plaintext"]
        ALICE_PRIV --> UNWRAP
        UNWRAP --> DEC
    end
```

**v1.x で追加するコマンド:**

| コマンド | 概要 |
|---------|------|
| `amulet keygen` | X25519 キーペアを生成・保存 |
| `amulet seal --recipient <pubkey>` | 1人以上のレシピエントへ seal |
| `amulet add-recipient <pubkey> <key>` | 既存エントリに受取人を追加 |
| `amulet remove-recipient <pubkey> <key>` | 受取人を削除（退職時など） |

**共有パスフレーズが不要になる。** 各自の秘密鍵は自分のパスフレーズで保護。メンバーが抜けても他メンバーの鍵は安全なまま。

---

## バージョンロードマップ

```mermaid
timeline
    title Amulet バージョンロードマップ
    v0.2.0 : Zig 実装（現行）
           : 11 コマンド完成
           : vault フォーマット v1
    v1.0.0 : Rust 書き直し
           : 全コマンド完全移植
           : vault フォーマット v1 維持（後方互換）
           : RustCrypto 監査済みクレート採用
    v1.x.0 : X25519 レシピエントモード
           : vault フォーマット v2
           : チーム開発対応
           : migrate コマンド追加
```

# Amulet — セキュリティリファレンス

## 動作モード

### Locked Mode（デフォルト）

seal 時と同じ machine_id を持つ環境でのみ復号できます。マシン識別子をパスフレーズと組み合わせて Argon2id の password 入力に含めます。

```
AEAD 鍵 = Argon2id(passphrase ‖ 0x00 ‖ machine_id, salt)
```

| OS | machine_id の取得元 |
|----|---------------------|
| Linux | `/etc/machine-id`（fallback: `/var/lib/dbus/machine-id`） |
| macOS | `IOPlatformUUID`（`ioreg` 経由） |
| Windows | `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`（`reg query` 経由） |

**安定性:** 再起動には耐えます。Linux では OS の再インストール、macOS ではロジックボード交換などで machine_id が変わり得ます。Windows の `MachineGuid` は多くのハードウェア変更では維持されやすい一方、OS のクリーンインストールやイメージの復元などで変わることがあります。

### Portable Mode（`--portable` 付きで seal した場合）

machine_id を Argon2id の password 入力に含めません。パスフレーズとソルトだけから鍵が導出され、どのマシンでも復号できます。

```
AEAD 鍵 = Argon2id(passphrase, salt)
```

- vault エントリヘッダの `flags` bit 0 が 1 にセットされます。
- `unseal` 時はこのフラグを自動読み取りしてモード判定します（ユーザーが `--portable` を指定する必要はありません）。
- セキュリティが低下するため、seal 時に警告を stderr に出力します。

CI ランナー・コンテナ・クロスマシン移行では Portable モードを使います。判断表は [deployment-ja.md](deployment-ja.md) を参照してください。

---

## Vault ファイルフォーマット

vault ファイルはエントリの列です（ファイル全体のヘッダなし；空ファイル = 空 vault）。

**外側のエントリエンベロープ**（格納済みキーごとに繰り返し）:

```
[2 byte big-endian]  キー名の長さ
[キー名の長さ]        キー名（平文）
[4 byte big-endian]  blob の長さ
[blob の長さ]         暗号化 blob
```

**各エントリの暗号化 blob（v2、現行）:**

```
[1 byte]  version  = 0x02
[1 byte]  flags    (bit 0 = portable mode)
[16 byte] Argon2id salt  （CSPRNG ランダム、seal ごとに生成）
[24 byte] XChaCha20-Poly1305 nonce（CSPRNG ランダム、seal ごとに生成、再利用なし）
[4 byte]  ciphertext 長（big-endian u32）
[N byte]  ciphertext（N は直前の 4 バイトフィールドの値）
[16 byte] Poly1305 認証タグ
```

`N` は直後の ciphertext のバイト数だけを表し、Poly1305 の認証タグ（16 バイト）は含みません。ciphertext の長さは平文長と一致するため、`N` は seal 時の秘密のバイト数と同じになります。

> **後方互換性:** Amulet v0.x が生成した v1 blob（`version = 0x01`、ChaCha20-Poly1305、12 バイト nonce）は unseal 時に透過的にサポートされます。新規 seal は常に v2 を生成します。

キー名は外側のエンベロープに平文で保持されます。暗号化されるのは秘密の**値**だけです。

---

## 暗号仕様

| 項目 | 仕様 |
|------|------|
| KDF | Argon2id（m=64 MiB, t=3, p=1） |
| 暗号化 | XChaCha20-Poly1305（AEAD） |
| 鍵長 | 256 bit（32 byte） |
| ソルト | 16 byte CSPRNG、`seal` ごとに生成、vault エントリに保存 |
| Nonce | 24 byte CSPRNG、`seal` ごとに生成、vault エントリに保存、再利用なし |
| AAD | version バイト（フォーマット変更検知用） |

---

## セキュリティ設計原則

| 原則 | 実装 |
|------|------|
| No .env Policy | ディスクへの平文書き込みは一切実装しない |
| Silent Failure | 復号失敗時は stderr 出力なし、終了コード 1 のみ |
| No Leakage | ログ・エラーに秘密情報・machine_id・鍵素材を含まない |
| Immediate Erasure | 使用後すぐ `zeroize` でメモリを抹消 |
| Stdin Only | 秘密の値は argv・環境変数経由で受け取らない |
| シンボリックリンク対策 | POSIX では `O_NOFOLLOW` で vault を開く |
| ファイル権限 | Unix では vault 作成時に mode `0600` を設定 |

---

## 脅威モデル

| 脅威 | 対策 |
|------|------|
| AI エージェントが env vars やリポジトリを読む | `.env` なし — 秘密は vault ファイルのみ |
| プロセスリスト・argv の盗み見 | 秘密は stdin から読み取り、argv には載せない |
| vault を machine_id が異なるホストにコピーされる | Locked Mode で Argon2id が machine_id にバインド |
| 弱いパスフレーズ | Argon2id（64 MiB メモリコスト）で強化 |
| コールドブート・メモリダンプ | `zeroize` で使用後即消去；`mlock` でスワップアウト防止；ヒープ露出を最小化 |
| ログへの秘密情報の漏洩 | 秘密素材のログ出力なし、サイレント失敗 |
| vault ファイルへのシンボリックリンク攻撃 | `O_NOFOLLOW` で open |
| Nonce の再利用 | `seal` ごとに CSPRNG で新しい Nonce を生成 |

> **VM クローンについて:** Amulet は machine_id が一致するホストを同一マシンとして扱います。ID が重複したクローンがあれば、あるインスタンスで sealed した vault を別インスタンスでも復号できます。クローン後は各インスタンスで machine-id を再生成してください。詳細は [deployment-ja.md](deployment-ja.md) を参照してください。

**スコープ:** Amulet が減らせるのは、健全な開発者マシン上での**不注意による事故**です。OS が既に侵害されていたり、ターミナルや stdin をマルウェアが制御している場合は、ソフトウェアだけでは防ぎきれません。
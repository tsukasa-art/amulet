---
title: "デプロイメント・ガイド"
description: "各種環境へのデプロイ手順、移行、および Docker Compose との連携方法。"
order: 5
---

## Locked vs Portable: 判断基準

| 環境 | 推奨モード | 運用上の注意 |
|------|-----------|------------|
| 物理マシン / 固定 VM | **Locked** | 脅威モデル: vault ファイルだけが他所へ流出した際の復号を阻止。既にそのマシン上で権限を持つ攻撃者からは保護できない。 |
| VM クローン / テンプレート | **Locked** | **ID の重複に注意:** クローン後に各インスタンスで `machine-id` を再生成すること（例: `systemd-machine-id-setup`）。ID が重複していると、あるクローンで sealed した vault を別のクローンでも復号できてしまい、本来の隔離が機能しない。 |
| Windows (Sysprep) | **Locked** | 一般化（Sysprep）により `MachineGuid` が変わる。ゴールデンイメージに sealed vault を含めず、デプロイ後に各ノードで seal すること。seal 後に MachineGuid が変わると復旧不能になる（後述の移行手順が必要）。 |
| 開発用 PC (個人) | **Locked** | 各開発者が自分のマシンで seal する。 |
| CI (GitHub Actions 等) | **Portable** | 実行のたびにランナーが変わり machine_id が不安定なため。CI 側のシークレットから十分な長さのランダムなパスフレーズを注入する。 |
| コンテナ / Kubernetes | **Portable** | Pod の machine_id が不安定または共有されることが多いため。パスフレーズの強度と、シークレットの注入経路が主な保護手段となる。 |
| 移行・リカバリ | **Portable** | マシンを跨いだ復号を意図的に行うため。 |

> **OS 再インストール・ハード変更:** machine_id が変わると Locked な vault は復旧できなくなります（Linux: OS 再インスコ; macOS: ロジックボード交換; Windows: OS クリーンインスコやイメージ復元）。ランブックに後述のリカバリ手順を含めてください。

**チーム運用のパターン:**
- 本番環境: サーバー自身で seal / unseal を行う (Locked)
- CI やステージング: プラットフォーム側のシークレット注入（GitHub Actions Secrets 等）を使うか、強固なパスフレーズを持つ Portable な vault を使う
- Locked な vault をマシン間で共有しない（各環境がそれぞれ自身で seal する）

### 運用上の補足

#### Locked モードの脅威モデル

Locked は OS が報告するマシン識別子（Linux: `/etc/machine-id`, macOS: `IOPlatformUUID`, Windows: レジストリの `MachineGuid`）を Argon2id のパスワード入力に混合します。これにより、vault ファイルだけが攻撃者のマシン（異なる machine_id）に渡った場合、正しいパスフレーズを知っていても復号に失敗し、Argon2id への総当たり攻撃が必要になります。攻撃者が既にそのホスト上でシェル権限を持っている場合、machine_id もプロセスメモリ上のパスフレーズも読み取れる可能性があるため、ホスト自体のセキュリティ対策は別途必要です。

#### VM クローンと machine-id の重複

Amulet は machine_id が一致するホストを「同じマシン」とみなします。Linux において ID を初期化せずに VM イメージをクローンするのはよくあるミスです。
- **ID が重複している場合:** インスタンス A で seal した vault が、同じ ID を持つインスタンス B でも復号できてしまいます。環境の隔離（例：開発用 vault が本番で読める等）が暗黙的に破れます。
- **seal 後に ID が変わった場合:** vault を seal した後にそのホストの machine-id が変わると（例：`systemd-machine-id-setup` を実行した、OS を再インストールした等）、そのホスト上でも復号できなくなります。

**推奨プラクティス:** Linux テンプレートを作成する場合、ゴールデンイメージ内の machine-id を空（`> /etc/machine-id`）にしておき、初回起動時に `systemd-machine-id-setup` が自動実行されて各インスタンスが固有の ID を持つように設定してください。

#### Portable モードによる CI/CD

GitHub Actions, GitLab CI, Buildkite 等の ephemeral（短命）な環境では、ランナーごとに machine_id が変わります。Portable モードを使用し、パスフレーズを CI 側のシークレットストアから注入してください。パスフレーズだけが暗号的な防壁となるため、CSPRNG で生成した 32 文字以上のランダムな文字列を使用することを推奨します。

---

## 移行と災害復旧

### Vault ファイルのコピー ≠ Locked モードの復旧可能なバックアップ

| バックアップの種類 | 内容 | 異なる machine_id のホストで復旧できるか |
|------------------|------|----------------------------------------|
| Vault ファイルのコピー | 暗号化済みバイナリ | ❌ Locked の場合は machine_id が一致する必要あり |
| 旧マシンで unseal した平文 | 生の秘密情報 | ✅ 新マシンで再度 seal する |
| Portable vault のコピー | 暗号化済みバイナリ | ✅ パスフレーズだけで復旧可能 |

> **注意:** machine_id を共有する VM クローン同士は、互いの Locked な vault を復旧できます。詳細は [docs/security.md の VM クローンについての注記](security.md) を参照してください。

### 計画的なマシン移行

旧マシンがまだ動いている場合:

```sh
# 1. 旧マシンで平文を取り出す
printf "mypassphrase\n" | amulet unseal SECRET_KEY --file secrets.vault

# 2. 新マシンで再度 seal する（新しい machine_id にバインドされる）
echo -n "<取り出した平文>" | amulet seal SECRET_KEY --file secrets.vault
```

### 突然のマシン故障

旧マシンが起動しなくなった場合、Locked な vault は**復旧できません**。事前に対策しておいてください。
- 秘密情報を別の安全な場所（パスワードマネージャー等）に保管しておく
- または、オフラインバックアップとして Portable な vault を用意しておく

### 複数デバイスでの開発

同じ Locked vault をデバイス間で共有することはできません。以下のいずれかを選択してください。
- **デバイスごとに個別の vault を作成** — 各デバイスが自身の ID で seal する
- **共有の Portable vault を使用** — パスフレーズを安全に共有し、どこでも同じ vault を使う
- **開発は Portable、本番は Locked** — 環境ごとにモードを使い分ける

---

## Docker Compose / Podman Compose

最も確実な方法は、秘密情報を**短命の一時ファイル**に書き出し、`--env-file` で渡すことです。

### 手順

**1. 一時ファイルを作成し、終了時の削除を予約する:**

```sh
TMP_ENV=$(mktemp)
chmod 0600 "$TMP_ENV"
trap "rm -f '$TMP_ENV'" EXIT
```

> **発展 — ディスク露出をさらに減らす (Linux):** Linux の多くのディストリビューションでは `/dev/shm` が tmpfs（メモリ上）なので、`mktemp -p /dev/shm` が有効です。デスクトップ環境で `$XDG_RUNTIME_DIR` が設定されている場合は `mktemp -p "$XDG_RUNTIME_DIR"` もよく使われます。フォールバック先の指定を誤ると通常のディスク（`/tmp`）に書かれるため、注意が必要です。これらはベストエフォートな対策であり、スワップ設定等によっては完全にメモリ内に留まるとは限りません。macOS では `/dev/shm` は使えないため、通常の `mktemp` で問題ありません。

**2. `KEY=value` 形式で 1 行書き出す。** 一部の zsh 等でサブシェルのリダイレクトが不安定なのを避けるため、2 回に分けるのが無難です：

```sh
printf 'OPENAI_API_KEY=' > "$TMP_ENV"
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault >> "$TMP_ENV"
```

**bash** なら、サブシェルを使った 1 行も確実です：

```sh
( printf 'OPENAI_API_KEY='; printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault ) > "$TMP_ENV"
```

もし `wc -c "$TMP_ENV"` の結果が `OPENAI_API_KEY=` の文字数だけなら unseal に失敗しています。パスフレーズ、キー名、`--file` のパス、または Locked モードのマシン不一致を確認してください。

**3. Compose を起動する:**

```sh
docker compose --env-file "$TMP_ENV" config   # 設定の確認
docker compose --env-file "$TMP_ENV" up

# Podman の場合
podman compose --env-file "$TMP_ENV" up
```

**4. 後片付け:**

```sh
docker compose down
rm -f "$TMP_ENV"    # またはシェルを終了（trap が処理）
```

`compose down` を `--env-file` なしで実行すると、環境変数が未定義である警告が出ることがありますが、削除処理自体には影響ありません。

### Podman on macOS

`podman compose` が繋がらない場合は、`podman machine start` で VM を起動してください（未作成なら `podman machine init` を先に 1 回実行）。

### YAML 内の `$` のエスケープ

Compose YAML 内で `$VAR` や `${VAR}` は環境変数展開に使われます。`command:` ブロック等でドル記号そのものを渡したい場合は `$$` と重ねてください（例：`$$OPENAI_API_KEY`）。`${#VAR}` のような bash 固有の展開は Compose でエラーになるため避けてください。

> **注意:** 一時ファイルには平文が短時間保持されます。必ず `trap` 等で確実に削除されるようにしてください。本番環境では、一時ファイル経由よりも CI/CD プラットフォームのシークレット注入機能の使用を優先してください。

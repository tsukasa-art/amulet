# Amulet — 環境別運用・移行・Docker Compose

## Locked vs Portable 判断表

| 環境 | 推奨モード | 理由 |
|------|-----------|------|
| 本番の固定サーバ | **Locked** | machine_id が安定している。vault をコピーされても別マシンでは復号不可 |
| 開発者の個人 PC | **Locked**（各自） | 各開発者が自分のマシンで seal する |
| CI（GitHub Actions 等） | **Portable** | ランナーが毎回変わり machine_id が安定しない |
| コンテナ / Kubernetes | **Portable** | Pod の machine_id が安定しないことが多い |
| 移行・検証用途 | **Portable** | 別マシンでの復号が意図的に必要な場合 |

> **OS 再インストール・ハードウェア交換時の注意:** machine_id が変わると Locked vault は復号不能になります（Linux: OS 再インストール、macOS: マザーボード交換）。runbook に復旧手順を記載してください。

**チームでの基本パターン:**
- 本番ホスト: サーバ上で seal・unseal（Locked）
- CI・ステージング: CI プラットフォームのシークレット注入か、強いパスフレーズを使った Portable vault
- Locked vault はマシン間で共有しない — 各環境が自前で seal する

---

## 移行・複数端末・障害時の注意

### vault ファイルのコピーは「復号できるバックアップ」ではない

| バックアップの種類 | 内容 | 別マシンでの復旧 |
|------------------|------|----------------|
| vault ファイルのコピー | 暗号化済みバイナリ | ❌ Locked: 別マシンでは machine_id が合わず復号不可 |
| 旧マシンで unseal した平文 | 秘密情報の生データ | ✅ 新マシンで re-seal できる |
| Portable vault のコピー | 暗号化済みバイナリ | ✅ パスフレーズさえあれば復号可 |

### 計画的なマシン移行

旧マシンが生きている間に次の手順を踏んでください:

```sh
# 旧マシンで unseal して平文を取り出す
printf "mypassphrase\n" | amulet unseal SECRET_KEY --file secrets.vault

# 新マシンで re-seal（Locked なら新マシンの machine_id にバインドされる）
echo -n "<取り出した値>" | amulet seal SECRET_KEY --file secrets.vault
```

### 突然の故障

旧マシンが起動しなくなった場合、Locked vault は**復号できません**。事前の対策が必要です:
- 秘密情報をパスワードマネージャー等にも保管しておく
- または Portable vault を別途作成してオフラインバックアップとして保管する

### 複数端末での開発

同じ Locked vault を複数端末で共有することはできません。以下のいずれかを選んでください:
- **端末ごとに別 vault** — 各端末で seal する（Locked のまま独立）
- **Portable vault を共有** — パスフレーズを安全に共有し、全端末で同じ vault を使う
- **開発だけ Portable、本番は Locked** — 環境で使い分ける

---

## Docker Compose / Podman Compose との連携

vault を Compose ベースのワークフローに統合するには、**一時ファイル経由**が最も安定した方法です。

### 手順

**1. 一時ファイルを作成して終了時削除を登録:**

```sh
TMP_ENV=$(mktemp)
chmod 0600 "$TMP_ENV"
trap "rm -f '$TMP_ENV'" EXIT
```

> **任意の改善（Linux）:** 平文をディスクに書き込まないようにするには、`mktemp -p /dev/shm` または `mktemp -p "${XDG_RUNTIME_DIR:-/tmp}"` でメモリ上の tmpfs を使う方法があります。macOS には `/dev/shm` がないため、macOS では通常の `mktemp` を使ってください。

**2. `KEY=value` の1行を書く。** 2 コマンドに分けるのを推奨します — 一部の zsh では同じリダイレクト内にまとめると `unseal` の出力がファイルに乗らないことがあります:

```sh
printf 'OPENAI_API_KEY=' > "$TMP_ENV"
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault >> "$TMP_ENV"
```

bash ではサブシェル1行でも通ることが多い:

```sh
( printf 'OPENAI_API_KEY='; printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault ) > "$TMP_ENV"
```

`wc -c "$TMP_ENV"` が `OPENAI_API_KEY=` の文字数だけなら `unseal` が追記されていません — パスフレーズ・キー名・`--file`・Locked のマシン不一致を確認してください。

**3. Compose を実行:**

```sh
docker compose --env-file "$TMP_ENV" config   # 設定確認（ドライラン）
docker compose --env-file "$TMP_ENV" up

# Podman
podman compose --env-file "$TMP_ENV" up
```

**4. 片付け:**

```sh
docker compose down
rm -f "$TMP_ENV"    # または trap を設定したシェルを exit する
```

`--env-file` なしで `compose down` すると `OPENAI_API_KEY` が未設定だと警告することがありますが、削除処理自体には通常影響しません。

### macOS での Podman

`podman compose` が接続できないときは Linux VM が停止しています。`podman machine start`（初回のみ `podman machine init`）を実行してください。

### compose.yaml の `$` エスケープ

Compose は YAML 内の `$VAR` / `${VAR}` を補間します。`command:` ブロックなどではコンテナシェル向けに `$$` と書いてリテラルの `$` にします（例: `$$OPENAI_API_KEY`）。`${#変数名}` のような bash 専用構文は Compose 的に不正な補間になりやすいため避けてください。

> **注意:** 一時ファイルはディスクに短時間平文が出ます。`trap` による削除を必ず設定し、開発用ブリッジとして扱ってください。本番では CI のシークレット注入（GitHub Actions secrets 等）を使用してください。

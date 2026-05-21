---
title: "Amulet からの移行ガイド"
description: "シークレットを安全にエクスポートし、プロジェクトやマシンからAmuletを削除する方法。"
order: 9
---

このページでは、シークレットを安全にエクスポートし、プロジェクトやマシンから Amulet を削除する手順を解説します。

> **Locked モードに関する注意:** Locked モードの vault は、それを seal したマシン上でのみ復号できます。エクスポートする前にマシンを初期化したり OS を変更したりすると、シークレットは永久に復旧できなくなります。必ず先にエクスポートを行い、その後にクリーンアップを行ってください。

---

## ステップ 1 — シークレットのエクスポート

vault に保存されている全キー名をリストアップし、一つずつ unseal します。

```sh
amulet list --file secrets.vault
```

個別に unseal して値を表示する：

```sh
amulet unseal --tty MY_KEY --file secrets.vault
```

### 一括エクスポート（シェルスクリプト）

以下のスクリプトは、全キーを `KEY=value` 形式で平文ファイルに書き出します。このファイルは「生の秘密情報」そのものですので、権限を制限し、作業が終わったら必ず削除してください。

```sh
VAULT=secrets.vault
OUTPUT=exported-secrets.env

# シークレットを書き込む前に、権限を制限した空ファイルを作成する
install -m 0600 /dev/null "$OUTPUT"

printf "Enter vault passphrase: "
read -rs PASSPHRASE
echo

while IFS= read -r KEY; do
  VALUE=$(printf '%s\n' "$PASSPHRASE" | amulet unseal "$KEY" --file "$VAULT")
  printf '%s=%s\n' "$KEY" "$VALUE" >> "$OUTPUT"
done < <(amulet list --file "$VAULT")

echo "Exported to $OUTPUT"
```

**Windows (PowerShell)** では、上記のスクリプトは動作しません。各キーを個別に unseal して必要な場所に貼り付けてください。

---

## ステップ 2 — 新しい移行先への登録

エクスポートしたシークレットを、Amulet の代わりとなる場所に登録します。

| 移行先 | 手順 |
|-------|-----|
| **`.env` ファイル** | `exported-secrets.env` の `KEY=value` 行を直接コピー。`.env` を `.gitignore` に追加するのを忘れずに。 |
| **パスワードマネージャー** (1Password, Bitwarden 等) | シークレットごとに新しいアイテムを作成し、値を貼り付ける。 |
| **CI シークレット** (GitHub Actions, GitLab CI 等) | プラットフォームの設定画面または CLI から各キーを追加する。 |
| **クラウドのシークレットマネージャー** (AWS, GCP, HashiCorp Vault 等) | プロバイダーの CLI や SDK を使い、エクスポートした値からエントリを作成する。 |
| **別のマシンの Amulet** | 新しいマシンで再度 seal する (`echo -n "<value>" | amulet seal KEY --file secrets.vault`)。[デプロイメント・ガイド](deployment.md#計画的なマシン移行) を参照。 |

### コードの更新

コードベースから `amulet unseal` を呼び出している箇所を検索し、新しい移行先の仕組み（`.env` からの読み込み、SDK の呼び出し等）に書き換えます。

```sh
grep -r "amulet" .
```

---

## ステップ 3 — クリーンアップ

**vault ファイルを削除する:**

```sh
rm secrets.vault
```

vault ファイルを git にコミットしていた場合は、履歴からも削除してください。暗号化されてはいますが、残しておく理由はありません。

```sh
git rm secrets.vault
git commit -m "remove amulet vault"
```

**バイナリを削除する:**

```sh
# Linux / macOS (/usr/local/bin にインストールした場合)
sudo rm /usr/local/bin/amulet

# 他の場所にインストールした場合は確認：
which amulet
```

**Windows** では、`amulet.exe` を配置した場所から削除してください。Amulet のためだけに `PATH` に追加したディレクトリがあれば、それも削除します。

**エクスポートした平文ファイルを削除する**（ステップ 1 で作成した場合）:

```sh
rm exported-secrets.env
```

---

## チェックリスト

- [ ] すべてのシークレットがエクスポートされ、`amulet list` の出力と一致している
- [ ] エクスポートした値が新しい移行先に登録された
- [ ] コードが更新され、`amulet unseal` の呼び出しが残っていない
- [ ] `secrets.vault` が削除された（git にあれば履歴からも削除済み）
- [ ] `amulet` バイナリが削除された
- [ ] エクスポートに使った平文ファイルが削除された

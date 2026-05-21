---
title: "トラブルシューティング"
description: "Amuletでよく発生する問題の解決策、unsealの失敗、および起動タイムアウトへの対処法。"
order: 8
---

## なぜ unseal は失敗時に何も出力しないのか

`unseal` は、パスフレーズ間違い、キー名間違い、vault パスの誤り、またはマシン識別子の不一致など、いかなる失敗時も **何も出力せず終了コード 1 で終了** します。これは意図的な設計です。詳細なエラーメッセージを出力すると、vault ファイルを手に入れた攻撃者に対して「なぜ復号に失敗したのか」というヒントを与えてしまうためです。詳細は [セキュリティリファレンス](security.md) を参照してください。

このため、起動スクリプトの設定ミスも、成功して何も出力されなかった場合と同じように見えてしまいます。以下の手順で、秘密の値を露出させずに原因を切り分けることができます。

---

## アプリが起動しない / サービスが失敗し続ける

サービスを実行しているのと同じユーザーで、以下の手順を手動で実行してください。

### ステップ 1 — vault のパスが正しいか確認する

```sh
ls -l /path/to/secrets.vault
amulet list --file /path/to/secrets.vault
```

`list` が何も出力しない、またはエラーになる場合は、パスが間違っているか、ファイルが読み取れません。ラッパースクリプトの `--file` 引数と、ファイルの権限（`chmod 600`）を確認してください。

### ステップ 2 — キー名が存在するか確認する（大文字小文字を区別）

```sh
amulet list --file /path/to/secrets.vault
```

キー名はバイト単位で一致する必要があります。`API_KEY` と `api_key` は別のキーとして扱われます。`list` の出力と、ラッパースクリプトで使用しているキー名が正確に一致しているか比較してください。

### ステップ 3 — `verify` でパスフレーズをテストする

`verify` は復号した結果をすぐに破棄します。秘密の値を画面に出さずに、パスフレーズが正しいかどうかだけを確認できます。

```sh
# パスフレーズファイルから読み込む場合
cat ~/.config/amulet/passphrase | amulet verify YOUR_KEY --file /path/to/secrets.vault
echo $?   # 0 = パスフレーズとキーが共に正しい; 1 = 何かが間違っている
```

`verify` が 1 を返す場合は、パスフレーズが間違っています。対話モードで入力して、seal 時と同じパスフレーズであることを確認してください。

```sh
amulet verify --tty YOUR_KEY --file /path/to/secrets.vault
```

### ステップ 4 — Locked モードのマシン不一致を確認する

vault を別のマシンで seal してコピーしてきた場合、Locked モードのエントリはすべての unseal を拒否します。`probe` コマンドで、このホストが使用するマシン識別子を確認できます。

```sh
amulet probe
```

Locked な vault は、それを seal した時にアクティブだった識別子を持つマシンでのみ復号できます。もし `probe` が終了コード 2 を返す場合は、マシン識別子自体が読み取れていません。これも Locked モードの unseal が失敗する原因となります。

マシンを移行する必要がある場合は、[デプロイメント・ガイド](deployment.md#計画的なマシン移行) の移行手順を参照してください。

---

## サービスの起動がタイムアウトする（秘密情報が多い場合）

Amulet は `unseal` の呼び出しごとに Argon2id（64 MiB、3 パス）を実行します。一般的な VPS ハードウェアでは、1 回の呼び出しに 0.5 〜 1 秒程度かかります。15 個以上のエントリをループで読み出すようなラッパースクリプトの場合、合計で 10 〜 30 秒ほどかかり、systemd のデフォルトの `TimeoutStartSec`（90秒）に近づくことがあります。

もしサービスが `start operation timed out` で失敗する場合は、ユニットファイルに明示的なタイムアウト時間を追加してください。

```ini
[Service]
TimeoutStartSec=120
```

秘密の数と、実際の起動時間を測定して値を調整してください。

---

## パスフレーズの変更（全キーの一括更新）

`re-seal` は 1 つのキーずつパスフレーズを変更します。vault 全体のパスフレーズを更新するには、各キーを順番に re-seal してください。

```sh
# まず全キー名をリストアップ
amulet list --file ~/.config/amulet/secrets.vault

# 各キーを re-seal（現在のパスフレーズ、新しいパスフレーズ、確認入力を求められます）
amulet re-seal KEY_ONE   --file ~/.config/amulet/secrets.vault
amulet re-seal KEY_TWO   --file ~/.config/amulet/secrets.vault
amulet re-seal KEY_THREE --file ~/.config/amulet/secrets.vault
```

全キーを一度に更新する単一のコマンドはありません。エントリが多い場合は、キーリストをループに流し込みます。

```sh
amulet list --file ~/.config/amulet/secrets.vault | while read -r key; do
  echo "Re-sealing: $key"
  amulet re-seal "$key" --file ~/.config/amulet/secrets.vault
done
```

実行のたびに現在のパスフレーズと新しいパスフレーズを聞かれます。キーごとに同じ「新しいパスフレーズ」を入力してください。

---

## seal 後の machine_id の変化（OS アップグレード vs. 再インストール）

| イベント | machine_id | Locked vault |
|---------|-----------|--------------|
| `apt upgrade` / `do-release-upgrade` | 維持される | 引き続き動作する |
| OS 再インストール (初期化) | 新しい ID が生成される | **復旧不能** |
| ID を初期化せずに VM クローン | ソースと同じ | クローン先でも復号可能 ([deployment.md](deployment.md)参照) |

OS のインプレースアップグレード（`do-release-upgrade` 等）では、`/etc/machine-id` は維持されます。一方で OS のクリーンインストールを行うと新しい ID が生成され、旧 ID の下で seal された Locked な vault は永久に復号できなくなります。

**対策:** 元の秘密情報をパスワードマネージャー等の別の安全な場所に保管しておき、再インストール後に再度 seal できるようにしておいてください。

---

## クイックリファレンス

| 症状 | 最初の確認事項 |
|------|--------------|
| サービスが即座に終了し、ログが出ない | 同じパスフレーズファイルを使って `amulet verify` を実行 |
| `verify` が 1 を返す | パスフレーズ間違い、キー名間違い、またはマシン不一致 |
| `verify` は 0 を返すがアプリが失敗する | vault 内のキー名と、ラッパースクリプト内のキー名の不一致 |
| サービスの起動がタイムアウトする | ユニットに `TimeoutStartSec=120` を追加し、キーの数を確認 |
| 以前は動いていたがサーバー移行後に失敗する | `amulet probe` を実行。以前のマシンに Locked されている可能性あり |
| 以前は動いていたが OS 再インストール後に失敗する | Locked な vault は復旧不能。元の秘密情報から再度 seal する |

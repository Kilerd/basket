# Japanese (ja): terms beyond the glossary

Decisions made while translating, so later strings stay consistent. The main table is
[glossary.md](glossary.md).

## Messages

- Up / Down (Compose controls) → 作成して起動 / 停止して削除 (Down… → 停止して削除…); sentences name the action, not the button; “Compose Up” stays the feature name
- progress line “Doing X” → 〜中 (起動中, 削除中, 書き出し中); a list placeholder goes after “：” (ネットワークを削除中：%@)
- export (from OrbStack) → 書き出す / 書き出し
- load (an image archive) → 読み込む (same as import)
- variant → バリアント
- memory limit → メモリ上限
- named volume / anonymous volume → 名前付きボリューム / 匿名ボリューム
- bind mount → バインドマウント
- driver → ドライバ
- profile (Compose) / active → プロファイル / アクティブ
- healthcheck → ヘルスチェック
- restart policy → 再起動ポリシー
- privileged mode / unprivileged → 特権モード / 非特権
- capability (Linux) → ケーパビリティ
- namespace → 名前空間
- kernel parameter → カーネルパラメータ
- secrets / configs (Compose) → シークレット / コンフィグ
- reservation (deploy.resources) → リソースの予約
- replicas → レプリカ
- exposed port → EXPOSEされたポート; publish → 公開; host port → ホストポート
- not supported → サポートされていません; left out → 除外されます; ignored → 無視されます
- Compose format → Composeの仕様
- docker shim → dockerシム
- backend → バックエンド
- registry → レジストリ
- layer → レイヤ
- archive → アーカイブ; unzip → 展開
- checksum → チェックサム; altered → 改ざん
- signature / signed / code signed / ad hoc → 署名 / 署名済み / コード署名 / アドホック署名
- notarized → 公証済み
- bundle identifier / team identifier → バンドルID / チームID
- maintainer → メンテナ
- installer → インストーラ
- update information (latest.json) → アップデート情報; update server → アップデートサーバ
- read-only → 読み出し専用
- Applications folder → 「アプリケーション」フォルダ
- exit status → 終了コード
- time out → タイムアウト
- YAML terms: mapping → マッピング, list → リスト, scalar → スカラー, block scalar → ブロックスカラー, flow sequence / flow mapping / flow collection → フローシーケンス / フローマッピング / フローコレクション, anchor → アンカー, alias → エイリアス, tag → タグ, node → ノード, merge key → マージキー, boolean → ブール値, integer → 整数, number → 数値, string → 文字列, null value → null値
- indentation → インデント; escape sequence → エスケープシーケンス; quote (character) → 引用符
- “line N, column M” → N行目、M列目
- “expected X, found Y” → Xが必要ですが、Yが指定されています

## Interface

- “… Anyway” buttons → このまま〜 (このまま削除, このまま終了, このまま再起動, このまま停止)
- Kill (SIGKILL) → 強制終了; Killing… → 強制終了中…
- Try Again → 再試行; Dismiss / Close → 閉じる; Check Again → 再確認; Check Now → 今すぐ確認
- Reload (logs) → 再読み込み (same as Refresh)
- Enable / Disable (buttons) → 有効にする / 無効にする; toggles on / off → オン / オフ
- New Container / Machine / Network / Volume → 新規コンテナ / 新規マシン / 新規ネットワーク / 新規ボリューム
- Show in Finder / Reveal → Finderで表示 / 表示
- Select All / Select None → すべてを選択 / 選択を解除
- Down and Delete Volumes… → 停止して削除（ボリュームも）…; “Take X down?” → 「X」を停止して削除しますか？
- container API server → container APIサーバ; Remove Unused → 未使用の項目を削除; Created (date) → 作成日時, Created (state) → 作成済み
- formulas use full-width ＋ ＝ with no spaces; “(recommended)” → （推奨）; no space after a leading sentence placeholder
- Keep Only linux/arm64 → linux/arm64のみ残す; Slimming… → スリム化中…
- Restore (image archive) → 復元
- empty state “No Containers” → コンテナがありません; “No Results for X” → 「X」の結果はありません
- “Couldn't load X” → Xを取得できませんでした (avoids 読み込む, which means import)
- states: Running 実行中, Stopped 停止, Stopping 停止中, Unknown 不明, Created (state) 作成済み, Exited 終了, Paused 一時停止, Restarting 再起動中, Removing 削除中, Dead デッド
- table columns: Name 名前, State 状態, Size サイズ, On Disk ディスク上, Used By 使用元, In Basket Basket内, Created 作成日時, Subnet サブネット, Gateway ゲートウェイ, Mode モード, Capacity 容量, Tag タグ, Digest ダイジェスト, Format フォーマット, Home ホーム, Import 読み込み
- detail tabs: Info 情報, Logs ログ, Stats 統計, Inspect インスペクト, Overview 概要
- Host Memory (column / section) → このMacのメモリ; Memory (host) / Memory (guest) → メモリ（このMac） / メモリ（ゲスト）; Host (real) → このMac（実メモリ）
- Guest in use → ゲスト使用量; VM overhead / VM footprint → VMオーバーヘッド / VMフットプリント; Limits → 上限; Top consumers → 使用量上位
- Stranded (label) → 滞留メモリ; “%@ reclaimable” → %@を解放可能
- idle for <duration> → <duration>前からアイドル状態 (works with any unit; avoids “2時間間”); Stop Idle Containers → アイドル状態のコンテナを停止
- Exempt (Memory Saver) → 除外; Exempt from Memory Saver → メモリセーバーから除外
- Memory Saver activity “Recently Returned” → 最近の解放
- writable layer → 書き込み可能レイヤ; sparse (disk image) → スパース
- dangling (image) → ダングリング; untagged → タグなし; reference (image name:tag) → 参照
- not compared / not importable → 未比較 / 読み込み不可
- Follow (logs) → 追従; following → 追従中
- Disk I/O read / write → 読：%@ / 書：%@
- Setup (noun) → セットアップ; Setup assistant → 設定アシスタント (macOS term); Set Up Basket → Basketを設定
- Summary (setup) → まとめ; Welcome → ようこそ; Ready → 準備完了
- What's New → 新機能; release notes → リリースノート; You're up to date → 最新の状態です
- Optional (field prompt) → 省略可; recommended → 推奨
- counters: 個 for containers, images, volumes, networks, machines, services, CPUs (“%lld個のコンテナ”); 件 for conflicts and attachments; “%lld of %lld” → “%2$lld個中%1$lld個” (or “%1$lld/%2$lld” where space is tight)
- Step %lld of %lld → 手順%1$lld/%2$lld

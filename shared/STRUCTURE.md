# /shared/ Directory Structure Rules

Soul System の全コンテナが共有する `/shared/` ボリュームの配置規則。
ファイルの追加・移動・削除はこのドキュメントに従うこと。

---

## ディレクトリ一覧

### `inbox/`
- **目的**: 新規タスクの投入先
- **命名規則**: `task_{unix_ts}_{random_4digit}.json`
- **ライフサイクル**: UIまたはbotから投入 → ゴリラが検出しdiscussionsへ移動 → inboxから消える
- **保持期間**: 処理済みタスクは残らない（ゴリラが即座に移動する）
- **注意**: `.gitkeep` のみ常駐

### `discussions/{task_id}/`
- **目的**: タスクの議論プロセス（ラウンドごとの投票・意見）
- **命名規則**:
  - `task.json` — 元タスク情報
  - `status.json` — `{status, current_round, max_rounds}`
  - `comments.json` — ユーザーコメント
  - `round_{n}/{node}.json` — 各ノードの投票・意見
- **ライフサイクル**: ゴリラが作成 → 各ノードがラウンドで議論 → 合意後にdecisionsへ → アーカイブ時にarchiveへ移動
- **保持期間**: アーカイブ処理が完了するまで
- **アクティブ状態**: `status.json` の `status` が `"discussing"` のもののみデーモンが処理する

### `decisions/`
- **目的**: 合意結果・実行結果の格納
- **命名規則**:
  - `{task_id}.json` — 決定レコード
  - `{task_id}_result.json` — 実行結果
  - `{task_id}_progress.jsonl` — リアルタイム実行ストリーム (NDJSON)
  - `{task_id}_announce_progress.jsonl` — 発表ストリーム (NDJSON)
  - `{task_id}_history.json` — 実行履歴（リトライ含む全記録）
  - `{task_id}_progress_attempt{n}.jsonl` — リトライ前の実行ストリームバックアップ
- **ライフサイクル**: コンセンサス後に作成 → 発表 → 実行 → 結果記録 → archive へ移動
- **保持期間**: アーカイブ処理が完了するまで
- **アクティブ状態**: `"pending_announcement"`, `"announcing"`, `"announced"`, `"executing"` はデーモンが参照中。`"completed"`, `"failed"`, `"rejected"` はアーカイブ可能
- **アーカイブ対象**: タスクIDに紐づく全ファイル（`.json`, `_result.json`, `_progress.jsonl`, `_announce_progress.jsonl`, `_history.json`, `_progress_attempt*.jsonl`）を一括移動
- **注意**: `.gitkeep` のみ常駐

### `archive/`
- **目的**: 完了タスクの永続保管
- **命名規則**: `archive/YYYY-MM/{task_id}/` 配下に discussion, decision, result を一式格納
  - `discussion/` — 議論データ（`discussions/{task_id}/` から移動）
  - `{task_id}.json` — 決定レコード
  - `{task_id}_result.json` — 実行結果
  - `{task_id}_announce_progress.jsonl` — 発表ストリーム
  - `{task_id}_history.json` — 実行履歴
  - `{task_id}_progress.jsonl` — 実行ストリーム
  - `{task_id}_progress_attempt{n}.jsonl` — リトライバックアップ（存在する場合）
- **トップレベルファイル**:
  - `index.jsonl` — 全アーカイブタスクの索引。1行1タスクのNDJSON形式
- **ライフサイクル**: タスク完了後にアーカイブ（手動またはタスク実行時）
- **保持期間**: 無期限（履歴として保管）
- **クリーンアップルール**:
  - `index.jsonl` との整合性を常に維持すること
  - トップレベルに直接置かれたタスクJSONファイルは禁止。必ず `YYYY-MM/{task_id}/` 配下に格納すること
  - `discussion_current/`, `discussion_leftover/` は旧アーカイブ形式の残骸。存在する場合は `discussion/` に統合すること

### `nodes/{node}/`
- **目的**: 各ブレインノード (panda, gorilla, triceratops) の状態管理
- **命名規則**:
  - `params.json` — 動的パラメータ（risk_tolerance, safety_weight 等）
  - `activity.json` — 現在のアクティビティ状態
- **ライフサイクル**: デーモン起動時に作成 → 常時更新
- **保持期間**: 永続（削除不可）
- **警告**: **触れてはならないファイル**。デーモンが常時読み書きする

### `evaluations/{cycle_id}/`
- **目的**: ノード間の相互評価サイクルデータ
- **命名規則**: `eval_YYYYMMDD_HHmmss/` 配下に各ノードの評価JSONと `summary.json`
- **ライフサイクル**: スケジューラが6時間ごとにトリガー → 各ノードが評価 → サマリー生成
- **保持期間**: 90日
- **クリーンアップルール**: 90日経過した cycle ディレクトリは削除可能

### `logs/YYYY-MM-DD/`
- **目的**: 日次ログ（各ノードのデーモンログ、claudeログ）
- **命名規則**: `{node}.log`, `{node}_claude.log`
- **ライフサイクル**: デーモンが毎日自動作成 → ログ追記
- **保持期間**: 30日
- **クリーンアップルール**: 30日経過した日付ディレクトリは削除可能

### `rebuild_requests/`
- **目的**: コンテナリビルドのリクエスト管理
- **命名規則**: `rebuild_{unix_ts}_{random_4digit}.json`
- **ライフサイクル**: トリケラトプスがリクエスト → ゴリラが承認 → パンダが実行 → completed/failed
- **アクティブ状態**: `"pending"`, `"pending_approval"`, `"approved"`, `"executing"` はデーモンが参照中
- **保持期間**: completed/failed/rejected は7日後にアーカイブ可能
- **クリーンアップルール**: `status` が `"completed"`, `"failed"`, `"rejected"` のファイルは `rebuild_requests/archive/` に移動可能
- **アーカイブ先**: `rebuild_requests/archive/`

### `personality_improvement/`
- **目的**: ユーザーフィードバックによるパーソナリティ改善プロセス
- **命名規則**:
  - `trigger.json` — 現在のトリガー状態
  - `pending_YYYYMMDD_HHmmss.json` — 質問生成ファイル
  - `answers_YYYYMMDD_HHmmss.json` — 回答ファイル
  - `manual_trigger.json` — 手動トリガー
  - `question_history.jsonl` — 質問履歴
  - `history/YYYYMMDD_HHmmss.json` — 処理履歴
- **アクティブ状態**: `trigger.json` の `status` が `"pending"`, `"questions_sent"`, `"answers_received"` のときデーモンが処理中
- **保持期間**: trigger.json の status が `"completed"` のとき、pending_* と answers_* は30日後にアーカイブ可能
- **クリーンアップルール**:
  - `trigger.json` — **触れてはならない**（デーモンが常時監視）
  - `manual_trigger.json` — **触れてはならない**
  - `question_history.jsonl` — **触れてはならない**（累積履歴）
  - `history/` — 永続保管（パラメータ変更履歴）
  - `pending_*`, `answers_*` — trigger.json が completed で、対応する history エントリが存在するもののみアーカイブ可能
- **アーカイブ先**: `personality_improvement/archive/`

### `alerts/`
- **目的**: 監視アラートの記録
- **命名規則**: `{type}_alert_{unix_ts}_{random_4digit}.json`（type: panda_alert, unified_alert）
- **ライフサイクル**: 監視デーモンが異常検出時に作成
- **保持期間**: 30日
- **クリーンアップルール**: 30日経過したアラートファイルは `alerts/archive/` に移動可能
- **注意**: デーモンコードがアラートファイルを直接参照する実装は確認されていないが、安全のため保持期間を設定

### `monitoring/`
- **目的**: パンダの統合監視システムのデータ
- **命名規則**:
  - `latest.json` — 最新の監視結果
  - `alerts.jsonl` — アラート累積ログ
  - `integrity.json` — 整合性チェック結果
  - `policy.json` — 監視ポリシー
  - `false_positives.json` — 誤検出記録
  - `personality_update_marker.json` — パーソナリティ更新マーカー
  - `backups/` — バックアップデータ
  - `pending_actions/` — 保留中のアクション
  - `reports/` — 監視レポート
  - `validation/` — バリデーション結果
- **ライフサイクル**: パンダの監視デーモンが常時更新
- **保持期間**: 永続（ポリシー・設定ファイル）、reports は90日
- **警告**: **触れてはならないファイル** — `latest.json`, `policy.json`, `integrity.json`, `false_positives.json`, `personality_update_marker.json`

### `workspace/`
- **目的**: タスク実行時の作業出力エリア
- **命名規則**:
  - タスク関連ファイル: `{task_id}_*.md` または `{task_id}_*.json` — タスクIDをプレフィックスにすること（アーカイブ判定に使用）
  - サブディレクトリ: `{task_id}/` — タスク固有の作業ディレクトリ
  - 常駐サブシステム: `proactive-suggestions/` 等の独自ディレクトリは別途定義
- **ライフサイクル**: タスク実行中に作成 → 対応タスクの完了後にアーカイブ可能
- **保持期間**: 対応タスクが archive に移動済みなら30日後にアーカイブ可能
- **クリーンアップルール**: 対応タスクが archive に存在し完了済みであることを確認してから `workspace/archive/` に移動
- **アーカイブ先**: `workspace/archive/`
- **注意**: タスクIDをファイル名に含めないファイルは、どのタスクに属するか不明になりアーカイブ判定が困難になるため避けること

### `workspace/proactive-suggestions/`
- **目的**: プロアクティブ提案システムの稼働データ
- **命名規則**: サブディレクトリ構成
  - `config.json` — 設定
  - `secrets.env` — **シークレットファイル（API キー等）**
  - `state/` — 状態管理
  - `suggestions/` — 提案データ
  - `triggers/` — トリガー定義
  - `broadcasts/` — 配信データ
  - `feedback/` — フィードバック
  - `dryrun/` — テスト実行データ
- **警告**: **現状維持。secrets.env は絶対に移動・削除・コピーしないこと**
- **保持期間**: 永続（アクティブサブシステム）

### `bot_commands/`
- **目的**: ボットコマンドの状態管理
- **命名規則**: `{feature}_status.json`
- **ライフサイクル**: ボット操作時に更新
- **保持期間**: 永続

### `openclaw/`
- **目的**: OpenClaw 連携データ
- **命名規則**: `suggestions/` 配下にリサーチ結果等
- **ライフサイクル**: リサーチリクエスト → 実行 → 結果保存
- **保持期間**: 90日

### `attachments/{task_id}/`
- **目的**: タスクに紐づく添付ファイル
- **命名規則**: `attachments/{task_id}/` 配下に任意ファイル
- **ライフサイクル**: タスク作成時にアップロード → タスク完了後もアーカイブ参照用に保持
- **保持期間**: 対応タスクが archive に移動後90日

### `host_metrics/`
- **目的**: ホストマシンのメトリクス
- **命名規則**: `metrics.json`
- **ライフサイクル**: 定期的に更新
- **保持期間**: 永続（最新値のみ保持）
- **警告**: **触れてはならないファイル**

### `health.json`
- **目的**: システム全体のヘルスチェック状態
- **警告**: **絶対に触れてはならないファイル**。デーモンが常時更新する

---

## シークレットファイルの取り扱いルール

以下のファイルにはAPIキー・認証情報が含まれる可能性がある:
- `workspace/proactive-suggestions/secrets.env`

**ルール**:
1. シークレットファイルは **絶対に** 移動・コピー・削除しないこと
2. ログやレポートにシークレットの内容を記録しないこと
3. アーカイブ対象から常に除外すること
4. バックアップが必要な場合は暗号化した上で行うこと

---

## 全般ルール

1. **アトミック書き込み**: JSONファイルの書き込みは `.tmp` に書いてから `mv` でリネームすること
2. **タイムスタンプ**: すべて UTC ISO 8601 形式
3. **タスクID**: `task_{unix_ts}_{random_4digit}` 形式
4. **アーカイブ移動**: 各ディレクトリの `archive/` サブフォルダに移動する
5. **削除禁止**: 原則としてファイルは削除ではなくアーカイブに移動する
6. **.gitkeep**: 空ディレクトリ維持用。削除しないこと

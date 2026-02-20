# Soul System - Project Rules

## Language
- Claudeとの会話では日本語を使用すること

## Container修正フロー
- ソースや設定ファイルを修正する場合は以下の順序で行うこと:
  1. まずコンテナ内で直接修正（`docker cp` / `docker exec`）して動作確認する
  2. 動作に問題なければ、ホスト側のソースファイルを修正する
  3. `docker compose build <service>` でイメージをリビルドしてから `docker compose up -d <service>` で反映する
- **`docker compose up -d` だけではソース変更は反映されない**。必ず `build` してから `up` すること
- `docker cp` でコンテナに入れた変更は、コンテナ再起動（`up -d`）で消える。テスト用の一時的な手段として使い、最終的には必ずリビルドで反映すること
- このルールはClaude Code実行時もBrain実行時も共通

### コンテナのソースマウント状況
以下を把握し、修正→反映の方法を間違えないこと:
- **Brainコンテナ** (panda/gorilla/triceratops): `/brain/lib/` 等のコードはイメージに焼き込み。**ソース修正後はリビルド必須**。ホストからマウントされるのは `CLAUDE.md` と `.mcp.json` のみ
- **OpenClaw**: 全ファイルがイメージに焼き込み。**ソース修正後はリビルド必須**
- **OpenClaw Gateway / Web UI / Scheduler**: 同上。**リビルド必須**
- **共有データ** (`/shared`): bind mountでホストと同期。ファイル修正は即反映（リビルド不要）

## Documentation
- 新しい仕組み・機能を導入した場合は、README.mdに反映すること
  - 小規模な機能: README.md内の該当セクションに直接追記
  - 大規模な機能: docs/に別ドキュメントを作成し、README.mdからリンク
- このルールはClaude Code実行時もBrain実行時も共通

## Git Workflow
- タスク実行後、変更内容をユーザに確認してからgit commitし、pushすること
- ユーザの承認なしにcommit/pushしないこと

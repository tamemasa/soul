# Soul System - Project Rules

## Language
- Claudeとの会話では日本語を使用すること

## Container修正フロー
- ソースや設定ファイルを修正する場合は以下の順序で行うこと:
  1. まずコンテナ内で直接修正して動作確認する
  2. 動作に問題なければ、Dockerfileやイメージビルドに使われるファイル（entrypoint.sh等）を修正する
  3. コンテナをリビルドして実機に反映する
- このルールはClaude Code実行時もBrain実行時も共通

## Documentation
- 新しい仕組み・機能を導入した場合は、README.mdに反映すること
  - 小規模な機能: README.md内の該当セクションに直接追記
  - 大規模な機能: docs/に別ドキュメントを作成し、README.mdからリンク
- このルールはClaude Code実行時もBrain実行時も共通

## Git Workflow
- タスク実行後、変更内容をユーザに確認してからgit commitし、pushすること
- ユーザの承認なしにcommit/pushしないこと

# Soul System

呪術廻戦のパンダに着想を得たマルチエージェントAIシステム。
3つのBrainノード（パンダ・ゴリラ・トリケラトプス）が相互に議論・評価し合いながら、自律的にタスクを遂行する。

> パンダが自律した受戒として成立するには、3つの魂がお互いに干渉し合うことが必要。

## Architecture

```
┌──────────────────────── Soul System ────────────────────────┐
│                                                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────────────┐    │
│  │brain-panda │  │brain-      │  │brain-triceratops   │    │
│  │  (安全重視) │  │  gorilla   │  │    (調停者)         │    │
│  │            │  │  (冒険的)   │  │                    │    │
│  │Claude Code │  │Claude Code │  │  Claude Code       │    │
│  │+soul-daemon│  │+soul-daemon│  │  +soul-daemon      │    │
│  └─────┬──────┘  └─────┬──────┘  └──────────┬─────────┘    │
│        │               │                     │              │
│        └───────────────┼─────────────────────┘              │
│                        │                                    │
│               ┌────────▼────────┐    ┌──────────────────┐   │
│               │  /shared volume │    │  ./soul chat     │   │
│               │                 │◄───│  (Gateway UI)    │   │
│               │  inbox/         │    └──────────────────┘   │
│               │  discussions/   │                           │
│               │  decisions/     │                           │
│               │  evaluations/   │                           │
│               │  logs/          │                           │
│               └────────┬────────┘                           │
│                        │                                    │
│  ┌─────────────────────▼────────────────────────────────┐   │
│  │                 Worker Nodes                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │ OpenClaw │  │ Worker-2 │  │ Worker-N │           │   │
│  │  └──────────┘  └──────────┘  └──────────┘           │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐                                           │
│  │  scheduler   │ ← 定期評価サイクル発火(6h毎)              │
│  └──────────────┘                                           │
└──────────────────────────────────────────────────────────────┘
```

## Concept

### 3つのBrainノード

| ノード | 特性 | 役割 |
|--------|------|------|
| **Panda** (パンダ) | 安全重視 | リスク回避、安定性優先、テスト・検証を重視 |
| **Gorilla** (ゴリラ) | 冒険的 | 革新性・スピード優先、新技術推奨、挑戦的 |
| **Triceratops** (トリケラトプス) | 調停者 | バランス重視、実用的妥協点を見出す、デッドロック打破 |

各ノードは独立したDockerコンテナで稼働し、Claude Codeをエージェントとして搭載する。
性格は `CLAUDE.md`（システムプロンプト）と `params.json`（数値パラメータ）で定義される。

### 合意形成メカニズム

- **タスク駆動**: タスクが投入されると3ノードで議論し、2/3の合意で実行
- **定期評価**: スケジューラが6時間毎に相互評価サイクルを発火
- **パラメータチューニング**: 2/3が合意すれば、残り1ノードのパラメータを変更し再作成

### Workerノード

Brainノードの合意形成のもとで作成・運用されるアプリケーション実行ノード。
最初のWorkerとしてOpenClawの運用を予定。

## Directory Structure

```
soul/
├── soul                        # メインCLIエントリーポイント
├── docker-compose.yml          # 全サービス定義
├── .env                        # 環境変数 (SOUL_UID, SOUL_GID等)
├── .env.example                # 環境変数テンプレート
├── brain/
│   ├── Dockerfile              # Brainノード共通イメージ
│   ├── soul-daemon.sh          # コア: ファイル監視 + Claude Code呼び出し
│   ├── lib/
│   │   ├── watcher.sh          # 共有フォルダ監視・タスク検知
│   │   ├── discussion.sh       # 議論プロトコル (Round制)
│   │   ├── consensus.sh        # 合意判定・決定ロジック
│   │   ├── evaluation.sh       # 相互評価・パラメータチューニング
│   │   └── worker-manager.sh   # Worker作成・管理
│   ├── protocols/
│   │   ├── discussion.md       # 議論プロンプトテンプレート
│   │   ├── evaluation.md       # 評価プロンプトテンプレート
│   │   └── task-execution.md   # タスク実行テンプレート
│   └── nodes/
│       ├── panda/
│       │   └── CLAUDE.md       # パンダの性格・判断基準
│       ├── gorilla/
│       │   └── CLAUDE.md
│       └── triceratops/
│           └── CLAUDE.md
├── gateway/
│   ├── soul-chat.sh            # 対話型チャットUI (REPL + 単発コマンド)
│   └── commands.sh             # チャットコマンド実装
├── worker/
│   ├── Dockerfile              # Worker共通イメージ
│   ├── entrypoint.sh           # Workerエントリーポイント
│   └── templates/
│       └── openclaw/           # OpenClaw用テンプレート
├── web-ui/
│   ├── Dockerfile              # Web UIイメージ
│   ├── server.js               # Express APIサーバー
│   ├── routes/                 # APIエンドポイント
│   ├── lib/                    # ファイル読み書きヘルパー
│   └── public/                 # フロントエンド (HTML/CSS/JS)
├── scheduler/
│   ├── Dockerfile              # スケジューライメージ
│   └── cron-tasks.sh           # 定期評価・クリーンアップ
├── network-restrict.sh          # LAN隔離用iptablesルール管理
├── examples/
│   └── sample-task.json        # タスク投入サンプル
└── shared/                     # コンテナ間共有ボリューム (bind mount)
    ├── nodes/                  # ノードパラメータ (全Brainから読み書き可能)
    │   ├── panda/params.json
    │   ├── gorilla/params.json
    │   └── triceratops/params.json
    ├── inbox/                  # タスクキュー
    ├── discussions/            # 議論プロセス
    ├── decisions/              # 合意結果・実行結果
    ├── evaluations/            # 相互評価
    └── logs/                   # システムログ
```

## Setup

### Prerequisites

- Docker & Docker Compose
- Claude Code の認証 (以下いずれか):
  - **Claude Max plan** (推奨): ホストで `claude login` 済みであること
  - **Anthropic API Key**: `.env` に `ANTHROPIC_API_KEY` を設定
- 対応プラットフォーム: Raspberry Pi (ARM64), Linux (x86_64)

### Quick Start

```bash
# 1. クローン
git clone https://github.com/tamemasa/soul.git
cd soul

# 2. 認証設定
#    Max plan の場合: ホストで claude login 済みなら設定不要
#    API Key の場合:
cp .env.example .env
# .env を編集し ANTHROPIC_API_KEY を設定

# 3. 起動
./soul up

# 4. チャットインターフェイスを開く
./soul chat
```

### Authentication

コンテナ内の Claude Code は、ホストの `~/.claude/.credentials.json` をread-onlyマウントして認証する。
コンテナ自体はホストユーザーの UID/GID (`SOUL_UID`/`SOUL_GID`, デフォルト1000) で実行されるため、
`shared/` 内のファイルはホストユーザー所有で作成される。

```bash
# UID/GID をカスタマイズする場合は .env に設定:
SOUL_UID=1000
SOUL_GID=1000
```

### CLI Commands

```bash
./soul up        # 全コンテナ起動
./soul down      # 全コンテナ停止
./soul chat      # 対話型チャットUI起動
./soul web       # Web UI の URL を表示
./soul logs      # Docker logs をフォロー
./soul rebuild   # 全コンテナ再ビルド・再起動
```

## User Interface

### Web UI

ブラウザから `http://<host-ip>:3000` でアクセスできるWeb UIを搭載。

- **ダッシュボード**: ノード状態・統計サマリ・最近の議論
- **タスク投入**: フォームからタスクや質問を投入
- **議論ビューア**: ラウンドごとの投票・意見をタイムライン形式で表示
- **決定一覧**: 合意結果と実行結果の閲覧
- **パラメータ管理**: スライダーで各ノードのparams.jsonをリアルタイム編集
- **評価履歴**: 相互評価サイクルの詳細とリチューニング結果
- **ログビューア**: ノード別のログをリアルタイム表示

SSE（Server-Sent Events）によりファイル変更を自動検知して画面を更新する。
ポート番号は `.env` の `WEB_UI_PORT` で変更可能（デフォルト: 3000）。

### Chat UI

`./soul chat` で起動するチャット型インターフェイスからもBrainシステムをフル操作できる。

```
  ____              _
 / ___|  ___  _   _| |
 \___ \ / _ \| | | | |
  ___) | (_) | |_| | |
 |____/ \___/ \__,_|_|

  3-Brain Autonomous Agent System

soul> セキュリティ監査を実施して
  Task submitted: task_1770708677_9395

soul> /status
  ═══ Soul System Status ═══
  ● panda (running)
  ● gorilla (running)
  ● triceratops (running)

soul> /discussion task_1770708677_9395
  ── Round 1 ──
  panda [approve_with_modification] 内部パラメータの詳細は公開しないよう注意...
  gorilla [approve] 生き生きとした紹介にすべき...
  triceratops [approve] 各ノードを公平に描写すべき...
  ── Decision ──
  Result: approved
  Executor: panda
```

### Chat Commands

| コマンド | 説明 |
|---------|------|
| (自由テキスト) | Brainにタスクとして投入 |
| `/task <説明>` | タスクを明示的に投入 |
| `/ask <質問>` | Brainに質問（実行なし、議論のみ） |
| `/status` | システム全体のステータス表示 |
| `/discussions` | アクティブな議論一覧 |
| `/discussion <id>` | 議論の詳細（各ノードの意見・投票）を表示 |
| `/decisions` | 合意済み決定の一覧 |
| `/eval` | 相互評価サイクルを手動発火 |
| `/params [node]` | パラメータ表示（全ノードor指定ノード） |
| `/set <node> <key> <val>` | パラメータを直接変更 |
| `/workers` | Workerノード一覧 |
| `/logs [node] [lines]` | 直近ログ表示 |
| `/restart <node>` | Brainノードコンテナを再起動 |
| `/help` | ヘルプ表示 |

単発コマンドとしても実行可能:
```bash
./soul chat /status        # ステータスだけ表示して終了
./soul chat /params panda  # パンダのパラメータ確認
```

## Communication Protocol

Brainノード間の通信は共有ボリューム上のJSONファイルで行う。
各ノードは **自分の名前のファイルのみ書き込む** ことで競合を回避する。

### タスク処理フロー

```
1. タスクが shared/inbox/{task_id}.json に投入
2. Gorilla(コーディネーター)が検知 → discussions/{task_id}/ に議論スペース作成
3. Round 1: 各Brainが独立して意見を書き込み
   → discussions/{task_id}/round_1/{node_name}.json
4. Round 2: 他ノードの意見を読み、修正意見を書き込み (必要な場合)
   → discussions/{task_id}/round_2/{node_name}.json
5. 合意判定: 2/3同意 → decisions/{task_id}.json
6. 不合意時: 最大Round 3実施 → それでも不一致ならトリケラトプスが調停
7. 決定に基づきExecutor(担当ノード)がタスクを実行
```

### データフォーマット

タスク投入:
```json
{
  "id": "task_001",
  "type": "task",
  "title": "Workerノードのヘルスチェック機能追加",
  "description": "各Workerノードの生存確認を定期実行する仕組みを構築",
  "priority": "medium",
  "created_at": "2026-02-10T12:00:00Z",
  "status": "pending"
}
```

議論の回答:
```json
{
  "node": "panda",
  "round": 1,
  "vote": "approve_with_modification",
  "opinion": "賛成だが、ヘルスチェック失敗時の自動復旧は段階的に導入すべき",
  "proposed_approach": "...",
  "concerns": ["自動復旧の暴走リスク"],
  "timestamp": "2026-02-10T12:01:30Z"
}
```

投票種別: `approve` / `approve_with_modification` / `reject`

### 相互評価サイクル

```
1. scheduler が6時間毎に evaluations/{cycle_id}/ を作成し評価タスクを発行
   (手動発火: ./soul chat /eval)
2. 各Brainが他2ノードを評価 (スコア: decision_quality, collaboration, effectiveness, parameter_balance)
   → evaluations/{cycle_id}/{evaluator}_evaluates_{target}.json
3. 2/3が「パラメータ変更が必要」(needs_retuning=true) と合意
   → 対象ノードの params.json を更新
```

## Brain Personality Parameters

`shared/nodes/{node}/params.json` で各ノードの振る舞いを数値制御する。
共有ボリューム上にあるため、相互評価によるリチューニングが直接反映される:

| パラメータ | 説明 | Panda | Gorilla | Triceratops |
|-----------|------|-------|---------|-------------|
| `risk_tolerance` | リスク許容度 (0:回避 - 1:積極) | 0.2 | 0.8 | 0.5 |
| `innovation_weight` | 新規アプローチの重み | 0.3 | 0.9 | 0.5 |
| `safety_weight` | 安全性の重み | 0.9 | 0.3 | 0.5 |
| `thoroughness` | 検証の徹底度 | 0.9 | 0.4 | 0.6 |
| `consensus_flexibility` | 合意への柔軟性 (0:固執 - 1:柔軟) | 0.4 | 0.5 | 0.8 |

これらのパラメータは相互評価によって動的にチューニングされる。

## Network Security

コンテナはLAN内デバイスへのアクセスが制限されている。
インターネット（Claude API）とコンテナ間通信は許可される。

```
┌─────────────┐     ┌──────────────┐     ┌──────────┐
│ Soul        │ ──✓──▶ Internet     │     │ LAN      │
│ Containers  │     │ (Claude API) │     │ 192.168. │
│ (br-soul)   │ ──✗──────────────────────▶│ 11.0/24  │
└─────────────┘     └──────────────┘     └──────────┘
```

- **仕組み**: 専用Dockerブリッジ `br-soul` + iptables `DOCKER-USER` チェーンでLANサブネットへの通信をDROP
- **自動適用**: `./soul up` 時にルール適用、`./soul down` 時に除去
- **手動操作**:
  ```bash
  sudo ./network-restrict.sh status   # 現在のルール確認
  sudo ./network-restrict.sh apply    # ルール適用
  sudo ./network-restrict.sh remove   # ルール除去
  ```
- **LAN範囲の変更**: `network-restrict.sh` 内の `LAN_SUBNET` を編集

## Tech Stack

- **Container Runtime**: Docker + Docker Compose
- **AI Agent**: Claude Code (claude-code CLI, non-interactive mode)
- **Communication**: File-based (shared volume, JSON)
- **Scheduler**: cron (6h interval, in scheduler container)
- **User Interface**: Bash-based interactive chat (gateway)
- **Target Platform**: Raspberry Pi (ARM64) / Linux (x86_64)

## Design Principles

1. **自律性**: 3つのBrainが自律的に議論・合意・実行する。人間の介入なしで稼働
2. **相互牽制**: 異なる特性のノードが互いに監視・評価し、暴走を防止
3. **簡素な通信**: ファイルベースの通信でシンプルさと信頼性を両立
4. **進化可能性**: パラメータチューニングによりシステムが自己最適化
5. **拡張性**: Workerノードの追加で対応領域を拡大

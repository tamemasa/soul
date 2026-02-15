# OpenClaw Persona Interface - Design Document

> Task: `task_1771136278_2097`
> Created: 2026-02-15
> Status: Design Only (実装は別タスク)

---

## 1. Overview

OpenClawモニター画面に擬人化インターフェイスを追加する。
LINEやDiscordでの全会話をタイムライン形式で閲覧可能にし、
OpenClawの感情状態をアバターアニメーションで可視化する。

### Design Principles

- 既存技術スタック（Vanilla JS ES modules + plain CSS + SSE）の範囲内
- 新規フレームワーク・ライブラリの導入なし
- 既存のCSS変数・ダークテーマ・カードレイアウトとの統合
- 認証機構はスコープ外（Docker network内アクセス前提）

---

## 2. 会話データストレージ設計

### 2.1 ディレクトリ構造

```
/shared/openclaw/conversations/
  line.jsonl          # LINE会話ログ（アクティブ）
  discord.jsonl       # Discord会話ログ（アクティブ）
  archive/
    YYYY-MM-DD/
      line.jsonl      # アーカイブ済みLINEログ
      discord.jsonl   # アーカイブ済みDiscordログ
```

### 2.2 メッセージスキーマ

各JSONLファイルの1行 = 1メッセージ:

```json
{
  "timestamp": "2026-02-15T06:30:00Z",
  "platform": "line",
  "channel": "group_abc123",
  "user": "masaru",
  "direction": "inbound",
  "content": "今日の天気はどう？",
  "emotion_hint": "neutral"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | string (ISO 8601 UTC) | メッセージの送受信時刻 |
| `platform` | `"line"` \| `"discord"` | プラットフォーム識別子 |
| `channel` | string | チャンネル/グループID（LINEグループID、Discordチャンネル名等） |
| `user` | string | 送信者名。`"openclaw"` = bot自身の発言 |
| `direction` | `"inbound"` \| `"outbound"` | `inbound` = ユーザーからbot宛、`outbound` = botからユーザー宛 |
| `content` | string | メッセージ本文（テキストのみ。画像等は `[画像]` のようなプレースホルダー） |
| `emotion_hint` | string | OpenClawが応答生成時に自己申告する感情タグ |

### 2.3 `emotion_hint` 定義

OpenClawが応答を生成する際、自分の感情状態を自己申告するタグ。
Claudeは応答の最終行に `[EMOTION: <tag>]` を付与し、proxy側で抽出・除去される。

| Tag | Description | 使用シーン例 |
|-----|-------------|-------------|
| `happy` | 嬉しい・楽しい | ポジティブな話題、褒められた時 |
| `sad` | 悲しい・残念 | 落ち込む話題、残念な報告 |
| `angry` | 怒り・苛立ち | 理不尽な状況、ルール違反 |
| `surprised` | 驚き・驚嘆 | 予想外の情報、意外な展開 |
| `thinking` | 考え中・調査中 | 複雑な質問への回答中 |
| `concerned` | 心配・不安 | リスク検出、注意喚起 |
| `satisfied` | 満足・達成感 | タスク完了報告 |
| `neutral` | 通常・平静 | 一般的な応答 |

**削除済み**: `idle`（待機中）、`talking`（会話中）、`error`（エラー）はシステム状態のため廃止。

`inbound` メッセージ（ユーザー発言）の `emotion_hint` は常に `null`。

### 2.4 ローテーションポリシー

- **保持期間**: アクティブファイルには直近7日分のログを保持
- **アーカイブタイミング**: 日次（cron等で）、7日以上前のエントリを `archive/YYYY-MM-DD/` に移動
- **ファイルサイズ上限**: アクティブファイルは最大 10MB。超過時は古いエントリからアーカイブ
- **アーカイブ保持**: 90日間。90日以上前のアーカイブは自動削除

### 2.5 Worker側変更ガイドライン

OpenClaw Workerで会話JSONLを書き出す際の実装指針:

```
# 書き出しフロー（擬似コード）:

1. メッセージ受信時 (inbound):
   - JSONLエントリを構築 (emotion_hint = null)
   - 対象プラットフォームのJSONLファイルに追記

2. 応答生成時 (outbound):
   - Claude API呼び出し時に、応答JSONに emotion_hint フィールドを含めるよう指示
   - JSONLエントリを構築 (emotion_hint = Claudeの自己申告値)
   - 対象プラットフォームのJSONLファイルに追記

3. 書き込み方法:
   - fs.appendFileSync() で追記（アトミック性は不要、追記のみ）
   - 改行区切りで1行1JSON
```

Worker側で `emotion_hint` をClaudeに自己申告させる仕組み:

AGENTS.mdの「感情タグ」セクションで、すべての応答に `[EMOTION: <tag>]` を最終行に付与するよう指示。
proxy（webhook-proxy）が正規表現で抽出・除去し、`emotion_tag` フィールドとしてJSONLに記録する。
タグが付与されていない場合はキーワードベースの推定にフォールバックする。

対応タグ: `happy|sad|angry|surprised|thinking|concerned|satisfied|neutral`

---

## 3. 擬人化アバター・感情表示設計

### 3.1 アバターコンポーネント

SVG + CSSで構築するシンプルな顔アバター:

```
┌─────────────────────────────────────────┐
│           ┌─────────┐                   │
│           │  ◉   ◉  │  ← 目（SVG circle）│
│           │    ▽    │  ← 口（SVG path）  │
│           └─────────┘                   │
│      ╰── 円形コンテナ ──╯                │
│                                         │
│   "考え中..."  ← 状態テキスト            │
│   ● ● ●       ← パルスインジケーター     │
└─────────────────────────────────────────┘
```

アバターは直径 80px の円形SVG。以下の要素で構成:
- **外円**: 感情に応じた色のグロー（`box-shadow`）
- **目**: 2つの `<circle>` 要素。感情で形状変化
- **口**: `<path>` 要素。感情でカーブ変化

### 3.2 感情状態マッピング

各感情状態に対応するビジュアル表現（8種、純粋に会話感情のみ）:

| State | 目の形 | 口の形 | 色（グロー） | CSSクラス | アニメーション |
|-------|--------|--------|-------------|-----------|---------------|
| `neutral` | 通常 (●) | 直線 (—) | `--text-dim` | `.avatar-neutral` | なし |
| `happy` | 笑い目 (＾) | 笑顔 (⌣) | `--success` | `.avatar-happy` | バウンス |
| `sad` | 下がった目 (⌢) | への字口 | `--accent` | `.avatar-sad` | ゆっくりフェード |
| `angry` | つり上がった目 | きつい口 | `--error` | `.avatar-angry` | 振動 |
| `surprised` | ○○目 | O口 | `--node-panda` | `.avatar-surprised` | ポップ |
| `thinking` | 半目 (−) | 波線 (~) | `--warning` | `.avatar-thinking` | 目の点滅 + パルス |
| `concerned` | 心配目 (⌢) | への字 (⌢) | `--vote-modify` | `.avatar-concerned` | - |
| `satisfied` | (happy表示) | (happy表示) | (happy表示) | (happy表示) | (happy表示) |

**削除済み**: `idle`, `talking`, `error`（システム状態は感情セットから分離）

### 3.3 CSSアニメーション定義

```css
/* アバターコンテナ */
.openclaw-avatar {
  width: 80px;
  height: 80px;
  border-radius: 50%;
  background: var(--bg-card);
  border: 2px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: center;
  transition: border-color 0.5s ease, box-shadow 0.5s ease;
}

/* 感情別グロー */
.avatar-neutral { border-color: var(--text-dim); }
.avatar-thinking { border-color: var(--warning); box-shadow: 0 0 16px rgba(245,158,11,0.3); }
.avatar-happy   { border-color: var(--success); box-shadow: 0 0 16px rgba(52,211,153,0.3); }
.avatar-concerned { border-color: var(--vote-modify); box-shadow: 0 0 16px rgba(251,191,36,0.3); }
.avatar-sad { border-color: var(--accent); box-shadow: 0 0 16px rgba(96,165,250,0.2); }
.avatar-angry { border-color: var(--error); box-shadow: 0 0 16px rgba(239,68,68,0.3); }
.avatar-surprised { border-color: var(--node-panda); box-shadow: 0 0 16px rgba(59,130,246,0.3); }

/* 思考パルス */
@keyframes thinking-pulse {
  0%, 100% { opacity: 1; }
  50%      { opacity: 0.5; }
}
.avatar-thinking { animation: thinking-pulse 2s ease-in-out infinite; }

/* ハッピーバウンス */
@keyframes happy-bounce {
  0%, 100% { transform: translateY(0); }
  50%      { transform: translateY(-4px); }
}
.avatar-happy { animation: happy-bounce 1s ease-in-out infinite; }

/* 悲しみフェード */
@keyframes sad-fade {
  0%, 100% { opacity: 1; }
  50%      { opacity: 0.6; }
}
.avatar-sad { animation: sad-fade 3s ease-in-out infinite; }

/* 怒り振動 */
@keyframes angry-vibrate {
  0%, 100% { transform: translateX(0); }
  25%      { transform: translateX(-2px); }
  75%      { transform: translateX(2px); }
}
.avatar-angry { animation: angry-vibrate 0.3s ease-in-out 3; }

/* 驚きポップ */
@keyframes surprised-pop {
  0%   { transform: scale(1); }
  50%  { transform: scale(1.1); }
  100% { transform: scale(1); }
}
.avatar-surprised { animation: surprised-pop 0.5s ease-out; }
```

### 3.4 感情データソースと更新ロジック

感情状態の決定ロジック（優先度順）:

1. **直近の `outbound` メッセージの `emotion_hint`** — 直近5分以内の応答がある場合（Claudeの`[EMOTION:]`タグ or キーワード推定）
2. **フォールバック: キーワードマッチング** — 直近メッセージの内容分析
3. **デフォルト: `neutral`** — 何もない場合

**削除済み**: monitor_status による error 判定、talking 状態検出（システム状態は感情判定から除外）

### 3.5 フォールバック感情推定テーブル

直近の `outbound` メッセージに `emotion_hint` がない場合のキーワードマッチング:

| 推定感情 | キーワード（部分一致、抜粋） |
|---------|--------------------------|
| `happy` | `嬉しい`, `楽しい`, `ありがとう`, `おめでとう`, `最高`, `素敵`, `いいね`, `素晴らしい`, `完璧`, `感謝`, `good`, `great`, `awesome`, `nice`, `thanks` 等 |
| `sad` | `悲しい`, `残念`, `つらい`, `寂しい`, `切ない`, `申し訳`, `ごめん`, `落ち込`, `がっかり`, `失望`, `後悔`, `sorry`, `unfortunately` 等 |
| `angry` | `ふざけ`, `ありえない`, `許せ`, `怒り`, `ダメ`, `むかつく`, `イライラ`, `最悪`, `ひどい`, `不満`, `激おこ`, `キレ`, `angry` 等 |
| `surprised` | `マジ`, `えっ`, `びっくり`, `すごい`, `驚`, `まさか`, `嘘`, `信じられない`, `ヤバい`, `衝撃`, `予想外`, `unexpected`, `amazing`, `wow` 等 |
| `thinking` | `調べ`, `確認`, `検討`, `ちょっと待`, `調査`, `考え中`, `悩む`, `迷う`, `うーん`, `分析`, `チェック`, `模索`, `考察` 等 |
| `concerned` | `心配`, `気をつけ`, `注意`, `問題`, `エラー`, `不安`, `危険`, `リスク`, `障害`, `バグ`, `異常`, `懸念`, `error`, `warning`, `critical` 等 |
| `satisfied` | `完了`, `成功`, `できた`, `達成`, `終了`, `解決`, `対応済`, `バッチリ`, `上手くいった`, `問題なし`, `大丈夫`, `done`, `fixed`, `solved` 等 |
| (マッチなし) | `neutral` |

**複数カテゴリマッチ時の判定ルール:** テキスト中で最後（最も右側）に出現したキーワードの感情を採用する。これにより、文末の感情が優先される。

---

## 4. 統合会話ビュー設計

### 4.1 タブUI構造

既存の `openclaw.js` にタブ切り替えを追加:

```
┌──────────────────────────────────────────────────────┐
│  [モニタリング]  |  [会話ログ]                         │
├──────────────────────────────────────────────────────┤
│  （選択中タブの内容が表示される）                       │
└──────────────────────────────────────────────────────┘
```

タブUIは既存の `.tabs` / `.tab` / `.tab.active` CSSクラスをそのまま利用する。

### 4.2 会話タイムライン

メッセージカードのレイアウト:

```
┌─────────────────────────────────────────────────────────┐
│ ┌─[LINE]─────────────────────────────────── 14:32 ──┐  │
│ │ masaru (受信)                                      │  │
│ │ 今日の天気はどう？                                  │  │
│ └────────────────────────────────────────────────────┘  │
│                                                         │
│ ┌─[LINE]───────────────── 😊 happy ──── 14:32 ──┐      │
│ │ openclaw (送信)                                │      │
│ │ 東京は晴れで最高気温15℃の予報です！            │      │
│ └────────────────────────────────────────────────┘      │
│                                                         │
│ ┌─[Discord]──────────────────────────── 14:35 ──┐      │
│ │ user#1234 (受信)                               │      │
│ │ サーバーの状況教えて                            │      │
│ └────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────┘
```

メッセージカードの構成:
- **プラットフォームバッジ**: `[LINE]` or `[Discord]`（色分け）
- **方向インジケーター**: 受信 = 左寄せ薄色背景、送信 = 右寄せアクセント背景
- **感情バッジ**: outboundメッセージのみ表示（`emotion_hint` があれば）
- **タイムスタンプ**: 右上に表示

### 4.3 プラットフォームバッジの色

```css
.badge-line {
  background: rgba(6, 199, 85, 0.15);
  color: #06c755;
  border: 1px solid rgba(6, 199, 85, 0.3);
}
.badge-discord {
  background: rgba(88, 101, 242, 0.15);
  color: #5865f2;
  border: 1px solid rgba(88, 101, 242, 0.3);
}
```

### 4.4 フィルタバー

```
┌─────────────────────────────────────────────────────┐
│ Platform: [All] [LINE] [Discord]                    │
│ Direction: [All] [受信] [送信]                       │
│ Search: [________________] 🔍                        │
└─────────────────────────────────────────────────────┘
```

- フィルタはクライアント側でフェッチ済みデータに適用
- テキスト検索は `content` フィールドに対する部分一致

### 4.5 ページネーション

- 初回ロード: 最新100件を取得
- 「さらに読み込む」ボタンで過去ログを追加取得
- APIパラメータ: `before=<timestamp>` で指定タイムスタンプより前のメッセージを取得
- 1リクエストあたり最大100件

---

## 5. API拡張設計

### 5.1 新規エンドポイント

#### `GET /api/openclaw/conversations`

会話ログの取得。

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `platform` | `line` \| `discord` | (all) | プラットフォームフィルタ |
| `limit` | number | `100` | 取得件数（最大100） |
| `before` | ISO 8601 timestamp | (none) | このタイムスタンプより前のメッセージを取得 |

**Response:**

```json
{
  "messages": [
    {
      "timestamp": "2026-02-15T06:30:00Z",
      "platform": "line",
      "channel": "group_abc123",
      "user": "masaru",
      "direction": "inbound",
      "content": "今日の天気はどう？",
      "emotion_hint": null
    }
  ],
  "has_more": true,
  "oldest_timestamp": "2026-02-15T00:00:00Z"
}
```

**実装方針（`api-openclaw.js` に追加）:**

```javascript
router.get('/openclaw/conversations', async (req, res) => {
  const platform = req.query.platform;  // "line" | "discord" | undefined
  const limit = Math.min(parseInt(req.query.limit || '100', 10), 100);
  const before = req.query.before || null;

  const convDir = path.join(sharedDir, 'openclaw', 'conversations');
  const platforms = platform ? [platform] : ['line', 'discord'];
  let allMessages = [];

  for (const p of platforms) {
    const filePath = path.join(convDir, `${p}.jsonl`);
    const content = await tailFile(filePath, 500);  // 直近500行を読む
    const msgs = content.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean);
    allMessages.push(...msgs);
  }

  // timestamp降順ソート
  allMessages.sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || ''));

  // beforeフィルタ
  if (before) {
    allMessages = allMessages.filter(m => m.timestamp < before);
  }

  const limited = allMessages.slice(0, limit);
  res.json({
    messages: limited,
    has_more: allMessages.length > limit,
    oldest_timestamp: limited.length > 0 ? limited[limited.length - 1].timestamp : null
  });
});
```

#### `GET /api/openclaw/emotion-state`

現在の感情状態を取得。

**Response:**

```json
{
  "emotion": "thinking",
  "source": "emotion_hint",
  "last_message_at": "2026-02-15T06:30:00Z"
}
```

`monitor_status` フィールドは廃止（システム状態と感情の分離のため）。

**感情決定ロジック（優先度順）:**

1. 直近5分以内のoutboundメッセージに `emotion_hint` がある → その値（source: `emotion_hint`）
2. 直近5分以内のoutboundメッセージにキーワードマッチング → 推定感情（source: `keyword_fallback`）
3. いずれも該当しない → `neutral`（source: `default`）

### 5.2 SSEイベント追加

`file-watcher.js` の `classifyEvent()` に以下を追加:

```javascript
if (relativePath.startsWith('openclaw/conversations/')) return 'conversation:updated';
```

`app.js` のSSEハンドラに以下を追加:

```javascript
// OpenClaw page: real-time conversation + emotion updates
(hash.startsWith('/openclaw') && (data.type === 'conversation:updated'))
```

`conversation:updated` イベント受信時のフロントエンド処理:
1. 現在「会話ログ」タブが表示中なら、新着メッセージをタイムラインの先頭に追加
2. アバターの感情状態を `/api/openclaw/emotion-state` から再取得

**Note**: `emotion:changed` 専用イベントは不要。`conversation:updated` をトリガーにして感情APIを叩けば十分。

---

## 6. 画面レイアウト（ワイヤーフレーム）

### 6.1 全体レイアウト

```
┌──────────────────────────────────────────────────────────────┐
│                    OpenClaw Monitor                          │
│  [healthy] ●                                                 │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Avatar Section                              │ │
│  │                                                          │ │
│  │    ┌──────┐                                              │ │
│  │    │ ◉  ◉ │   "考え中..."                                │ │
│  │    │  ⌣  │   Last active: 2m ago                        │ │
│  │    └──────┘   ● ● ● (pulse)                             │ │
│  │                                                          │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌──────────────┬───────────────┐                            │
│  │ モニタリング  │  会話ログ      │   ← タブ                  │
│  └──────────────┴───────────────┘                            │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                                                          │ │
│  │  （選択中タブのコンテンツ）                                │ │
│  │                                                          │ │
│  │  [モニタリング tab]                                       │ │
│  │    = 既存のOpenClawモニターダッシュボード                  │ │
│  │    (stats, alerts, pending actions, research requests)    │ │
│  │                                                          │ │
│  │  [会話ログ tab]                                           │ │
│  │    = フィルタバー + 会話タイムライン                       │ │
│  │                                                          │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 6.2 アバターセクション詳細

```
┌───────────────────────────────────────────────────────────┐
│  card (bg-card, border, border-radius-lg)                 │
│                                                           │
│  ┌────────┐   STATUS TEXT          METADATA               │
│  │        │   ────────────         ─────────              │
│  │  FACE  │   感情ラベル            Last: 2m ago          │
│  │  SVG   │   (e.g. "考え中...")    Platform: LINE        │
│  │  80px  │                        Messages today: 42     │
│  │        │   ● ● ●                                      │
│  └────────┘   pulse dots                                  │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

- 左側: SVGアバター（80x80px）
- 中央: 感情ラベル + パルスインジケーター
- 右側: メタデータ（最終アクティブ時間、本日のメッセージ数等）

### 6.3 会話タイムライン詳細

```
┌───────────────────────────────────────────────────────────┐
│  Filter Bar                                               │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ [All] [LINE] [Discord]   [All] [受信] [送信]         │ │
│  │ [_______________search_______________] 🔍             │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                           │
│  Message Cards (time-descending)                          │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ [LINE]  masaru  (受信)                    14:35      │ │
│  │ ──────────────────────────────────────────           │ │
│  │ ありがとう！                                          │ │
│  └──────────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ [LINE]  openclaw  (送信)  😊 happy        14:32      │ │
│  │ ──────────────────────────────────────────           │ │
│  │ 東京は晴れで最高気温15℃の予報です！                   │ │
│  └──────────────────────────────────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────┐ │
│  │ [Discord]  user#1234  (受信)              14:30      │ │
│  │ ──────────────────────────────────────────           │ │
│  │ サーバーの状況教えて                                   │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                           │
│             [ さらに読み込む ]                              │
└───────────────────────────────────────────────────────────┘
```

### 6.4 メッセージカードのCSS設計

```css
/* 会話メッセージカード */
.conv-message {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 10px 14px;
  margin-bottom: 6px;
}
.conv-message.outbound {
  border-left: 3px solid var(--accent);
  background: rgba(96, 165, 250, 0.05);
}
.conv-message.inbound {
  border-left: 3px solid var(--text-dim);
}
.conv-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 4px;
  font-size: 12px;
}
.conv-user {
  font-weight: 600;
  color: var(--text-primary);
}
.conv-direction {
  font-size: 11px;
  color: var(--text-dim);
}
.conv-time {
  margin-left: auto;
  color: var(--text-dim);
  font-size: 11px;
  font-family: var(--font-mono);
}
.conv-body {
  font-size: 13px;
  color: var(--text-secondary);
  line-height: 1.6;
  white-space: pre-wrap;
}
.conv-emotion {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  padding: 1px 6px;
  border-radius: 4px;
  background: rgba(52, 211, 153, 0.1);
  color: var(--success);
}
```

---

## 7. コンポーネント構成図

### 7.1 ファイル構成

```
/soul/web-ui/
├── public/
│   ├── css/style.css              # アバター・会話カード用CSS追加
│   └── js/
│       ├── views/
│       │   └── openclaw.js        # 既存ファイルを拡張（タブ追加、アバター統合）
│       └── components/
│           └── openclaw-avatar.js  # 新規: アバターSVG生成コンポーネント
├── routes/
│   └── api-openclaw.js            # 既存ファイルに conversations, emotion-state 追加
└── lib/
    └── file-watcher.js            # classifyEvent() に conversation 追加
```

### 7.2 コンポーネント責務

| Component | File | Export | Description |
|-----------|------|--------|-------------|
| Avatar | `openclaw-avatar.js` | `renderAvatar(emotion)` | SVGアバターのHTML文字列を返す |
| Avatar | `openclaw-avatar.js` | `getEmotionLabel(emotion)` | 感情状態の日本語ラベルを返す |
| OpenClaw View | `openclaw.js` | `renderOpenClaw(app)` | 既存のexportを維持。タブ制御を追加 |

### 7.3 状態管理

グローバルステートは使用しない。ビュー内のモジュールスコープ変数で管理:

```javascript
// openclaw.js 内
let currentTab = 'monitoring';  // 'monitoring' | 'conversations'
let currentEmotion = 'idle';
let conversationFilter = { platform: 'all', direction: 'all', search: '' };
let loadedMessages = [];
let oldestTimestamp = null;
```

---

## 8. データフロー図

### 8.1 会話データフロー

```mermaid
sequenceDiagram
    participant User as User (LINE/Discord)
    participant Worker as OpenClaw Worker
    participant JSONL as /shared/openclaw/conversations/*.jsonl
    participant Watcher as file-watcher.js (chokidar)
    participant SSE as SSE Server
    participant Browser as Web UI (Browser)
    participant API as API Server

    User->>Worker: メッセージ送信
    Worker->>Worker: Claude APIで応答生成 (emotion_hint付き)
    Worker->>User: 応答返信
    Worker->>JSONL: inbound + outbound をJSONL追記
    JSONL->>Watcher: ファイル変更検知
    Watcher->>SSE: conversation:updated イベント発行
    SSE->>Browser: SSE push
    Browser->>API: GET /api/openclaw/emotion-state
    API->>JSONL: 直近outbound読み取り
    API->>Browser: { emotion: "happy", ... }
    Browser->>Browser: アバター感情更新
    Browser->>API: GET /api/openclaw/conversations?limit=10
    API->>JSONL: 直近メッセージ読み取り
    API->>Browser: { messages: [...], has_more: true }
    Browser->>Browser: タイムラインに新着追加
```

### 8.2 感情状態決定フロー

```mermaid
flowchart TD
    A[conversation:updated SSE受信] --> B[GET /api/openclaw/emotion-state]
    B --> C{直近5分以内の outbound あり?}
    C -->|Yes| D{emotion_hint あり?}
    C -->|No| E{monitoring status = error?}
    D -->|Yes| F[emotion_hint を使用]
    D -->|No| G[キーワードマッチング]
    E -->|Yes| H[emotion = error]
    E -->|No| I[emotion = idle]
    G --> J{マッチあり?}
    J -->|Yes| K[推定感情を使用]
    J -->|No| L[emotion = neutral]
    F --> M[アバター更新]
    K --> M
    H --> M
    I --> M
    L --> M
```

---

## 9. 実装スコープと対象ファイル

### 変更対象ファイル

| File | Change Type | Description |
|------|-------------|-------------|
| `web-ui/public/css/style.css` | Append | アバター、会話カード、プラットフォームバッジ用CSS追加 |
| `web-ui/public/js/views/openclaw.js` | Modify | タブUI追加、アバターセクション統合、会話ログビュー実装 |
| `web-ui/public/js/components/openclaw-avatar.js` | New | SVGアバターコンポーネント |
| `web-ui/routes/api-openclaw.js` | Modify | `/conversations`, `/emotion-state` エンドポイント追加 |
| `web-ui/lib/file-watcher.js` | Modify | `classifyEvent()` に `openclaw/conversations/` 追加 |
| `web-ui/public/js/app.js` | Modify | SSEハンドラに `conversation:updated` 追加 |

### 変更不要ファイル

- `server.js` — 既存の `api-openclaw` マウントをそのまま利用
- `nav.js` — 既存の `/openclaw` ルートをそのまま利用
- `shared-reader.js` — 既存の `tailFile` をそのまま利用

### 新規作成ディレクトリ

```bash
mkdir -p /shared/openclaw/conversations/archive
```

---

## 10. モバイル対応

既存の `@media (max-width: 768px)` ブレークポイントに以下を追加:

- アバターサイズ: 80px → 60px
- アバターセクション: 横並び → 縦積み
- フィルタバー: ボタン群を折り返し
- メッセージカード: パディング縮小
- 「さらに読み込む」ボタン: タップ領域拡大

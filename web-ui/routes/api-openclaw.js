const { Router } = require('express');
const path = require('path');
const { readJson, listJsonFiles, listDirs, tailFile } = require('../lib/shared-reader');
const { writeJsonAtomic } = require('../lib/shared-writer');

module.exports = function (sharedDir) {
  const router = Router();
  const monitorDir = path.join(sharedDir, 'monitoring');

  // ===== Unified API Endpoints =====

  // POST /api/openclaw/trigger-check - 手動チェックトリガー
  router.post('/openclaw/trigger-check', async (req, res) => {
    const forceFile = path.join(monitorDir, 'force_check.json');
    const existing = await readJson(forceFile);
    if (existing) {
      return res.status(429).json({ error: 'Check already pending', triggered_at: existing.triggered_at });
    }
    const data = {
      triggered_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      triggered_by: 'dashboard',
      type: 'manual_full_check'
    };
    await writeJsonAtomic(forceFile, data);
    res.json({ status: 'triggered', ...data });
  });

  // GET /api/openclaw/status - Monitor status (reads from /shared/monitoring/latest.json)
  router.get('/openclaw/status', async (req, res) => {
    const unified = await readJson(path.join(monitorDir, 'latest.json'));
    const integrity = await readJson(path.join(monitorDir, 'integrity.json'));

    const state = unified || { status: 'not_started', check_count: 0, monitor_type: 'unified' };

    // Build alert summary from alerts.jsonl
    const alertContent = await tailFile(path.join(monitorDir, 'alerts.jsonl'), 200);
    const allAlerts = alertContent.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean);

    const by_severity = { high: 0, medium: 0, low: 0 };
    const by_category = { policy: 0, security: 0, integrity: 0 };
    for (const a of allAlerts) {
      const sev = (a.severity || 'low').toLowerCase();
      if (sev in by_severity) by_severity[sev]++;
      else by_severity.low++;
      const cat = a.category || 'policy';
      if (cat in by_category) by_category[cat]++;
    }

    res.json({
      state,
      integrity: integrity || { status: 'unknown' },
      summary: {
        total_alerts: allAlerts.length,
        by_severity,
        by_category
      }
    });
  });

  // GET /api/openclaw/alerts - Unified alerts (all categories)
  router.get('/openclaw/alerts', async (req, res) => {
    const limit = parseInt(req.query.limit || '50', 10);
    const category = req.query.category || null; // filter: policy, security, integrity
    const content = await tailFile(path.join(monitorDir, 'alerts.jsonl'), limit * 2);
    let alerts = content.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .reverse();

    if (category) {
      alerts = alerts.filter(a => a.category === category);
    }

    res.json(alerts.slice(0, limit));
  });

  // GET /api/openclaw/integrity - Personality integrity state
  router.get('/openclaw/integrity', async (req, res) => {
    const integrity = await readJson(path.join(monitorDir, 'integrity.json'));
    res.json(integrity || { status: 'unknown', checked_at: null });
  });

  // GET /api/openclaw/reports - Recent monitoring reports
  router.get('/openclaw/reports', async (req, res) => {
    const reportsDir = path.join(monitorDir, 'reports');
    const files = await listJsonFiles(reportsDir);
    const reports = [];
    const sorted = files.sort().reverse().slice(0, 20);
    for (const f of sorted) {
      const report = await readJson(path.join(reportsDir, f));
      if (report) reports.push(report);
    }
    res.json(reports);
  });

  // GET /api/openclaw/remediation - Remediation log
  router.get('/openclaw/remediation', async (req, res) => {
    const limit = parseInt(req.query.limit || '50', 10);
    const content = await tailFile(path.join(monitorDir, 'remediation.jsonl'), limit);
    const entries = (content || '').split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .reverse();
    res.json(entries);
  });

  // GET /api/openclaw/pending-actions - Pending actions
  router.get('/openclaw/pending-actions', async (req, res) => {
    const actions = [];
    const pendingDir = path.join(monitorDir, 'pending_actions');
    const files = await listJsonFiles(pendingDir);
    for (const f of files) {
      const action = await readJson(path.join(pendingDir, f));
      if (action) actions.push(action);
    }
    actions.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    res.json(actions);
  });

  // POST /api/openclaw/pending-actions/:id/approve - Approve a pending action
  router.post('/openclaw/pending-actions/:id/approve', async (req, res) => {
    const actionId = req.params.id;
    const actionFile = path.join(monitorDir, 'pending_actions', `${actionId}.json`);
    const action = await readJson(actionFile);
    if (!action) {
      return res.status(404).json({ error: 'Action not found' });
    }
    if (action.status !== 'pending') {
      return res.status(400).json({ error: `Action already ${action.status}` });
    }
    action.status = 'approved';
    action.approved_by = 'dashboard';
    action.approved_at = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    await writeJsonAtomic(actionFile, action);
    res.json(action);
  });

  // POST /api/openclaw/pending-actions/:id/reject - Reject a pending action
  router.post('/openclaw/pending-actions/:id/reject', async (req, res) => {
    const actionId = req.params.id;
    const actionFile = path.join(monitorDir, 'pending_actions', `${actionId}.json`);
    const action = await readJson(actionFile);
    if (!action) {
      return res.status(404).json({ error: 'Action not found' });
    }
    action.status = 'rejected';
    action.rejected_at = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    await writeJsonAtomic(actionFile, action);
    res.json(action);
  });

  // GET /api/openclaw/notifications - Unread notifications
  router.get('/openclaw/notifications', async (req, res) => {
    const notifDir = path.join(buddyDir, 'notifications');
    const files = await listJsonFiles(notifDir);
    const notifications = [];
    for (const f of files) {
      const notif = await readJson(path.join(notifDir, f));
      if (notif) notifications.push(notif);
    }
    notifications.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    res.json(notifications);
  });

  // ===== Research Requests =====

  // GET /api/openclaw/research-requests - List OpenClaw research requests
  // Scans inbox, discussions, and decisions for [OpenClaw Research] tasks
  router.get('/openclaw/research-requests', async (req, res) => {
    const requests = [];
    const inboxDir = path.join(sharedDir, 'inbox');
    const decisionsDir = path.join(sharedDir, 'decisions');
    const discussionsDir = path.join(sharedDir, 'discussions');
    const archiveDir = path.join(sharedDir, 'archive');

    const PREFIX = '[OpenClaw Research]';

    // Helper to determine phase of a task
    async function getTaskPhase(taskId) {
      // Check decisions first (most progressed)
      const resultFile = path.join(decisionsDir, `${taskId}_result.json`);
      const decisionFile = path.join(decisionsDir, `${taskId}.json`);
      const result = await readJson(resultFile);
      if (result) return { phase: 'completed', result };
      const decision = await readJson(decisionFile);
      if (decision) return { phase: 'decided', decision };

      // Check discussions
      const statusFile = path.join(discussionsDir, taskId, 'status.json');
      const status = await readJson(statusFile);
      if (status) return { phase: 'discussing', discussion_status: status };

      // Check archive
      const archiveTaskDir = path.join(archiveDir, taskId);
      const archiveDecision = await readJson(path.join(archiveTaskDir, `${taskId}.json`));
      if (archiveDecision) return { phase: 'archived', decision: archiveDecision };

      return { phase: 'inbox' };
    }

    // Scan inbox for pending research requests
    const inboxFiles = await listJsonFiles(inboxDir);
    for (const f of inboxFiles) {
      const task = await readJson(path.join(inboxDir, f));
      if (!task || !task.title || !task.title.startsWith(PREFIX)) continue;
      const phaseInfo = await getTaskPhase(task.id);
      requests.push({ ...task, ...phaseInfo });
    }

    // Scan decisions for completed/decided research requests
    const decisionFiles = await listJsonFiles(decisionsDir);
    const seenIds = new Set(requests.map(r => r.id));
    for (const f of decisionFiles) {
      if (f.endsWith('_result.json') || f.endsWith('_progress.jsonl') ||
          f.endsWith('_history.json') || f.endsWith('_announce_progress.jsonl')) continue;
      const decision = await readJson(path.join(decisionsDir, f));
      if (!decision || !decision.title || !decision.title.startsWith(PREFIX)) continue;
      const taskId = decision.task_id || f.replace('.json', '');
      if (seenIds.has(taskId)) continue;
      seenIds.add(taskId);
      const resultFile = path.join(decisionsDir, `${taskId}_result.json`);
      const result = await readJson(resultFile);
      requests.push({
        id: taskId,
        title: decision.title,
        description: decision.description || '',
        priority: decision.priority || 'low',
        source: 'openclaw',
        request_type: decision.request_type || 'research',
        created_at: decision.created_at || '',
        phase: result ? 'completed' : 'decided',
        decision,
        result: result || undefined
      });
    }

    // Scan archive
    const archiveDirs = await listDirs(archiveDir);
    for (const dirName of archiveDirs) {
      if (seenIds.has(dirName)) continue;
      const archiveDecision = await readJson(path.join(archiveDir, dirName, `${dirName}.json`));
      if (!archiveDecision || !archiveDecision.title || !archiveDecision.title.startsWith(PREFIX)) continue;
      seenIds.add(dirName);
      const archiveResult = await readJson(path.join(archiveDir, dirName, `${dirName}_result.json`));
      requests.push({
        id: dirName,
        title: archiveDecision.title,
        description: archiveDecision.description || '',
        priority: archiveDecision.priority || 'low',
        source: 'openclaw',
        request_type: archiveDecision.request_type || 'research',
        created_at: archiveDecision.created_at || '',
        phase: 'archived',
        decision: archiveDecision,
        result: archiveResult || undefined
      });
    }

    // Sort by created_at descending
    requests.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    res.json(requests);
  });

  // ===== Legacy Endpoints (kept during parallel operation period) =====

  // GET /api/openclaw/panda-status - Legacy: redirects to unified status
  router.get('/openclaw/panda-status', async (req, res) => {
    const latest = await readJson(path.join(monitorDir, 'latest.json'));
    res.json(latest || { status: 'not_started', check_count: 0 });
  });

  // GET /api/openclaw/panda-alerts - Legacy: redirects to unified alerts
  router.get('/openclaw/panda-alerts', async (req, res) => {
    const limit = parseInt(req.query.limit || '50', 10);
    const content = await tailFile(path.join(monitorDir, 'alerts.jsonl'), limit);
    const alerts = content.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .reverse();
    res.json(alerts);
  });

  // GET /api/openclaw/panda-reports - Legacy: redirects to reports
  router.get('/openclaw/panda-reports', async (req, res) => {
    const reportsDir = path.join(monitorDir, 'reports');
    const files = await listJsonFiles(reportsDir);
    const reports = [];
    const sorted = files.sort().reverse().slice(0, 20);
    for (const f of sorted) {
      const report = await readJson(path.join(reportsDir, f));
      if (report) reports.push(report);
    }
    res.json(reports);
  });

  // ===== Conversation Log Endpoints =====

  // GET /api/openclaw/conversations - 会話ログ取得
  router.get('/openclaw/conversations', async (req, res) => {
    const platform = req.query.platform; // "line" | "discord" | undefined
    const limit = Math.min(parseInt(req.query.limit || '100', 10), 100);
    const before = req.query.before || null;

    const convDir = path.join(sharedDir, 'openclaw', 'conversations');
    const platforms = platform ? [platform] : ['line', 'discord'];
    let allMessages = [];

    for (const p of platforms) {
      const filePath = path.join(convDir, `${p}.jsonl`);
      const content = await tailFile(filePath, 500);
      if (!content) continue;
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

  // GET /api/openclaw/emotion-state - 現在の感情状態取得
  router.get('/openclaw/emotion-state', async (req, res) => {
    const convDir = path.join(sharedDir, 'openclaw', 'conversations');

    // 各プラットフォームの直近outboundメッセージを探す
    let latestOutbound = null;
    for (const p of ['line', 'discord']) {
      const content = await tailFile(path.join(convDir, `${p}.jsonl`), 20);
      if (!content) continue;
      const msgs = content.split('\n')
        .filter(l => l.trim())
        .map(l => { try { return JSON.parse(l); } catch { return null; } })
        .filter(m => m && m.direction === 'outbound');
      for (const m of msgs) {
        if (!latestOutbound || m.timestamp > latestOutbound.timestamp) {
          latestOutbound = m;
        }
      }
    }

    let emotion = 'neutral';
    let source = 'default';
    const fiveMinAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();

    if (latestOutbound && latestOutbound.timestamp > fiveMinAgo && latestOutbound.emotion_hint) {
      emotion = latestOutbound.emotion_hint;
      source = 'emotion_hint';
    } else if (latestOutbound && latestOutbound.timestamp > fiveMinAgo) {
      emotion = estimateEmotion(latestOutbound.content);
      source = 'keyword_fallback';
    }

    res.json({
      emotion,
      source,
      last_message_at: latestOutbound ? latestOutbound.timestamp : null
    });
  });

  // GET /api/openclaw/emotion-distribution - 直近48時間の感情分布
  router.get('/openclaw/emotion-distribution', async (req, res) => {
    const hours = Math.min(parseInt(req.query.hours || '48', 10), 168);
    const cutoff = new Date(Date.now() - hours * 60 * 60 * 1000).toISOString();
    const convDir = path.join(sharedDir, 'openclaw', 'conversations');

    const counts = {};
    for (const p of ['line', 'discord']) {
      const content = await tailFile(path.join(convDir, `${p}.jsonl`), 2000);
      if (!content) continue;
      const msgs = content.split('\n')
        .filter(l => l.trim())
        .map(l => { try { return JSON.parse(l); } catch { return null; } })
        .filter(m => m && m.direction === 'outbound' && m.timestamp >= cutoff);
      for (const m of msgs) {
        const emotion = m.emotion_hint || 'neutral';
        counts[emotion] = (counts[emotion] || 0) + 1;
      }
    }

    res.json({ hours, counts, total: Object.values(counts).reduce((a, b) => a + b, 0) });
  });

  return router;
};

// キーワードベースの感情推定（最後にマッチしたキーワードの感情を優先）
function estimateEmotion(content) {
  if (!content) return 'neutral';
  const lower = content.toLowerCase();

  const patterns = [
    { emotion: 'happy', keywords: [
      '嬉しい', '楽しい', 'ありがとう', 'おめでとう', 'ナイス', 'ええやん',
      'やった', '最高', '幸せ', '素敵', 'いいね', 'よかった', '良かった',
      'ハッピー', '面白い', 'ウケる', '感謝', 'サンキュー',
      '素晴らしい', '見事', '上手い', '完璧', 'わーい', 'よっしゃ',
      'ラッキー', 'いい感じ', 'good', 'great', 'awesome', 'nice',
      'cool', 'excellent', 'wonderful', 'happy', 'love', 'thanks', 'thx',
    ]},
    { emotion: 'sad', keywords: [
      '悲しい', '残念', 'つらい', '辛い', '寂しい', '切ない', '申し訳',
      'ごめん', 'ごめんなさい', 'すまん', 'すみません',
      '泣き', '涙', '落ち込', 'しょんぼり', 'がっかり', 'ショック',
      '失望', '惜しい', '虚しい', '空しい', '後悔', '不幸', '無念',
      'しゃーない', '仕方ない', 'sorry', 'unfortunately', 'disappointed',
    ]},
    { emotion: 'angry', keywords: [
      'ふざけ', 'ありえない', 'ありえへん', '許せ', '怒り', '怒る',
      'ダメ', 'むかつく', 'イライラ', '腹立', 'うざい', 'いい加減に',
      '最悪', 'ひどい', '酷い', 'なめんな', '舐めんな', '黙れ',
      'うるさい', '勘弁', '邪魔', '迷惑', '不満', '文句',
      '激おこ', 'キレ', 'ブチ切れ', '頭にくる', '腹が立つ',
      '不快', '気に入らない', 'angry',
    ]},
    { emotion: 'surprised', keywords: [
      'マジ', 'まじ', 'えっ', 'びっくり', 'すごい', '驚', 'まさか',
      'うそ', '嘘', 'ほんまに', '本当に', '信じられない',
      'ヤバい', 'やばい', '衝撃', 'まじか', 'おお', 'わお',
      '想定外', '予想外', '意外', 'たまげた', '仰天',
      '半端ない', 'とんでもない', 'unexpected', 'amazing', 'wow',
      'incredible', 'unbelievable', 'omg',
    ]},
    { emotion: 'thinking', keywords: [
      '調べ', '確認', '検討', 'ちょっと待', '調査',
      '考え中', '思案', '悩んで', '悩む', '迷って', '迷う',
      'うーん', 'んー', 'どうしよう', '検索', '分析',
      'リサーチ', '見てみる', 'チェック', '精査', '模索',
      '考察', '見極め', '比較', '試して',
    ]},
    { emotion: 'concerned', keywords: [
      '心配', '気をつけ', '注意', 'まずい', '問題', 'エラー',
      '不安', '危険', '危ない', 'リスク', '警告', '障害',
      '故障', 'バグ', '異常', '不具合', 'おかしい', '気がかり',
      '懸念', '用心', '慎重', '困った', 'トラブル', '深刻', '重大',
      '怖い', '恐い',
      'error', 'exception', 'timeout', 'warning', 'bug', 'trouble',
      'issue', 'critical', 'failure', 'fault',
    ]},
    { emotion: 'satisfied', keywords: [
      '完了', '成功', 'できた', 'できました',
      '達成', '終了', '終わった', '終わり', '片付いた', '解決',
      '対応済', '修正済', '反映済', 'やり遂げ', '仕上がった',
      'クリア', 'バッチリ', 'ばっちり', '上手くいった', 'うまくいった',
      '問題なし', '問題ない', '大丈夫',
      'done', 'ok', 'solved', 'fixed', 'deployed', 'finished',
      'complete', 'completed', 'passed',
    ]},
  ];

  let lastPos = -1;
  let result = 'neutral';
  for (const p of patterns) {
    for (const kw of p.keywords) {
      const pos = lower.lastIndexOf(kw);
      if (pos > lastPos) {
        lastPos = pos;
        result = p.emotion;
      }
    }
  }
  return result;
}

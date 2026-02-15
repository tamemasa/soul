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

  return router;
};

// キーワードベースの感情推定
function estimateEmotion(content) {
  if (!content) return 'neutral';
  const text = content.toLowerCase();

  const patterns = [
    { keywords: ['完了', '成功', 'done', 'ok'], emotion: 'satisfied' },
    { keywords: ['ありがとう', 'thanks', '嬉しい'], emotion: 'happy' },
    { keywords: ['調査', '確認中', '検討', '...'], emotion: 'thinking' },
    { keywords: ['申し訳', 'エラー', '失敗', 'sorry', 'error', 'exception', 'timeout'], emotion: 'concerned' },
    { keywords: ['マジ', 'えっ', 'びっくり', 'すごい', '驚'], emotion: 'surprised' },
    { keywords: ['残念', '悲しい', 'つらい', 'ごめん'], emotion: 'sad' },
    { keywords: ['ふざけ', 'ありえない', '許せ', '怒', 'ダメ'], emotion: 'angry' }
  ];

  const matches = [];
  for (const p of patterns) {
    if (p.keywords.some(kw => text.includes(kw))) {
      matches.push(p.emotion);
    }
  }

  if (matches.length === 1) return matches[0];
  return 'neutral';
}

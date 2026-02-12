const { Router } = require('express');
const path = require('path');
const { readJson, listJsonFiles, tailFile } = require('../lib/shared-reader');
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

  return router;
};

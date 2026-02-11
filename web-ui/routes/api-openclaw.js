const { Router } = require('express');
const path = require('path');
const { readJson, listJsonFiles, tailFile } = require('../lib/shared-reader');
const { writeJsonAtomic } = require('../lib/shared-writer');

module.exports = function (sharedDir) {
  const router = Router();
  const monitorDir = path.join(sharedDir, 'openclaw', 'monitor');

  // GET /api/openclaw/status - Monitor status overview
  router.get('/openclaw/status', async (req, res) => {
    const state = await readJson(path.join(monitorDir, 'state.json'));
    const summary = await readJson(path.join(monitorDir, 'summary.json'));

    res.json({
      state: state || { status: 'not_started', check_count: 0 },
      summary: summary || { total_alerts: 0, by_severity: { high: 0, medium: 0, low: 0 }, unacknowledged: 0 }
    });
  });

  // GET /api/openclaw/alerts - Recent alerts
  router.get('/openclaw/alerts', async (req, res) => {
    const limit = parseInt(req.query.limit || '50', 10);
    const content = await tailFile(path.join(monitorDir, 'alerts.jsonl'), limit);
    const alerts = content.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .reverse();
    res.json(alerts);
  });

  // GET /api/openclaw/remediation - Remediation log
  router.get('/openclaw/remediation', async (req, res) => {
    const limit = parseInt(req.query.limit || '50', 10);
    const content = await tailFile(path.join(monitorDir, 'remediation.jsonl'), limit);
    const entries = content.split('\n')
      .filter(l => l.trim())
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .reverse();
    res.json(entries);
  });

  // GET /api/openclaw/pending-actions - Pending remediation actions
  router.get('/openclaw/pending-actions', async (req, res) => {
    const actionsDir = path.join(monitorDir, 'pending_actions');
    const files = await listJsonFiles(actionsDir);
    const actions = [];
    for (const f of files) {
      const action = await readJson(path.join(actionsDir, f));
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
    const notifDir = path.join(monitorDir, 'notifications');
    const files = await listJsonFiles(notifDir);
    const notifications = [];
    for (const f of files) {
      const notif = await readJson(path.join(notifDir, f));
      if (notif) notifications.push(notif);
    }
    notifications.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    res.json(notifications);
  });

  return router;
};

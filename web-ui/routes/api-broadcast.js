const { Router } = require('express');
const path = require('path');
const { readJson, listJsonFiles } = require('../lib/shared-reader');
const { writeJsonAtomic } = require('../lib/shared-writer');

module.exports = function (sharedDir) {
  const router = Router();
  const proactiveDir = path.join(sharedDir, 'workspace', 'proactive-suggestions');

  // POST /api/broadcast/trigger - Manual broadcast trigger
  router.post('/broadcast/trigger', async (req, res) => {
    const forceFile = path.join(proactiveDir, 'force_trigger.json');
    const existing = await readJson(forceFile);
    if (existing) {
      return res.status(429).json({ error: 'Trigger already pending', triggered_at: existing.triggered_at });
    }
    const data = {
      trigger: 'trending_news',
      triggered_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      triggered_by: 'dashboard'
    };
    await writeJsonAtomic(forceFile, data);
    res.json({ status: 'triggered', ...data });
  });

  // GET /api/broadcast/status - Broadcast engine status
  router.get('/broadcast/status', async (req, res) => {
    const broadcastState = await readJson(path.join(proactiveDir, 'state', 'broadcast.json'));
    const engineState = await readJson(path.join(proactiveDir, 'state', 'engine.json'));
    const config = await readJson(path.join(proactiveDir, 'config.json'));

    const mode = config ? config.mode : 'unknown';
    const triggerConfig = config && config.triggers ? config.triggers.trending_news : null;

    res.json({
      broadcast: broadcastState || { status: 'not_started' },
      engine: {
        status: engineState ? engineState.status : 'unknown',
        mode: mode,
        last_check_at: engineState ? engineState.last_check_at : null,
        daily_counts: engineState ? engineState.daily_counts : null
      },
      trigger: triggerConfig ? {
        destinations: (triggerConfig.destinations || []).map(d => d.type)
      } : null
    });
  });

  // GET /api/broadcast/history - Recent broadcast records
  router.get('/broadcast/history', async (req, res) => {
    const broadcastDir = path.join(proactiveDir, 'broadcasts');
    const files = await listJsonFiles(broadcastDir);
    const records = [];
    const sorted = files.sort().reverse().slice(0, 20);
    for (const f of sorted) {
      const record = await readJson(path.join(broadcastDir, f));
      if (record) records.push(record);
    }
    res.json(records);
  });

  return router;
};

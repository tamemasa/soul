const { Router } = require('express');
const path = require('path');
const { listDirs, readJson, listJsonFiles } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();
  const discDir = path.join(sharedDir, 'discussions');

  router.get('/discussions', async (req, res) => {
    const dirs = await listDirs(discDir);
    const discussions = [];

    for (const d of dirs) {
      const status = await readJson(path.join(discDir, d, 'status.json'));
      const task = await readJson(path.join(discDir, d, 'task.json'));
      discussions.push({
        task_id: d,
        title: task?.title || '(no title)',
        status: status?.status || 'unknown',
        current_round: status?.current_round || 0,
        started_at: status?.started_at || '',
        decided_at: status?.decided_at || ''
      });
    }

    discussions.sort((a, b) => {
      const order = { discussing: 0, executing: 1, decided: 2 };
      const diff = (order[a.status] ?? 9) - (order[b.status] ?? 9);
      if (diff !== 0) return diff;
      return (b.started_at || '').localeCompare(a.started_at || '');
    });

    res.json(discussions);
  });

  router.get('/discussions/:taskId', async (req, res) => {
    const { taskId } = req.params;
    const dDir = path.join(discDir, taskId);
    const status = await readJson(path.join(dDir, 'status.json'));
    if (!status) return res.status(404).json({ error: 'Discussion not found' });

    const task = await readJson(path.join(dDir, 'task.json'));
    const roundDirs = await listDirs(dDir);
    const rounds = [];

    for (const rd of roundDirs.filter(d => d.startsWith('round_')).sort()) {
      const roundNum = parseInt(rd.replace('round_', ''), 10);
      const files = await listJsonFiles(path.join(dDir, rd));
      const responses = [];
      for (const f of files) {
        const resp = await readJson(path.join(dDir, rd, f));
        if (resp) responses.push(resp);
      }
      responses.sort((a, b) => {
        const order = { panda: 0, gorilla: 1, triceratops: 2 };
        return (order[a.node] ?? 9) - (order[b.node] ?? 9);
      });
      rounds.push({ round: roundNum, responses });
    }

    // Include decision and result if available
    const decision = await readJson(path.join(sharedDir, 'decisions', `${taskId}.json`));
    const result = await readJson(path.join(sharedDir, 'decisions', `${taskId}_result.json`));

    res.json({ task_id: taskId, task, status, rounds, decision, result });
  });

  return router;
};

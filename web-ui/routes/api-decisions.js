const { Router } = require('express');
const path = require('path');
const { listJsonFiles, readJson } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();
  const decDir = path.join(sharedDir, 'decisions');

  router.get('/decisions', async (req, res) => {
    const files = await listJsonFiles(decDir);
    const decisions = [];

    for (const f of files) {
      if (f.endsWith('_result.json') || f.endsWith('_review.json') || f.endsWith('_review_history.json') || f.endsWith('_history.json') || f.endsWith('_progress.jsonl') || f.includes('_progress_') || f.includes('_announce_progress')) continue;
      const dec = await readJson(path.join(decDir, f));
      if (dec) decisions.push(dec);
    }

    decisions.sort((a, b) => (b.decided_at || '').localeCompare(a.decided_at || ''));
    res.json(decisions);
  });

  router.get('/decisions/:taskId', async (req, res) => {
    const { taskId } = req.params;
    const decision = await readJson(path.join(decDir, `${taskId}.json`));
    if (!decision) return res.status(404).json({ error: 'Decision not found' });

    const result = await readJson(path.join(decDir, `${taskId}_result.json`));
    const review = await readJson(path.join(decDir, `${taskId}_review.json`));
    const reviewHistory = await readJson(path.join(decDir, `${taskId}_review_history.json`)) || [];
    res.json({ ...decision, result: result?.result || null, review: review || null, reviewHistory });
  });

  return router;
};

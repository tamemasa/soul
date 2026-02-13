const { Router } = require('express');
const path = require('path');
const { listJsonFiles, readJson } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();
  const piDir = path.join(sharedDir, 'personality_improvement');
  const historyDir = path.join(piDir, 'history');

  // List all personality improvement cycles
  router.get('/personality/history', async (req, res) => {
    const trigger = await readJson(path.join(piDir, 'trigger.json'));
    const files = await listJsonFiles(historyDir);
    const cycles = [];

    for (const f of files) {
      const data = await readJson(path.join(historyDir, f));
      if (!data) continue;
      const id = f.replace('.json', '');
      cycles.push({
        id,
        timestamp: data.timestamp,
        summary: data.summary || '',
        changes_count: (data.changes || []).length,
        files_changed: [...new Set((data.changes || []).map(c => c.file))],
      });
    }

    cycles.sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || ''));
    res.json({ trigger: trigger || null, cycles });
  });

  // Get detail of a specific cycle
  router.get('/personality/history/:id', async (req, res) => {
    const { id } = req.params;
    const history = await readJson(path.join(historyDir, `${id}.json`));
    if (!history) return res.status(404).json({ error: 'Cycle not found' });

    // Find matching answers file (closest timestamp before history)
    const allFiles = await listJsonFiles(piDir);
    const answerFiles = allFiles.filter(f => f.startsWith('answers_'));
    let matchedAnswers = null;
    let matchedPending = null;

    // Sort answer files descending, find the one whose timestamp is closest
    const historyTime = new Date(history.timestamp).getTime();
    let bestDiff = Infinity;

    for (const af of answerFiles) {
      const aData = await readJson(path.join(piDir, af));
      if (!aData) continue;
      const aTime = new Date(aData.processed_at || aData.timestamp).getTime();
      const diff = Math.abs(historyTime - aTime);
      if (diff < bestDiff) {
        bestDiff = diff;
        matchedAnswers = aData;
      }
    }

    // From matched answers, get pending file
    if (matchedAnswers && matchedAnswers.pending_file) {
      matchedPending = await readJson(path.join(piDir, matchedAnswers.pending_file));
    }

    res.json({
      id,
      history,
      answers: matchedAnswers,
      pending: matchedPending,
    });
  });

  return router;
};

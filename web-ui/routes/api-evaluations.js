const { Router } = require('express');
const path = require('path');
const { listDirs, listJsonFiles, readJson } = require('../lib/shared-reader');
const { writeJsonAtomic, utcTimestamp } = require('../lib/shared-writer');

module.exports = function (sharedDir) {
  const router = Router();
  const evalDir = path.join(sharedDir, 'evaluations');

  router.get('/evaluations', async (req, res) => {
    const dirs = await listDirs(evalDir);
    const cycles = [];

    for (const d of dirs) {
      const request = await readJson(path.join(evalDir, d, 'request.json'));
      const result = await readJson(path.join(evalDir, d, 'result.json'));
      cycles.push({
        cycle_id: d,
        status: result?.status || request?.status || 'unknown',
        triggered_at: request?.triggered_at || request?.created_at || '',
        completed_at: result?.completed_at || '',
        retune_targets: result?.retune_targets || []
      });
    }

    cycles.sort((a, b) => (b.triggered_at || '').localeCompare(a.triggered_at || ''));
    res.json(cycles);
  });

  router.get('/evaluations/latest', async (req, res) => {
    const dirs = await listDirs(evalDir);
    if (dirs.length === 0) return res.json(null);

    // Find latest by sorting directory names (they contain timestamps)
    dirs.sort((a, b) => b.localeCompare(a));
    const latestDir = dirs[0];
    const cDir = path.join(evalDir, latestDir);
    const request = await readJson(path.join(cDir, 'request.json'));
    const result = await readJson(path.join(cDir, 'result.json'));
    const files = await listJsonFiles(cDir);
    const evaluations = [];

    for (const f of files) {
      if (f.includes('_evaluates_')) {
        const ev = await readJson(path.join(cDir, f));
        if (ev) evaluations.push(ev);
      }
    }

    // Compute per-target average scores
    const targetScores = {};
    for (const ev of evaluations) {
      if (!targetScores[ev.target]) {
        targetScores[ev.target] = { scores: [], overall: [] };
      }
      if (ev.overall_score != null) targetScores[ev.target].overall.push(ev.overall_score);
      if (ev.scores) {
        targetScores[ev.target].scores.push(ev.scores);
      }
    }

    const summary = {};
    for (const [node, data] of Object.entries(targetScores)) {
      const avgOverall = data.overall.length > 0
        ? data.overall.reduce((a, b) => a + b, 0) / data.overall.length
        : null;
      const avgScores = {};
      if (data.scores.length > 0) {
        const keys = Object.keys(data.scores[0]);
        for (const k of keys) {
          const vals = data.scores.map(s => s[k]).filter(v => v != null);
          avgScores[k] = vals.length > 0 ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
        }
      }
      summary[node] = { overall: avgOverall, scores: avgScores };
    }

    res.json({
      cycle_id: latestDir,
      status: result?.status || request?.status || 'unknown',
      triggered_at: request?.triggered_at || '',
      completed_at: result?.completed_at || '',
      retune_targets: result?.retune_targets || [],
      evaluation_count: evaluations.length,
      summary
    });
  });

  router.get('/evaluations/:cycleId', async (req, res) => {
    const { cycleId } = req.params;
    const cDir = path.join(evalDir, cycleId);
    const request = await readJson(path.join(cDir, 'request.json'));
    if (!request) return res.status(404).json({ error: 'Evaluation not found' });

    const result = await readJson(path.join(cDir, 'result.json'));
    const files = await listJsonFiles(cDir);
    const evaluations = [];
    const retunes = [];

    for (const f of files) {
      if (f.includes('_evaluates_')) {
        const ev = await readJson(path.join(cDir, f));
        if (ev) evaluations.push(ev);
      }
      if (f.startsWith('retune_')) {
        const rt = await readJson(path.join(cDir, f));
        if (rt) retunes.push(rt);
      }
    }

    res.json({ cycle_id: cycleId, request, result, evaluations, retunes });
  });

  router.post('/evaluations', async (req, res) => {
    const cycleId = `eval_manual_${Math.floor(Date.now() / 1000)}`;
    const request = {
      cycle_id: cycleId,
      type: 'manual_evaluation',
      status: 'pending',
      triggered_at: utcTimestamp(),
      triggered_by: 'web-ui'
    };

    await writeJsonAtomic(path.join(evalDir, cycleId, 'request.json'), request);
    res.status(201).json(request);
  });

  return router;
};

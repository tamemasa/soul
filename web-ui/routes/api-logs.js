const { Router } = require('express');
const path = require('path');
const { listDirs, listFiles, tailFile } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();
  const logDir = path.join(sharedDir, 'logs');

  router.get('/logs', async (req, res) => {
    const dates = await listDirs(logDir);
    dates.sort().reverse();
    res.json(dates);
  });

  router.get('/logs/:date', async (req, res) => {
    const { date } = req.params;
    const files = await listFiles(path.join(logDir, date), '.log');
    res.json(files.map(f => f.replace('.log', '')));
  });

  router.get('/logs/:date/:node', async (req, res) => {
    const { date, node } = req.params;
    const lines = parseInt(req.query.lines || '50', 10);
    const content = await tailFile(path.join(logDir, date, `${node}.log`), lines);
    res.json({ node, date, content });
  });

  return router;
};

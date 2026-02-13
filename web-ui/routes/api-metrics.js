const { Router } = require('express');
const path = require('path');
const { readJson } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();

  router.get('/metrics', async (req, res) => {
    const data = await readJson(path.join(sharedDir, 'host_metrics', 'metrics.json'));
    res.json(data || []);
  });

  return router;
};

const { Router } = require('express');
const path = require('path');
const { readJson } = require('../lib/shared-reader');
const { writeJsonAtomic } = require('../lib/shared-writer');

const ALL_NODES = ['panda', 'gorilla', 'triceratops'];

module.exports = function (sharedDir) {
  const router = Router();

  router.get('/nodes', async (req, res) => {
    const colors = { panda: '#3B82F6', gorilla: '#EF4444', triceratops: '#A855F7' };
    const nodes = await Promise.all(ALL_NODES.map(async (name) => {
      const params = await readJson(path.join(sharedDir, 'nodes', name, 'params.json'));
      return { name, color: colors[name], params };
    }));
    res.json(nodes);
  });

  router.get('/nodes/:name/params', async (req, res) => {
    const { name } = req.params;
    if (!ALL_NODES.includes(name)) return res.status(404).json({ error: 'Node not found' });
    const params = await readJson(path.join(sharedDir, 'nodes', name, 'params.json'));
    res.json(params || {});
  });

  router.put('/nodes/:name/params', async (req, res) => {
    const { name } = req.params;
    if (!ALL_NODES.includes(name)) return res.status(404).json({ error: 'Node not found' });

    const paramsFile = path.join(sharedDir, 'nodes', name, 'params.json');
    const current = await readJson(paramsFile) || {};
    const updated = { ...current, ...req.body };

    // Validate: all values should be numbers between 0 and 1
    for (const [key, val] of Object.entries(updated)) {
      if (typeof val !== 'number' || val < 0 || val > 1) {
        return res.status(400).json({ error: `Invalid value for ${key}: must be 0-1` });
      }
    }

    await writeJsonAtomic(paramsFile, updated);
    res.json(updated);
  });

  return router;
};

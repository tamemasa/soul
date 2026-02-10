const { Router } = require('express');
const path = require('path');
const { listJsonFiles, listDirs, readJson } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();

  router.get('/status', async (req, res) => {
    const nodes = ['panda', 'gorilla', 'triceratops'];
    const colors = { panda: '#3B82F6', gorilla: '#EF4444', triceratops: '#A855F7' };

    const nodeList = await Promise.all(nodes.map(async (name) => {
      const params = await readJson(path.join(sharedDir, 'nodes', name, 'params.json'));
      return { name, color: colors[name], params };
    }));

    // Count pending tasks
    const inboxFiles = await listJsonFiles(path.join(sharedDir, 'inbox'));
    const pendingTasks = inboxFiles.length;

    // Count active discussions
    const discDirs = await listDirs(path.join(sharedDir, 'discussions'));
    let activeDiscussions = 0;
    for (const d of discDirs) {
      const status = await readJson(path.join(sharedDir, 'discussions', d, 'status.json'));
      if (status && status.status === 'discussing') activeDiscussions++;
    }

    // Count decisions
    const decFiles = await listJsonFiles(path.join(sharedDir, 'decisions'));
    const totalDecisions = decFiles.filter(f => !f.endsWith('_result.json')).length;

    // Count workers
    const workerDirs = await listDirs(path.join(sharedDir, 'workers'));

    res.json({
      nodes: nodeList,
      counts: {
        pending_tasks: pendingTasks,
        active_discussions: activeDiscussions,
        total_decisions: totalDecisions,
        workers: workerDirs.length
      }
    });
  });

  return router;
};

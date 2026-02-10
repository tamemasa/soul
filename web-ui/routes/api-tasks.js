const { Router } = require('express');
const path = require('path');
const { listJsonFiles, readJson } = require('../lib/shared-reader');
const { writeJsonAtomic, generateTaskId, utcTimestamp } = require('../lib/shared-writer');

module.exports = function (sharedDir) {
  const router = Router();

  router.get('/tasks', async (req, res) => {
    const files = await listJsonFiles(path.join(sharedDir, 'inbox'));
    const tasks = [];
    for (const f of files) {
      const task = await readJson(path.join(sharedDir, 'inbox', f));
      if (task) tasks.push(task);
    }
    tasks.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
    res.json(tasks);
  });

  router.post('/tasks', async (req, res) => {
    const { title, description, type, priority } = req.body;
    if (!title) return res.status(400).json({ error: 'title is required' });

    const taskType = type === 'question' ? 'ask' : 'task';
    const id = generateTaskId(taskType);
    const task = {
      id,
      type: type || 'task',
      title,
      description: description || title,
      priority: priority || 'medium',
      created_at: utcTimestamp(),
      status: 'pending'
    };

    await writeJsonAtomic(path.join(sharedDir, 'inbox', `${id}.json`), task);
    res.status(201).json(task);
  });

  return router;
};

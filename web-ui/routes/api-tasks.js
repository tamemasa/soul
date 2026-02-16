const { Router } = require('express');
const path = require('path');
const fs = require('fs').promises;
const { listJsonFiles, readJson } = require('../lib/shared-reader');
const { writeJsonAtomic, generateTaskId, utcTimestamp } = require('../lib/shared-writer');
const { upload, buildAttachmentMeta } = require('../lib/upload');

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

  router.post('/tasks', (req, res, next) => {
    const ct = req.headers['content-type'] || '';
    if (ct.includes('multipart/form-data')) {
      // Generate task ID before multer runs so storage knows the destination
      const type = req.query.type || 'task';
      const taskType = type === 'question' ? 'ask' : 'task';
      req._pendingTaskId = generateTaskId(taskType);
      upload.array('files', 5)(req, res, (err) => {
        if (err) return res.status(400).json({ error: err.message });
        next();
      });
    } else {
      next();
    }
  }, async (req, res) => {
    // For multipart, fields come as strings in req.body
    const title = req.body.title;
    const description = req.body.description;
    const type = req.body.type;
    const priority = req.body.priority;
    const skipDiscussion = req.body.skip_discussion;

    if (!title) return res.status(400).json({ error: 'title is required' });

    const taskType = type === 'question' ? 'ask' : 'task';
    const id = req._pendingTaskId || generateTaskId(taskType);
    const attachments = buildAttachmentMeta(req.files);

    const task = {
      id,
      type: type || 'task',
      title,
      description: description || title,
      priority: priority || 'medium',
      created_at: utcTimestamp(),
      status: 'pending'
    };
    if (attachments.length > 0) {
      task.attachments = attachments;
    }

    await writeJsonAtomic(path.join(sharedDir, 'inbox', `${id}.json`), task);

    // Handle skip_discussion (string "true" from FormData or boolean true from JSON)
    const shouldSkip = skipDiscussion === true || skipDiscussion === 'true';
    if (shouldSkip) {
      const dDir = path.join(sharedDir, 'discussions', id);
      await fs.mkdir(dDir, { recursive: true });

      await writeJsonAtomic(path.join(dDir, 'status.json'), {
        task_id: id,
        status: 'decided',
        current_round: 0,
        max_rounds: 0,
        started_at: utcTimestamp(),
        decided_at: utcTimestamp(),
        started_by: 'user'
      });

      await writeJsonAtomic(path.join(dDir, 'task.json'), task);

      await writeJsonAtomic(path.join(sharedDir, 'decisions', `${id}.json`), {
        task_id: id,
        decision: 'approved',
        status: 'announced',
        final_round: 0,
        final_approach: `User requested direct execution.\n\nTask: ${description || title}`,
        executor: 'triceratops',
        decided_at: utcTimestamp()
      });
    }

    res.status(201).json(task);
  });

  return router;
};

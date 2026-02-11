const { Router } = require('express');
const path = require('path');
const fs = require('fs').promises;
const { listDirs, readJson, listJsonFiles } = require('../lib/shared-reader');
const { writeJsonAtomic, utcTimestamp } = require('../lib/shared-writer');
const { upload, buildAttachmentMeta } = require('../lib/upload');

async function readProgressFile(filePath) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    if (!raw.trim()) return [];
    const events = [];
    for (const line of raw.trim().split('\n')) {
      try {
        events.push(JSON.parse(line));
      } catch {
        // skip malformed lines (partial writes)
      }
    }
    return events;
  } catch {
    return null;
  }
}

module.exports = function (sharedDir) {
  const router = Router();
  const discDir = path.join(sharedDir, 'discussions');

  router.get('/discussions', async (req, res) => {
    const dirs = await listDirs(discDir);
    const discussions = [];

    for (const d of dirs) {
      const status = await readJson(path.join(discDir, d, 'status.json'));
      const task = await readJson(path.join(discDir, d, 'task.json'));
      // Merge status: status.json is authoritative for "discussing", decision file for terminal states
      const decision = await readJson(path.join(sharedDir, 'decisions', `${d}.json`));
      const result = await readJson(path.join(sharedDir, 'decisions', `${d}_result.json`));
      const discussionStatus = status?.status || 'unknown';
      const effectiveStatus = (discussionStatus === 'discussing' || discussionStatus === 'executing')
        ? discussionStatus
        : (decision?.status || discussionStatus);
      // Map decision statuses for display
      // pending_announcement, announced, executing, completed all come from decision file
      discussions.push({
        task_id: d,
        title: task?.title || '(no title)',
        status: effectiveStatus,
        current_round: status?.current_round || 0,
        started_at: status?.started_at || '',
        decided_at: decision?.decided_at || status?.decided_at || '',
        decision_type: decision?.decision || null,
        executor: decision?.executor || null,
        completed_at: decision?.completed_at || result?.completed_at || null,
        has_result: !!result?.result
      });
    }

    discussions.sort((a, b) => {
      const order = { discussing: 0, pending_announcement: 1, announcing: 1, announced: 2, executing: 3, decided: 4, approved: 5, completed: 6 };
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

    // Include execution history (previous cycles)
    const history = await readJson(path.join(sharedDir, 'decisions', `${taskId}_history.json`)) || [];

    // Include comments
    const comments = await readJson(path.join(dDir, 'comments.json')) || [];

    // Include progress events for executing and completed tasks
    let progress = null;
    let announceProgress = null;
    const effectiveStatus = decision?.status || status?.status;
    if (effectiveStatus === 'executing' || effectiveStatus === 'completed') {
      progress = await readProgressFile(path.join(sharedDir, 'decisions', `${taskId}_progress.jsonl`));
    }
    // Load announce progress: while announcing (live) or when announcement data is empty (fallback)
    const announceFile = path.join(sharedDir, 'decisions', `${taskId}_announce_progress.jsonl`);
    if (effectiveStatus === 'announcing') {
      announceProgress = await readProgressFile(announceFile);
    } else if (decision?.announcement && !decision.announcement.summary) {
      announceProgress = await readProgressFile(announceFile);
    }

    res.json({ task_id: taskId, task, status, rounds, decision, result, comments, progress, announceProgress, history });
  });

  // Progress endpoint for real-time execution monitoring
  router.get('/discussions/:taskId/progress', async (req, res) => {
    const { taskId } = req.params;
    const phase = req.query.phase;

    // If phase=announcement, read announce progress file
    if (phase === 'announcement') {
      const announceFile = path.join(sharedDir, 'decisions', `${taskId}_announce_progress.jsonl`);
      const events = await readProgressFile(announceFile);
      if (!events) return res.status(404).json({ error: 'No announce progress file found' });
      return res.json({ task_id: taskId, phase: 'announcement', events });
    }

    const progressFile = path.join(sharedDir, 'decisions', `${taskId}_progress.jsonl`);
    const events = await readProgressFile(progressFile);
    if (!events) return res.status(404).json({ error: 'No progress file found' });
    res.json({ task_id: taskId, events });
  });

  // Download task-level attachment
  router.get('/discussions/:taskId/attachments/:filename', (req, res) => {
    const { taskId, filename } = req.params;
    const filePath = path.join(sharedDir, 'attachments', taskId, filename);
    res.sendFile(filePath, (err) => {
      if (err) res.status(404).json({ error: 'File not found' });
    });
  });

  // Download comment-level attachment
  router.get('/discussions/:taskId/comments/:commentId/attachments/:filename', (req, res) => {
    const { taskId, commentId, filename } = req.params;
    const filePath = path.join(sharedDir, 'attachments', taskId, 'comments', commentId, filename);
    res.sendFile(filePath, (err) => {
      if (err) res.status(404).json({ error: 'File not found' });
    });
  });

  // Post a comment / request to a discussion
  router.post('/discussions/:taskId/comments', (req, res, next) => {
    const ct = req.headers['content-type'] || '';
    if (ct.includes('multipart/form-data')) {
      // Generate comment ID before multer runs
      const ts = Math.floor(Date.now() / 1000);
      const rand = Math.floor(1000 + Math.random() * 9000);
      req._pendingCommentId = `comment_${ts}_${rand}`;
      upload.array('files', 5)(req, res, (err) => {
        if (err) return res.status(400).json({ error: err.message });
        next();
      });
    } else {
      next();
    }
  }, async (req, res) => {
    const { taskId } = req.params;
    const message = req.body.message;
    const requestRound = req.body.request_round;
    const skipToExecution = req.body.skip_to_execution;

    if (!message || (typeof message === 'string' && !message.trim())) {
      return res.status(400).json({ error: 'message is required' });
    }

    const dDir = path.join(discDir, taskId);
    const statusFile = path.join(dDir, 'status.json');
    const status = await readJson(statusFile);
    if (!status) return res.status(404).json({ error: 'Discussion not found' });

    // Read existing comments or start fresh
    const commentsFile = path.join(dDir, 'comments.json');
    const comments = await readJson(commentsFile) || [];

    const attachments = buildAttachmentMeta(req.files);

    // Generate comment ID (use pending if from multipart, else generate new)
    const commentId = req._pendingCommentId || (() => {
      const ts = Math.floor(Date.now() / 1000);
      const rand = Math.floor(1000 + Math.random() * 9000);
      return `comment_${ts}_${rand}`;
    })();

    // Handle string→boolean for FormData fields
    const shouldRequestRound = requestRound === true || requestRound === 'true';
    const shouldSkipToExecution = skipToExecution === true || skipToExecution === 'true';

    const comment = {
      id: commentId,
      author: 'user',
      message: message.trim(),
      request_round: shouldRequestRound,
      created_at: utcTimestamp()
    };
    if (attachments.length > 0) {
      comment.attachments = attachments;
    }
    comments.push(comment);

    // Save comments
    await writeJsonAtomic(commentsFile, comments);

    // If requesting a new round, update status
    if (shouldRequestRound && !shouldSkipToExecution) {
      // Archive previous decision + result into history if they exist
      const decisionFile = path.join(sharedDir, 'decisions', `${taskId}.json`);
      const resultFile = path.join(sharedDir, 'decisions', `${taskId}_result.json`);
      const historyFile = path.join(sharedDir, 'decisions', `${taskId}_history.json`);
      const prevDecision = await readJson(decisionFile);
      const prevResult = await readJson(resultFile);
      if (prevDecision) {
        const history = await readJson(historyFile) || [];
        history.push({ decision: prevDecision, result: prevResult || null });
        await writeJsonAtomic(historyFile, history);
        // Remove stale result/progress from previous cycle
        const progressFile = path.join(sharedDir, 'decisions', `${taskId}_progress.jsonl`);
        const announceProgressFile = path.join(sharedDir, 'decisions', `${taskId}_announce_progress.jsonl`);
        await fs.unlink(decisionFile).catch(() => {});
        await fs.unlink(resultFile).catch(() => {});
        await fs.unlink(progressFile).catch(() => {});
        await fs.unlink(announceProgressFile).catch(() => {});
      }

      const nextRound = (status.current_round || 1) + 1;
      const newMax = Math.max(status.max_rounds || 3, nextRound);

      status.current_round = nextRound;
      status.max_rounds = newMax;
      status.status = 'discussing';

      await writeJsonAtomic(statusFile, status);

      // Create round directory
      const roundDir = path.join(dDir, `round_${nextRound}`);
      await fs.mkdir(roundDir, { recursive: true });
    }

    // Skip discussion and go directly to execution
    if (shouldSkipToExecution) {
      // Archive previous decision + result into history
      const decisionFile = path.join(sharedDir, 'decisions', `${taskId}.json`);
      const resultFile = path.join(sharedDir, 'decisions', `${taskId}_result.json`);
      const historyFile = path.join(sharedDir, 'decisions', `${taskId}_history.json`);
      const prevDecision = await readJson(decisionFile);
      const prevResult = await readJson(resultFile);
      if (prevDecision) {
        const history = await readJson(historyFile) || [];
        history.push({ decision: prevDecision, result: prevResult || null });
        await writeJsonAtomic(historyFile, history);
      }

      status.status = 'decided';
      status.decided_at = utcTimestamp();
      await writeJsonAtomic(statusFile, status);

      // Create decision file → brain will run announcement → execution
      const taskData = await readJson(path.join(dDir, 'task.json'));
      const approach = `User requested direct execution.\n\nTask: ${taskData?.description || taskData?.title || ''}\n\nUser instruction: ${message.trim()}`;
      const newDecision = {
        task_id: taskId,
        decision: 'approved',
        status: 'announced',
        final_round: 0,
        final_approach: approach,
        executor: 'triceratops',
        decided_at: utcTimestamp()
      };
      await writeJsonAtomic(decisionFile, newDecision);

      // Remove stale result/progress from previous execution cycle
      const progressFile = path.join(sharedDir, 'decisions', `${taskId}_progress.jsonl`);
      await fs.unlink(resultFile).catch(() => {});
      await fs.unlink(progressFile).catch(() => {});
    }

    res.json(comment);
  });

  return router;
};

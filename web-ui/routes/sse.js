const { Router } = require('express');

module.exports = function (sharedDir, watcher) {
  const router = Router();

  router.get('/events', (req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no'
    });

    res.write('data: {"type":"connected"}\n\n');

    const unsubscribe = watcher.subscribe((eventType, relativePath) => {
      const data = JSON.stringify({ type: eventType, path: relativePath });
      res.write(`data: ${data}\n\n`);
    });

    req.on('close', () => {
      unsubscribe();
    });
  });

  return router;
};

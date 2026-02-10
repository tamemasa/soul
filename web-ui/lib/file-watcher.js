const path = require('path');

function classifyEvent(relativePath) {
  if (relativePath.startsWith('inbox/')) return 'inbox:changed';
  if (relativePath.startsWith('discussions/')) return 'discussion:updated';
  if (relativePath.startsWith('decisions/')) return 'decision:updated';
  if (relativePath.startsWith('evaluations/')) return 'evaluation:updated';
  if (relativePath.startsWith('nodes/') && relativePath.endsWith('params.json')) return 'params:changed';
  if (relativePath.startsWith('logs/')) return 'log:appended';
  return null;
}

function createWatcher(sharedDir) {
  const listeners = new Set();
  let watcher = null;

  // Lazy init to avoid requiring chokidar at module load
  async function start() {
    const chokidar = require('chokidar');
    watcher = chokidar.watch(sharedDir, {
      persistent: true,
      ignoreInitial: true,
      depth: 5,
      usePolling: false,
      awaitWriteFinish: { stabilityThreshold: 500, pollInterval: 100 }
    });

    watcher.on('all', (event, filePath) => {
      const relative = path.relative(sharedDir, filePath);
      const eventType = classifyEvent(relative);
      if (eventType) {
        for (const listener of listeners) {
          listener(eventType, relative);
        }
      }
    });
  }

  function subscribe(fn) {
    listeners.add(fn);
    return () => listeners.delete(fn);
  }

  return { start, subscribe };
}

module.exports = { createWatcher };

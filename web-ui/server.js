const express = require('express');
const path = require('path');
const { createWatcher } = require('./lib/file-watcher');

const SHARED_DIR = process.env.SHARED_DIR || '/shared';
const PORT = parseInt(process.env.PORT || '3000', 10);

const app = express();
const watcher = createWatcher(SHARED_DIR);

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// API routes
app.use('/api', require('./routes/api-status')(SHARED_DIR));
app.use('/api', require('./routes/api-tasks')(SHARED_DIR));
app.use('/api', require('./routes/api-discussions')(SHARED_DIR));
app.use('/api', require('./routes/api-decisions')(SHARED_DIR));
app.use('/api', require('./routes/api-params')(SHARED_DIR));
app.use('/api', require('./routes/api-evaluations')(SHARED_DIR));
app.use('/api', require('./routes/api-personality')(SHARED_DIR));
app.use('/api', require('./routes/api-logs')(SHARED_DIR));
app.use('/api', require('./routes/api-openclaw')(SHARED_DIR));
app.use('/api', require('./routes/api-broadcast')(SHARED_DIR));
app.use('/api', require('./routes/api-metrics')(SHARED_DIR));
app.use('/api', require('./routes/sse')(SHARED_DIR, watcher));

// SPA fallback
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

watcher.start().then(() => {
  console.log(`File watcher started on ${SHARED_DIR}`);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Soul Web UI running on http://0.0.0.0:${PORT}`);
});

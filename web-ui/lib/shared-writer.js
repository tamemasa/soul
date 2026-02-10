const fs = require('fs').promises;
const path = require('path');

async function writeJsonAtomic(filePath, data) {
  const dir = path.dirname(filePath);
  await fs.mkdir(dir, { recursive: true });
  const tmp = filePath + '.tmp.' + process.pid;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2) + '\n', 'utf-8');
  await fs.rename(tmp, filePath);
}

function generateTaskId(type = 'task') {
  const ts = Math.floor(Date.now() / 1000);
  const rand = Math.floor(1000 + Math.random() * 9000);
  return `${type}_${ts}_${rand}`;
}

function utcTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

module.exports = { writeJsonAtomic, generateTaskId, utcTimestamp };

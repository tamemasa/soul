const fs = require('fs').promises;
const path = require('path');

async function readJson(filePath) {
  try {
    const data = await fs.readFile(filePath, 'utf-8');
    return JSON.parse(data);
  } catch {
    return null;
  }
}

async function listDirs(dirPath) {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    return entries.filter(e => e.isDirectory()).map(e => e.name);
  } catch {
    return [];
  }
}

async function listJsonFiles(dirPath) {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    return entries.filter(e => e.isFile() && e.name.endsWith('.json')).map(e => e.name);
  } catch {
    return [];
  }
}

async function tailFile(filePath, lines = 50) {
  try {
    const content = await fs.readFile(filePath, 'utf-8');
    const allLines = content.split('\n');
    return allLines.slice(-lines).join('\n');
  } catch {
    return '';
  }
}

async function listFiles(dirPath, ext) {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    return entries.filter(e => e.isFile() && (!ext || e.name.endsWith(ext))).map(e => e.name);
  } catch {
    return [];
  }
}

module.exports = { readJson, listDirs, listJsonFiles, tailFile, listFiles };

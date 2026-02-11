const multer = require('multer');
const path = require('path');
const fs = require('fs');

const SHARED_DIR = process.env.SHARED_DIR || '/shared';
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_FILES = 5;

function sanitizeFilename(name) {
  return name
    .replace(/[^a-zA-Z0-9._\-\u3000-\u9FFF\uF900-\uFAFF]/g, '_')
    .replace(/_{2,}/g, '_')
    .replace(/^\.+/, '_')
    .slice(0, 200);
}

const storage = multer.diskStorage({
  destination(req, _file, cb) {
    let dest;
    if (req._pendingCommentId) {
      dest = path.join(SHARED_DIR, 'attachments', req.params.taskId, 'comments', req._pendingCommentId);
    } else if (req._pendingTaskId) {
      dest = path.join(SHARED_DIR, 'attachments', req._pendingTaskId);
    } else {
      return cb(new Error('No pending ID for upload'));
    }
    fs.mkdirSync(dest, { recursive: true });
    cb(null, dest);
  },
  filename(_req, file, cb) {
    cb(null, sanitizeFilename(file.originalname));
  }
});

const upload = multer({
  storage,
  limits: { fileSize: MAX_FILE_SIZE, files: MAX_FILES }
});

function buildAttachmentMeta(files) {
  if (!files || files.length === 0) return [];
  return files.map(f => ({
    filename: f.filename,
    original_name: f.originalname,
    size: f.size,
    mime_type: f.mimetype
  }));
}

module.exports = { upload, buildAttachmentMeta };

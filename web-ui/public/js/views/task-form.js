export async function renderTaskForm(app) {
  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">New Task</h1>
    </div>

    <div class="card">
      <form id="task-form">
        <div class="form-group">
          <label class="form-label">Title *</label>
          <input class="form-input" name="title" placeholder="Brief summary of the task" required>
        </div>

        <div class="form-group">
          <label class="form-label">Description</label>
          <textarea class="form-textarea" name="description" placeholder="Detailed description (optional)"></textarea>
        </div>

        <div class="form-group">
          <label class="form-label">Attachments</label>
          <label class="file-attach-btn">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M14 9.5V13a1.5 1.5 0 01-1.5 1.5h-9A1.5 1.5 0 012 13V9.5M11 5L8 2M8 2L5 5M8 2v8.5"/></svg>
            Choose files
            <input type="file" name="files" multiple id="task-files" style="display:none">
          </label>
          <div class="file-list" id="file-list"></div>
        </div>

        <div class="grid-2">
          <div class="form-group">
            <label class="form-label">Type</label>
            <select class="form-select" name="type">
              <option value="task">Task (with execution)</option>
              <option value="question">Question (discussion only)</option>
            </select>
          </div>

          <div class="form-group">
            <label class="form-label">Priority</label>
            <select class="form-select" name="priority">
              <option value="low">Low</option>
              <option value="medium" selected>Medium</option>
              <option value="high">High</option>
            </select>
          </div>
        </div>

        <label class="comment-checkbox" style="margin-bottom:12px">
          <input type="checkbox" name="skip_discussion" id="skip-discussion-cb">
          <span>Skip discussion, execute directly</span>
        </label>
        <button type="submit" class="btn btn-primary">Submit Task</button>
      </form>
      <div id="task-result" class="mt-4" style="display:none;"></div>
    </div>
  `;

  // File input change → preview
  const fileInput = document.getElementById('task-files');
  const fileList = document.getElementById('file-list');
  fileInput.addEventListener('change', () => {
    fileList.innerHTML = '';
    for (const f of fileInput.files) {
      const item = document.createElement('div');
      item.className = 'file-item';
      item.innerHTML = `<span class="file-item-name">${escapeHtml(f.name)}</span><span class="file-item-size">${formatFileSize(f.size)}</span>`;
      fileList.appendChild(item);
    }
  });

  document.getElementById('task-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const form = e.target;
    const files = fileInput.files;

    try {
      let res;
      if (files.length > 0) {
        // FormData for multipart upload
        const fd = new FormData();
        fd.append('title', form.title.value);
        fd.append('description', form.description.value || form.title.value);
        fd.append('type', form.type.value);
        fd.append('priority', form.priority.value);
        fd.append('skip_discussion', form.skip_discussion.checked ? 'true' : 'false');
        for (const f of files) fd.append('files', f);
        res = await fetch('/api/tasks', { method: 'POST', body: fd });
      } else {
        // JSON for no-file submission
        const data = {
          title: form.title.value,
          description: form.description.value || form.title.value,
          type: form.type.value,
          priority: form.priority.value,
          skip_discussion: form.skip_discussion.checked
        };
        res = await fetch('/api/tasks', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(data)
        });
      }

      const task = await res.json();
      const resultDiv = document.getElementById('task-result');
      resultDiv.style.display = 'block';
      const statusMsg = form.skip_discussion.checked
        ? 'Direct execution requested.'
        : 'Brain nodes will detect and begin discussion.';
      resultDiv.innerHTML = `
        <div style="color: var(--vote-approve); font-weight: 600;">
          Task submitted: <span style="font-family:var(--font-mono)">${task.id}</span>
        </div>
        <div class="text-sm text-secondary mt-2">
          ${statusMsg}
          <a href="#/timeline" style="color: var(--accent-primary);">View timeline</a>
        </div>
      `;
      form.reset();
      fileList.innerHTML = '';
    } catch (err) {
      const resultDiv = document.getElementById('task-result');
      resultDiv.style.display = 'block';
      resultDiv.innerHTML = `<div style="color: var(--vote-reject);">Error: ${err.message}</div>`;
    }
  });
}

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

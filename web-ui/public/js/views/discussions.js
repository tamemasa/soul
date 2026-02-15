import { renderTimeline, formatToolInput } from '../components/timeline.js';
import { nodeBadge } from '../components/node-badge.js';

export async function renderTimelineList(app) {
  // Only show loading spinner on initial render, not on SSE-triggered re-renders
  if (!app.querySelector('.page-title')) {
    app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  }
  const discussions = await fetch('/api/discussions').then(r => r.json());

  // Sort by time descending (newest first)
  discussions.sort((a, b) => (b.started_at || '').localeCompare(a.started_at || ''));

  // Check if archive section is expanded
  const showArchive = app.querySelector('.archive-section.expanded') !== null;

  const prevScrollY = window.scrollY;

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Timeline</h1>
    </div>
    ${discussions.length > 0 ? discussions.map(d => `
      <div class="card clickable" onclick="location.hash='#/timeline/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${escapeHtml(d.title)}</span>
          <span class="badge badge-status badge-${d.status}">${d.status}</span>
        </div>
        <div class="timeline-card-pipeline">${renderMiniPipeline(d)}</div>
        <div class="text-sm text-secondary" style="font-family:var(--font-mono);margin-top:6px">
          ${formatTime(d.started_at)}${d.completed_at ? ' &rarr; ' + formatTime(d.completed_at) : ''}
        </div>
      </div>
    `).join('') : '<div class="empty-state">No tasks yet</div>'}

    <div class="archive-section ${showArchive ? 'expanded' : ''}" id="archive-section">
      <div class="section-label clickable" id="archive-toggle" style="cursor:pointer;user-select:none;">
        <span id="archive-arrow">${showArchive ? '\u25BC' : '\u25B6'}</span> Archived Tasks
        <span class="badge" id="archive-count" style="margin-left:8px;">...</span>
      </div>
      <div id="archive-list" style="display:${showArchive ? 'block' : 'none'}"></div>
    </div>
  `;

  window.scrollTo(0, prevScrollY);

  // Archive toggle handler
  document.getElementById('archive-toggle').addEventListener('click', async () => {
    const section = document.getElementById('archive-section');
    const list = document.getElementById('archive-list');
    const arrow = document.getElementById('archive-arrow');
    const isExpanded = section.classList.toggle('expanded');
    arrow.textContent = isExpanded ? '\u25BC' : '\u25B6';
    list.style.display = isExpanded ? 'block' : 'none';
    if (isExpanded && !list.dataset.loaded) {
      list.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
      const archived = await fetch('/api/archive').then(r => r.json());
      list.dataset.loaded = 'true';
      list.innerHTML = archived.length > 0 ? archived.map(a => `
        <div class="card clickable" onclick="location.hash='#/timeline/${a.task_id}'" style="opacity:0.8">
          <div class="card-header">
            <span class="card-title">${escapeHtml(a.title || a.task_id || '(無題)')}</span>
            <span class="badge badge-status badge-${a.decision || a.status || 'completed'}">${a.decision || a.status || 'archived'}</span>
          </div>
          <div class="text-sm text-secondary" style="font-family:var(--font-mono)">
            ${formatTime(a.decided_at)} &middot; Archived ${formatTime(a.archived_at)}
          </div>
        </div>
      `).join('') : '<div class="empty-state">No archived tasks</div>';
    }
  });

  // Load archive count
  fetch('/api/archive').then(r => r.json()).then(archived => {
    const countEl = document.getElementById('archive-count');
    if (countEl) countEl.textContent = archived.length;
  }).catch(() => {});
}

function renderMiniPipeline(d) {
  const stages = [
    { key: 'discussion', label: 'Discussion', icon: '\u{1F4AC}' },
    { key: 'decision', label: 'Decision', icon: '\u2714' },
    { key: 'execution', label: 'Execution', icon: '\u26A1' },
    { key: 'review', label: 'Review', icon: '\u{1F50D}' }
  ];

  // Determine which stage is current
  const statusMap = {
    discussing: 0,
    pending_announcement: 1, announcing: 1, announced: 1,
    executing: 2,
    reviewing: 3, remediating: 3,
    completed: 4
  };
  const currentIdx = statusMap[d.status] ?? 0;

  return `<div class="mini-pipeline">${stages.map((stage, i) => {
    let stateClass = 'mini-pipeline-pending';
    if (i < currentIdx) stateClass = 'mini-pipeline-done';
    else if (i === currentIdx && d.status !== 'completed') stateClass = 'mini-pipeline-active';
    else if (d.status === 'completed') stateClass = 'mini-pipeline-done';

    const detail = i === 0 ? `R${d.current_round}`
      : i === 1 && d.decision_type ? d.decision_type
      : i === 2 && d.executor ? d.executor
      : i === 3 && d.review_verdict ? d.review_verdict
      : i === 3 && d.status === 'remediating' ? 'remediate'
      : '';

    return `<div class="mini-pipeline-stage ${stateClass}">
      <span class="mini-pipeline-icon">${stage.icon}</span>
      <span class="mini-pipeline-label">${stage.label}</span>
      ${detail ? `<span class="mini-pipeline-detail">${detail}</span>` : ''}
    </div>${i < stages.length - 1 ? '<div class="mini-pipeline-arrow ' + (i < currentIdx ? 'mini-pipeline-arrow-done' : '') + '">\u2192</div>' : ''}`;
  }).join('')}</div>`;
}

export async function renderDiscussionDetail(app, taskId) {
  stopProgressPolling();
  stopAnnounceProgressPolling();
  stopStatusPolling();
  app.classList.add('detail-view');

  // Only show loading spinner on initial render (not on re-renders)
  const isRerender = !!document.querySelector('.detail-sticky-header');
  const prevScrollTop = isRerender
    ? document.getElementById('detail-scroll-area')?.scrollTop ?? 0
    : -1;
  if (!isRerender) {
    app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  }

  let data = await fetch(`/api/discussions/${taskId}`).then(r => r.json());

  // Fallback to archive if not found in active discussions
  if (data.error) {
    data = await fetch(`/api/archive/${taskId}`).then(r => r.json());
  }
  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }
  const isArchived = !!data.archived;

  const isDiscussing = data.status?.status === 'discussing';
  const currentRound = data.status?.current_round || 0;
  const isExecuting = (data.decision?.status === 'executing') && !data.result?.result;
  const isAnnouncing = data.decision?.status === 'announcing';
  const isReviewing = data.decision?.status === 'reviewing';

  // Determine effective status for pipeline
  // When discussion is reopened (new round requested), status.json takes priority over stale decision
  const discussionStatus = data.status?.status || 'discussing';
  const effectiveStatus = (discussionStatus === 'discussing')
    ? discussionStatus
    : (data.decision?.status || discussionStatus);
  const pipelineHtml = renderPipeline(effectiveStatus, data.result);

  const isMobile = window.innerWidth <= 768;
  const descriptionHtml = data.task?.description ? `<div class="text-secondary mt-2">${escapeHtml(data.task.description)}</div>` : '';
  const attachmentsHtml = data.task?.attachments?.length ? `<div class="attachment-list mt-2">${data.task.attachments.map(a => `<a class="attachment-badge" href="/api/discussions/${taskId}/attachments/${encodeURIComponent(a.filename)}" target="_blank" title="${escapeHtml(a.original_name)} (${formatFileSize(a.size)})">${escapeHtml(a.original_name)}<span class="attachment-size">${formatFileSize(a.size)}</span></a>`).join('')}</div>` : '';

  app.innerHTML = `
    <div class="detail-sticky-header">
      <div class="page-header">
        <h1 class="page-title">${escapeHtml(data.task?.title || taskId)}</h1>
        <a href="#/timeline" class="btn btn-secondary btn-sm">Back</a>
      </div>

      <div class="card mb-4">
        <div class="flex items-center gap-8">
          <span class="badge badge-status badge-${effectiveStatus}">${effectiveStatus}</span>
          ${isArchived ? '<span class="badge" style="background:var(--bg-tertiary);color:var(--text-dim)">archived</span>' : ''}
          <span class="text-sm text-secondary" style="font-family:var(--font-mono)">Round ${currentRound} / ${data.status?.max_rounds || 3}</span>
        </div>
        ${isMobile ? '' : descriptionHtml}
        ${isMobile ? '' : attachmentsHtml}
      </div>

      ${isMobile ? '' : pipelineHtml}
    </div>

    <div class="detail-scroll-area" id="detail-scroll-area">
      ${isMobile ? `<div class="card mb-4">${descriptionHtml}${attachmentsHtml}</div>${pipelineHtml}` : ''}
      ${renderTimeline(data.rounds, {
        comments: data.comments || [],
        isDiscussing,
        currentRound,
        maxRounds: data.status?.max_rounds || 3,
        decision: data.decision,
        result: data.result,
        review: data.review,
        reviewHistory: data.reviewHistory || [],
        isExecuting,
        isReviewing,
        progress: data.progress,
        remediationProgress: data.remediationProgress,
        history: data.history || [],
        isAnnouncing,
        announceProgress: data.announceProgress,
        taskId,
        previousAttempts: data.previousAttempts || []
      })}

      ${isArchived ? '' : `<div class="card comment-form-card" style="margin-top:24px;">
        <form id="comment-form">
          <textarea class="form-textarea" name="message" placeholder="Add a comment or request to the discussion..." rows="3"></textarea>
          <div class="file-list" id="comment-file-list"></div>
          <div class="comment-form-footer">
            <div class="comment-form-left">
              <label class="comment-attach" title="Attach files">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M13.5 7.5l-5.3 5.3a3 3 0 01-4.24-4.24L9.5 3a2 2 0 012.83 2.83L6.8 11.4a1 1 0 01-1.42-1.42l4.95-4.95"/></svg>
                <input type="file" name="files" multiple id="comment-files" style="display:none">
              </label>
              <div class="comment-toggle">
                <span class="toggle-label toggle-label-left active" id="toggle-left">Request additional round</span>
                <label class="toggle-switch">
                  <input type="checkbox" name="action_toggle" id="action-toggle">
                  <span class="toggle-slider"></span>
                </label>
                <span class="toggle-label toggle-label-right" id="toggle-right">Skip to execution</span>
              </div>
            </div>
            <button type="submit" class="btn btn-primary btn-sm">Send</button>
          </div>
        </form>
      </div>`}
    </div>
  `;

  // Restore scroll position on re-render, or scroll to bottom on initial render
  const scrollArea = document.getElementById('detail-scroll-area');
  if (scrollArea) {
    if (prevScrollTop >= 0) {
      scrollArea.scrollTop = prevScrollTop;
    } else {
      scrollArea.scrollTop = scrollArea.scrollHeight;
    }
  }

  // Toggle switch handler
  const actionToggle = document.getElementById('action-toggle');
  if (actionToggle) {
    actionToggle.addEventListener('change', (e) => {
      document.getElementById('toggle-left').classList.toggle('active', !e.target.checked);
      document.getElementById('toggle-right').classList.toggle('active', e.target.checked);
    });
  }

  // Comment file input handler
  const commentFileInput = document.getElementById('comment-files');
  const commentFileList = document.getElementById('comment-file-list');
  if (commentFileInput) commentFileInput.addEventListener('change', () => {
    commentFileList.innerHTML = '';
    for (const f of commentFileInput.files) {
      const item = document.createElement('div');
      item.className = 'file-item';
      item.innerHTML = `<span class="file-item-name">${escapeHtml(f.name)}</span><span class="file-item-size">${formatFileSize(f.size)}</span>`;
      commentFileList.appendChild(item);
    }
  });

  // Comment form handler
  const commentForm = document.getElementById('comment-form');
  if (commentForm) commentForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const form = e.target;
    const message = form.message.value.trim();
    if (!message) return;

    const btn = form.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = 'Sending...';

    const isSkipExecution = form.action_toggle.checked;
    const files = commentFileInput.files;
    try {
      if (files.length > 0) {
        const fd = new FormData();
        fd.append('message', message);
        fd.append('request_round', (!isSkipExecution).toString());
        fd.append('skip_to_execution', isSkipExecution.toString());
        for (const f of files) fd.append('files', f);
        await fetch(`/api/discussions/${taskId}/comments`, { method: 'POST', body: fd });
      } else {
        await fetch(`/api/discussions/${taskId}/comments`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message,
            request_round: !isSkipExecution,
            skip_to_execution: isSkipExecution
          })
        });
      }
      renderDiscussionDetail(app, taskId);
    } catch (err) {
      btn.disabled = false;
      btn.textContent = 'Send';
    }
  });

  // Skip all polling for archived tasks
  if (!isArchived) {
  const isTerminal = !!data.result?.result || effectiveStatus === 'completed';
  const isReviewing = effectiveStatus === 'reviewing';
  const isRemediating = effectiveStatus === 'remediating';

  // Start progress polling if executing or remediating
  // But skip if progress already has a result (avoids infinite re-render loop when decision status is stale)
  const execAlreadyDone = data.progress && data.progress.some(e => e.type === 'result');
  if ((isExecuting || isRemediating) && !execAlreadyDone) {
    startProgressPolling(taskId, app);
  }

  // Start announcement progress polling if announcing
  // But skip if progress already has a result (avoids infinite re-render loop when decision status is stale)
  const announceAlreadyDone = data.announceProgress && data.announceProgress.some(e => e.type === 'result');
  if (isAnnouncing && !announceAlreadyDone) {
    startAnnounceProgressPolling(taskId, app);
  }

  // Status polling handles lightweight in-place updates (badge, pipeline)
  // and does full re-render when status, round responses, or comments change
  if (!isTerminal && !isExecuting && !isAnnouncing && !isRemediating) {
    const initialFingerprint = buildFingerprint(data, effectiveStatus);
    startStatusPolling(taskId, app, initialFingerprint);
  }
  } // end if (!isArchived)
}

// --- Status polling (for intermediate states) ---
let _statusTimer = null;

function stopStatusPolling() {
  if (_statusTimer) {
    clearInterval(_statusTimer);
    _statusTimer = null;
  }
}

function buildFingerprint(data, status) {
  const currentRound = data.status?.current_round || 0;
  const totalResponses = (data.rounds || []).reduce((sum, r) => sum + (r.responses?.length || 0), 0);
  const commentCount = (data.comments || []).length;
  const hasDecision = data.decision ? 1 : 0;
  const hasAnnouncement = data.decision?.announcement?.summary ? 1 : 0;
  const hasResult = data.result?.result ? 1 : 0;
  const hasReview = data.review?.verdict ? 1 : 0;
  const reviewHistoryCount = (data.reviewHistory || []).length;
  return `${status}_r${currentRound}_n${totalResponses}_c${commentCount}_d${hasDecision}_a${hasAnnouncement}_x${hasResult}_rv${hasReview}_rh${reviewHistoryCount}`;
}

function startStatusPolling(taskId, app, lastFingerprint) {
  stopStatusPolling();

  async function poll() {
    // Stop if we navigated away from this detail page
    if (!document.querySelector('.detail-sticky-header')) {
      stopStatusPolling();
      return;
    }
    try {
      const resp = await fetch(`/api/discussions/${taskId}`);
      if (!resp.ok) return;
      const data = await resp.json();
      const newStatus = data.decision?.status || data.status?.status || 'discussing';
      const newFingerprint = buildFingerprint(data, newStatus);

      // Update pipeline in-place
      const pipelineEl = document.querySelector('.pipeline-stepper');
      if (pipelineEl) {
        const tmpDiv = document.createElement('div');
        tmpDiv.innerHTML = renderPipeline(newStatus, data.result);
        const newPipeline = tmpDiv.querySelector('.pipeline-stepper');
        if (newPipeline) pipelineEl.replaceWith(newPipeline);
      }

      // Update status badge in-place
      const badgeEl = document.querySelector('.badge-status');
      if (badgeEl) {
        badgeEl.className = `badge badge-status badge-${newStatus}`;
        badgeEl.textContent = newStatus;
      }

      // If any relevant data changed, do full re-render
      if (newFingerprint !== lastFingerprint) {
        stopStatusPolling();
        renderDiscussionDetail(app, taskId);
      }
    } catch { /* ignore */ }
  }

  poll();
  _statusTimer = setInterval(poll, 3000);
}

// --- Progress polling ---
let _progressTimer = null;
let _lastEventCount = 0;

function stopProgressPolling() {
  if (_progressTimer) {
    clearInterval(_progressTimer);
    _progressTimer = null;
  }
  _lastEventCount = 0;
}

function startProgressPolling(taskId, app) {
  stopProgressPolling();
  _lastEventCount = 0;

  async function poll() {
    // Stop if we navigated away
    if (!document.getElementById('execution-progress')) {
      stopProgressPolling();
      return;
    }
    try {
      const resp = await fetch(`/api/discussions/${taskId}/progress`);
      if (!resp.ok) return;
      const data = await resp.json();
      const events = data.events || [];

      if (events.length !== _lastEventCount) {
        _lastEventCount = events.length;
        renderProgressEvents(events);
      }

      // Stop polling if result event found
      if (events.some(e => e.type === 'result')) {
        stopProgressPolling();
        // Reload the full view after a short delay
        setTimeout(() => renderDiscussionDetail(app, taskId), 1500);
      }
    } catch { /* ignore fetch errors */ }
  }

  poll();
  _progressTimer = setInterval(poll, 2000);
}

function renderProgressEvents(events) {
  const container = document.getElementById('progress-events');
  if (!container) return;

  const hasResult = events.some(e => e.type === 'result');
  let html = '';

  for (const ev of events) {
    if (ev.type === 'system') continue;

    if (ev.type === 'assistant' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'text' && block.text) {
          html += `<div class="progress-event-text">${escapeHtml(block.text)}</div>`;
        }
        if (block.type === 'tool_use') {
          const toolInput = formatToolInput(block.name, block.input);
          html += `<div class="progress-event-tool">
            <div class="progress-tool-header">${escapeHtml(block.name)}</div>
            ${toolInput ? `<div class="progress-tool-input">${escapeHtml(toolInput)}</div>` : ''}
          </div>`;
        }
      }
    }

    if (ev.type === 'user' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'tool_result') {
          const content = typeof block.content === 'string' ? block.content
            : Array.isArray(block.content) ? block.content.map(c => c.text || '').join('\n') : '';
          if (content) {
            const id = 'tr-' + (block.tool_use_id || Math.random().toString(36).slice(2));
            html += `<div class="progress-event-result" id="${id}">
              <button class="progress-result-toggle" onclick="this.parentElement.classList.toggle('expanded')">
                &#9656; Tool result (click to expand)
              </button>
              <div class="progress-result-body">${escapeHtml(content.slice(0, 5000))}</div>
            </div>`;
          }
        }
      }
    }

    if (ev.type === 'result') {
      const duration = ev.duration_ms ? ` (${(ev.duration_ms / 1000).toFixed(1)}s)` : '';
      html += `<div class="progress-event-done">Completed${duration}</div>`;
    }
  }

  if (!hasResult) {
    html += `<div class="progress-streaming"><span class="progress-streaming-dot"></span> Executing...</div>`;
  }

  container.innerHTML = html;

  // Auto-scroll only if user is already near the bottom
  const scrollArea = document.getElementById('detail-scroll-area');
  if (scrollArea) {
    const distanceFromBottom = scrollArea.scrollHeight - scrollArea.scrollTop - scrollArea.clientHeight;
    if (distanceFromBottom < 150) scrollArea.scrollTop = scrollArea.scrollHeight;
  }
}

// --- Announcement progress polling ---
let _announceProgressTimer = null;
let _lastAnnounceEventCount = 0;

function stopAnnounceProgressPolling() {
  if (_announceProgressTimer) {
    clearInterval(_announceProgressTimer);
    _announceProgressTimer = null;
  }
  _lastAnnounceEventCount = 0;
}

function startAnnounceProgressPolling(taskId, app) {
  stopAnnounceProgressPolling();
  _lastAnnounceEventCount = 0;

  async function poll() {
    // Stop if we navigated away
    if (!document.getElementById('announce-progress')) {
      stopAnnounceProgressPolling();
      return;
    }
    try {
      const resp = await fetch(`/api/discussions/${taskId}/progress?phase=announcement`);
      if (!resp.ok) return;
      const data = await resp.json();
      const events = data.events || [];

      if (events.length !== _lastAnnounceEventCount) {
        _lastAnnounceEventCount = events.length;
        renderAnnounceProgressEvents(events);
      }

      // Stop polling if result event found
      if (events.some(e => e.type === 'result')) {
        stopAnnounceProgressPolling();
        // Reload the full view after a short delay
        setTimeout(() => renderDiscussionDetail(app, taskId), 1500);
      }
    } catch { /* ignore fetch errors */ }
  }

  poll();
  _announceProgressTimer = setInterval(poll, 2000);
}

function renderAnnounceProgressEvents(events) {
  const container = document.getElementById('announce-progress-events');
  if (!container) return;

  const hasResult = events.some(e => e.type === 'result');
  let html = '';

  for (const ev of events) {
    if (ev.type === 'system') continue;

    if (ev.type === 'assistant' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'text' && block.text) {
          html += `<div class="progress-event-text">${escapeHtml(block.text)}</div>`;
        }
        if (block.type === 'tool_use') {
          const toolInput = formatToolInput(block.name, block.input);
          html += `<div class="progress-event-tool">
            <div class="progress-tool-header">${escapeHtml(block.name)}</div>
            ${toolInput ? `<div class="progress-tool-input">${escapeHtml(toolInput)}</div>` : ''}
          </div>`;
        }
      }
    }

    if (ev.type === 'user' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'tool_result') {
          const content = typeof block.content === 'string' ? block.content
            : Array.isArray(block.content) ? block.content.map(c => c.text || '').join('\n') : '';
          if (content) {
            const id = 'atr-' + (block.tool_use_id || Math.random().toString(36).slice(2));
            html += `<div class="progress-event-result" id="${id}">
              <button class="progress-result-toggle" onclick="this.parentElement.classList.toggle('expanded')">
                &#9656; Tool result (click to expand)
              </button>
              <div class="progress-result-body">${escapeHtml(content.slice(0, 5000))}</div>
            </div>`;
          }
        }
      }
    }

    if (ev.type === 'result') {
      const duration = ev.duration_ms ? ` (${(ev.duration_ms / 1000).toFixed(1)}s)` : '';
      html += `<div class="progress-event-done">Completed${duration}</div>`;
    }
  }

  if (!hasResult) {
    html += `<div class="progress-streaming"><span class="progress-streaming-dot"></span> Announcing...</div>`;
  }

  container.innerHTML = html;

  // Auto-scroll only if user is already near the bottom
  const scrollArea = document.getElementById('detail-scroll-area');
  if (scrollArea) {
    const distanceFromBottom = scrollArea.scrollHeight - scrollArea.scrollTop - scrollArea.clientHeight;
    if (distanceFromBottom < 150) scrollArea.scrollTop = scrollArea.scrollHeight;
  }
}

function renderPipeline(status, result) {
  const steps = [
    { key: 'discussing', label: 'Discussion' },
    { key: 'announcement', label: 'Announcement' },
    { key: 'executing', label: 'Executing' },
    { key: 'review', label: 'Review' },
    { key: 'completed', label: 'Completed' }
  ];

  const hasResult = !!result?.result;

  function stepState(step) {
    const order = { discussing: 0, pending_announcement: 1, announcing: 1, announced: 2, executing: 2, reviewing: 3, remediating: 3, completed: 4 };
    const currentIdx = order[status] ?? (hasResult ? 4 : -1);
    const stepIdx = steps.indexOf(step);
    if (stepIdx < currentIdx) return 'done';
    if (stepIdx === currentIdx) return hasResult && stepIdx === 4 ? 'done' : 'active';
    return 'pending';
  }

  return `
    <div class="pipeline-stepper">
      ${steps.map((step, i) => {
        const state = stepState(step);
        return `
          <div class="pipeline-step pipeline-step-${state}">
            <div class="pipeline-dot"></div>
            <span class="pipeline-label">${step.label}</span>
          </div>
          ${i < steps.length - 1 ? '<div class="pipeline-connector ' + (stepState(step) === 'done' ? 'pipeline-connector-done' : '') + '"></div>' : ''}
        `;
      }).join('')}
    </div>
  `;
}

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

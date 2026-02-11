import { nodeBadge } from './node-badge.js';
import { voteBadge } from './vote-badge.js';

const ALL_NODES = ['panda', 'gorilla', 'triceratops'];

/**
 * Render a fully unified chronological timeline:
 *   Round 1 discussions → comments → Decision → Announcement → Execution
 *   (or across multiple rounds if consensus was not immediate)
 *
 * @param {Array}  rounds   - Array of { round, responses }
 * @param {Object} options
 * @param {Array}  options.comments
 * @param {boolean} options.isDiscussing
 * @param {number}  options.currentRound
 * @param {Object}  options.decision
 * @param {Object}  options.result
 * @param {boolean} options.isExecuting
 * @param {Array}   options.progress
 */
export function renderTimeline(rounds, options = {}) {
  const {
    comments = [], isDiscussing = false, currentRound = 0, maxRounds = 3,
    decision = null, result = null, isExecuting = false, progress = null,
    history = [], isAnnouncing = false, announceProgress = null,
    taskId = null
  } = options;

  if ((!rounds || rounds.length === 0) && comments.length === 0 && !decision && history.length === 0) {
    return '<p class="empty-state">No discussion rounds yet</p>';
  }

  // Determine which history entry belongs to which final_round
  const historyByRound = {};
  for (const entry of history) {
    const fr = entry.decision?.final_round ?? -1;
    historyByRound[fr] = entry;
  }

  const finalRound = decision?.final_round ?? Infinity;

  // Build earliest response time for each round (for chronological cutoffs)
  const roundEarliestTime = {};
  for (const round of (rounds || [])) {
    const times = round.responses
      .map(r => new Date(r.timestamp).getTime())
      .filter(t => !isNaN(t));
    roundEarliestTime[round.round] = times.length ? Math.min(...times) : 0;
  }

  // Collect all floating events: comments + unmatched history + unmatched current decision
  // These are rendered chronologically between rounds
  const floatingEvents = [];

  for (const c of (comments || [])) {
    floatingEvents.push({
      type: 'comment', comment: c,
      time: new Date(c.created_at).getTime()
    });
  }

  for (const entry of history) {
    const fr = entry.decision?.final_round ?? -1;
    if (!(rounds || []).some(r => r.round === fr)) {
      floatingEvents.push({
        type: 'history', entry,
        time: new Date(entry.decision?.decided_at || 0).getTime()
      });
    }
  }

  if (decision && finalRound !== Infinity && !(rounds || []).some(r => r.round === finalRound)) {
    floatingEvents.push({
      type: 'decision',
      time: new Date(decision.decided_at || 0).getTime()
    });
  }

  const typeOrder = { comment: 0, history: 1, decision: 2 };
  floatingEvents.sort((a, b) => (a.time - b.time) || (typeOrder[a.type] - typeOrder[b.type]));

  let floatingIdx = 0;

  // Render all floating events whose timestamp is before cutoffTime
  // If cutoffTime is null, render all remaining events
  function renderFloatingBefore(cutoffTime) {
    let out = '';
    while (floatingIdx < floatingEvents.length) {
      const ev = floatingEvents[floatingIdx];
      if (cutoffTime && ev.time >= cutoffTime) break;
      floatingIdx++;
      if (ev.type === 'comment') {
        out += renderCommentItems([ev.comment], taskId);
      } else if (ev.type === 'history') {
        out += renderDecisionItem(ev.entry.decision);
        out += renderAnnouncementItem(ev.entry.decision);
        out += renderExecutionItem(ev.entry.result, false, null, ev.entry.decision);
      } else if (ev.type === 'decision') {
        out += renderDecisionItem(decision);
        out += renderAnnouncementItem(decision, isAnnouncing, announceProgress);
        out += renderExecutionItem(result, isExecuting, progress, decision);
      }
    }
    return out;
  }

  let html = '<div class="timeline">';

  // Floating events before the first round
  const firstRoundStart = (rounds || []).length > 0
    ? (roundEarliestTime[(rounds || [])[0].round] || null)
    : null;
  html += renderFloatingBefore(firstRoundStart);

  // Render each round + inline matched history/decision, then floating events
  (rounds || []).forEach((round, i) => {
    const respondedNodes = round.responses.map(r => r.node);
    const isActive = round.round === currentRound && isDiscussing;
    const pendingNodes = isActive
      ? ALL_NODES.filter(n => !respondedNodes.includes(n))
      : [];

    html += `
    <div class="timeline-item">
      <div class="timeline-round">Round ${round.round}</div>
      ${round.responses.map(r => renderResponse(r)).join('')}
      ${pendingNodes.map(node => `
        <div class="timeline-response timeline-response-pending">
          <div class="response-header">
            ${nodeBadge(node)}
            <span class="pending-indicator">検討中…</span>
          </div>
        </div>
      `).join('')}
    </div>`;

    // Show indicator when all nodes responded but decision not yet generated
    if (isActive && pendingNodes.length === 0 && !decision) {
      const isFinalRound = currentRound >= maxRounds;
      const label = isFinalRound ? '最終決定を生成中…' : '合意を確認中…';
      html += `
      <div class="timeline-item timeline-decision-item">
        <div class="timeline-round">Decision</div>
        <div class="timeline-response timeline-response-pending">
          <div class="response-header">
            ${nodeBadge('triceratops')}
            <span class="pending-indicator">${label}</span>
          </div>
        </div>
      </div>`;
    }

    // Insert history decision+execution if a previous cycle ended at this round
    if (historyByRound[round.round]) {
      const h = historyByRound[round.round];
      html += renderDecisionItem(h.decision);
      html += renderAnnouncementItem(h.decision);
      html += renderExecutionItem(h.result, false, null, h.decision);
    }

    // Insert current decision + announcement + execution after the round where consensus was reached
    if (round.round === finalRound) {
      html += renderDecisionItem(decision);
      html += renderAnnouncementItem(decision, isAnnouncing, announceProgress);
      html += renderExecutionItem(result, isExecuting, progress, decision);
    }

    // Render floating events between this round and the next
    const nextRound = (rounds || [])[i + 1];
    const nextCutoff = nextRound ? (roundEarliestTime[nextRound.round] || null) : null;
    html += renderFloatingBefore(nextCutoff);
  });

  html += '</div>';
  return html;
}

// --- Decision timeline item ---
function renderDecisionItem(decision) {
  if (!decision) return '';
  return `
    <div class="timeline-item timeline-decision-item">
      <div class="timeline-round">Decision</div>
      <div class="timeline-decision-card ${decision.decision === 'rejected' ? 'rejected' : ''}">
        <div class="flex items-center gap-8 mb-4">
          <span class="badge badge-status badge-${decision.status || decision.decision}">${decision.decision}</span>
          ${decision.executor ? nodeBadge(decision.executor) : ''}
        </div>
        <div class="text-sm text-secondary">
          Consensus at round ${decision.final_round} &middot; ${formatTime(decision.decided_at)}
        </div>
      </div>
    </div>`;
}

// --- Announcement timeline item ---
function renderAnnouncementItem(decision, isAnnouncing = false, announceProgress = null) {
  // Show progress while announcing
  if (isAnnouncing) {
    return `
    <div class="timeline-item timeline-announcement-item">
      <div class="timeline-round">Announcement</div>
      <div class="execution-progress" id="announce-progress">
        <div class="execution-progress-header">
          <span class="execution-progress-title">Announcement Progress</span>
          ${nodeBadge('triceratops')}
        </div>
        <div class="progress-events" id="announce-progress-events">
          <div class="progress-streaming"><span class="progress-streaming-dot"></span> Waiting for output...</div>
        </div>
      </div>
    </div>`;
  }

  if (!decision?.announcement) return '';
  const a = decision.announcement;

  // If summary is empty but we have announceProgress, extract content from progress log
  let summary = a.summary || '';
  let keyPoints = a.key_points || [];
  if (!summary && announceProgress?.length) {
    const extracted = extractAnnouncementFromProgress(announceProgress);
    summary = extracted.summary || summary;
    keyPoints = extracted.key_points?.length ? extracted.key_points : keyPoints;
  }

  if (!summary && !keyPoints.length) return '';

  return `
    <div class="timeline-item timeline-announcement-item">
      <div class="timeline-round">Announcement</div>
      <div class="timeline-announcement-card">
        <div class="flex items-center gap-8 mb-4">
          ${nodeBadge(a.announced_by || 'triceratops')}
          <span class="text-dim text-sm" style="font-family:var(--font-mono)">${formatTime(a.announced_at)}</span>
        </div>
        <div class="announcement-summary">${renderMarkdown(summary)}</div>
        ${keyPoints.length ? `
          <div class="announcement-keypoints mt-4">
            <div class="section-label">Key Points</div>
            <ul>${keyPoints.map(p => `<li>${escapeHtml(p)}</li>`).join('')}</ul>
          </div>
        ` : ''}
      </div>
    </div>`;
}

// Extract announcement data from progress log when decision file has empty summary
function extractAnnouncementFromProgress(events) {
  let fullText = '';
  for (const ev of events) {
    if (ev.type === 'assistant' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'text' && block.text) {
          fullText += block.text;
        }
      }
    }
  }
  if (!fullText) return {};

  // Try to parse JSON from the text (may be wrapped in code fences or have preamble)
  const jsonMatch = fullText.match(/```(?:json)?\s*([\s\S]*?)```/);
  const jsonStr = jsonMatch ? jsonMatch[1].trim() : null;
  if (jsonStr) {
    try {
      return JSON.parse(jsonStr);
    } catch { /* fall through */ }
  }

  // Try finding raw JSON object
  const idx = fullText.indexOf('{');
  const lastIdx = fullText.lastIndexOf('}');
  if (idx >= 0 && lastIdx > idx) {
    try {
      return JSON.parse(fullText.slice(idx, lastIdx + 1));
    } catch { /* fall through */ }
  }

  return {};
}

// --- Execution timeline item ---
function renderExecutionItem(result, isExecuting, progress, decision) {
  if (!isExecuting && !result?.result && !(progress?.length)) return '';

  let inner = '';
  if (isExecuting) {
    inner = `
      <div class="execution-progress" id="execution-progress">
        <div class="execution-progress-header">
          <span class="execution-progress-title">Execution Progress</span>
          ${nodeBadge(decision?.executor || 'panda')}
        </div>
        <div class="progress-events" id="progress-events">
          <div class="progress-streaming"><span class="progress-streaming-dot"></span> Waiting for output...</div>
        </div>
      </div>`;
  } else {
    // Show progress snapshot (execution details) if available
    if (progress?.length) {
      inner += renderProgressSnapshotInline(progress);
    }
    // Show final result summary if available
    if (result?.result) {
      inner += `
      <div class="execution-result-box" style="border-left:none;margin-top:0;">
        <div class="flex items-center gap-8 mb-4">
          ${nodeBadge(result.executor || 'panda')}
          <span class="text-dim text-sm" style="font-family:var(--font-mono)">${formatTime(result.completed_at)}</span>
        </div>
        <div class="result-content">${renderMarkdown(result.result)}</div>
      </div>`;
    }
  }

  return `
    <div class="timeline-item timeline-execution-item">
      <div class="timeline-round">Execution</div>
      ${inner}
    </div>`;
}

function renderProgressSnapshotInline(events) {
  let inner = '';
  for (const ev of events) {
    if (ev.type === 'system') continue;
    if (ev.type === 'assistant' && ev.message?.content) {
      for (const block of ev.message.content) {
        if (block.type === 'text' && block.text) {
          inner += `<div class="progress-event-text">${escapeHtml(block.text)}</div>`;
        }
        if (block.type === 'tool_use') {
          const toolInput = formatToolInput(block.name, block.input);
          inner += `<div class="progress-event-tool">
            <div class="progress-tool-header">${escapeHtml(block.name)}</div>
            ${toolInput ? `<div class="progress-tool-input">${escapeHtml(toolInput)}</div>` : ''}
          </div>`;
        }
      }
    }
  }
  if (!inner) return '';
  return `<div class="execution-progress" style="border-left:none;margin-top:0;">
    <div class="progress-events">${inner}</div>
  </div>`;
}

export function formatToolInput(name, input) {
  if (!input) return '';
  if (name === 'Bash' && input.command) return `$ ${input.command}`;
  if (name === 'Write' && input.file_path) return `Write: ${input.file_path}`;
  if (name === 'Edit' && input.file_path) return `Edit: ${input.file_path}`;
  if (name === 'Read' && input.file_path) return `Read: ${input.file_path}`;
  if (name === 'Glob' && input.pattern) return `Glob: ${input.pattern}`;
  if (name === 'Grep' && input.pattern) return `Grep: ${input.pattern}`;
  const keys = Object.keys(input);
  if (keys.length === 0) return '';
  const first = input[keys[0]];
  return typeof first === 'string' ? first.slice(0, 200) : JSON.stringify(input).slice(0, 200);
}

// --- Discussion response ---
function renderResponse(r) {
  const opinion = extractOpinion(r);
  const approach = extractApproach(r);
  const concerns = extractConcerns(r);
  return `
    <div class="timeline-response">
      <div class="response-header">
        ${nodeBadge(r.node)}
        ${voteBadge(r.vote)}
        <span class="text-dim text-sm" style="font-family:var(--font-mono)">${formatTime(r.timestamp)}</span>
      </div>
      <div class="response-opinion">${escapeHtml(opinion)}</div>
      ${concerns.length ? `
        <div class="response-concerns">
          ${concerns.map(c => `<div class="concern-item">${escapeHtml(c)}</div>`).join('')}
        </div>
      ` : ''}
      ${approach ? `
        <details class="mt-2">
          <summary class="text-sm text-secondary" style="cursor:pointer">Proposed approach</summary>
          <div class="response-opinion mt-2">${escapeHtml(approach)}</div>
        </details>
      ` : ''}
    </div>
  `;
}

function renderCommentItems(comments, taskId) {
  return comments.map(c => `
    <div class="timeline-item timeline-comment-item">
      <div class="timeline-comment">
        <div class="comment-header">
          <span class="badge badge-user">USER</span>
          ${c.request_round ? '<span class="badge badge-status badge-discussing">round requested</span>' : ''}
          <span class="text-dim text-sm" style="font-family:var(--font-mono)">${formatTime(c.created_at)}</span>
        </div>
        <div class="comment-body">${escapeHtml(c.message)}</div>
        ${c.attachments?.length ? renderAttachmentBadges(c.attachments, taskId, c.id) : ''}
      </div>
    </div>
  `).join('');
}

function renderAttachmentBadges(attachments, taskId, commentId) {
  if (!attachments || attachments.length === 0) return '';
  return `<div class="attachment-list mt-2">${attachments.map(a => {
    const baseUrl = `/api/discussions/${encodeURIComponent(taskId || '')}`;
    const href = commentId
      ? `${baseUrl}/comments/${encodeURIComponent(commentId)}/attachments/${encodeURIComponent(a.filename)}`
      : `${baseUrl}/attachments/${encodeURIComponent(a.filename)}`;
    return `<a class="attachment-badge" href="${href}" target="_blank" title="${escapeHtml(a.original_name)} (${formatFileSize(a.size)})">${escapeHtml(a.original_name)}<span class="attachment-size">${formatFileSize(a.size)}</span></a>`;
  }).join('')}</div>`;
}

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function renderMarkdown(text) {
  return (text || '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/^### (.+)$/gm, '<h3>$1</h3>')
    .replace(/^## (.+)$/gm, '<h2>$1</h2>')
    .replace(/^# (.+)$/gm, '<h1>$1</h1>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/^- (.+)$/gm, '<li>$1</li>')
    .replace(/(<li>.*<\/li>\n?)+/g, '<ul>$&</ul>')
    .replace(/\n{2,}/g, '</p><p>')
    .replace(/\n/g, '<br>');
}

// Try to parse embedded JSON from opinion field.
// Handles: (1) ```json ... ``` code fences, (2) preamble text followed by { ... } JSON
function parseEmbeddedJson(raw) {
  if (!raw) return null;

  // Pattern 1: code fence wrapped JSON
  if (raw.startsWith('```')) {
    try {
      const jsonStr = raw.replace(/^```(?:json)?\n?/, '').replace(/\n?```\s*$/, '');
      return JSON.parse(jsonStr);
    } catch { /* fall through */ }
  }

  // Pattern 2: preamble text + JSON object (find first top-level '{')
  const idx = raw.indexOf('{');
  if (idx > 0) {
    // Find the matching closing brace from the end
    const lastIdx = raw.lastIndexOf('}');
    if (lastIdx > idx) {
      try {
        return JSON.parse(raw.slice(idx, lastIdx + 1));
      } catch { /* fall through */ }
    }
  }

  return null;
}

function extractOpinion(r) {
  const raw = r.opinion || '';
  const parsed = parseEmbeddedJson(raw);
  if (parsed?.opinion) return parsed.opinion;
  return raw;
}

function extractApproach(r) {
  const raw = r.opinion || '';
  const parsed = parseEmbeddedJson(raw);
  if (parsed?.proposed_approach) return parsed.proposed_approach;
  return r.proposed_approach || '';
}

function extractConcerns(r) {
  const raw = r.opinion || '';
  const parsed = parseEmbeddedJson(raw);
  if (parsed) {
    const concerns = parsed.concerns || r.concerns || [];
    return Array.isArray(concerns) ? concerns : [];
  }
  return (r.concerns && Array.isArray(r.concerns)) ? r.concerns : [];
}

function formatTime(ts) {
  if (!ts) return '';
  try {
    return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

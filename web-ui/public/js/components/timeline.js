import { nodeBadge } from './node-badge.js';
import { voteBadge } from './vote-badge.js';

const ALL_NODES = ['panda', 'gorilla', 'triceratops'];

/**
 * Render a fully chronological timeline where ALL events
 * (individual discussion responses, comments, decisions, announcements,
 * execution results, reviews, remediations) are sorted by timestamp.
 */
export function renderTimeline(rounds, options = {}) {
  const {
    comments = [], isDiscussing = false, currentRound = 0, maxRounds = 3,
    decision = null, result = null, review = null, reviewHistory = [], isExecuting = false, isReviewing = false, progress = null,
    remediationProgress = null,
    history = [], isAnnouncing = false, announceProgress = null,
    taskId = null, previousAttempts = []
  } = options;

  if ((!rounds || rounds.length === 0) && comments.length === 0 && !decision && history.length === 0) {
    return '<p class="empty-state">No discussion rounds yet</p>';
  }

  // Collect ALL events into a flat list with timestamps for sorting
  const events = [];

  // 1. Individual discussion responses (each node response is its own event)
  for (const round of (rounds || [])) {
    for (const r of round.responses) {
      events.push({
        type: 'response',
        time: new Date(r.timestamp || 0).getTime(),
        round: round.round,
        response: r
      });
    }
  }

  // 2. Pending nodes for current active round (rendered at the end, after all timed events)
  // These don't have timestamps - they'll be appended after sorted events

  // 3. Comments
  for (const c of (comments || [])) {
    events.push({
      type: 'comment',
      time: new Date(c.created_at || 0).getTime(),
      comment: c
    });
  }

  // 4. History entries (previous cycles: decision + announcement + execution + review)
  for (const entry of history) {
    if (entry.decision) {
      events.push({
        type: 'history_decision',
        time: new Date(entry.decision.decided_at || 0).getTime(),
        decision: entry.decision
      });
      if (entry.decision.announcement?.announced_at) {
        events.push({
          type: 'history_announcement',
          time: new Date(entry.decision.announcement.announced_at || 0).getTime(),
          decision: entry.decision
        });
      }
    }
    if (entry.result) {
      events.push({
        type: 'history_execution',
        time: new Date(entry.result.completed_at || entry.decision?.decided_at || 0).getTime(),
        result: entry.result,
        decision: entry.decision
      });
    }
    if (entry.review?.verdict) {
      events.push({
        type: 'history_review',
        time: new Date(entry.review.reviewed_at || 0).getTime(),
        review: entry.review
      });
    } else if (entry.decision?.review_verdict) {
      // Fallback: reconstruct minimal review from decision metadata
      events.push({
        type: 'history_review',
        time: new Date(entry.decision.completed_at || entry.decision.executed_at || 0).getTime(),
        review: {
          verdict: entry.decision.review_verdict,
          reviewer: 'panda',
          reviewed_at: entry.decision.completed_at || entry.decision.executed_at
        }
      });
    }
  }

  // 5. Current decision
  if (decision) {
    events.push({
      type: 'decision',
      time: new Date(decision.decided_at || 0).getTime(),
      decision
    });

    // 6. Current announcement (completed)
    if (decision.announcement?.announced_at && !isAnnouncing) {
      events.push({
        type: 'announcement',
        time: new Date(decision.announcement.announced_at || 0).getTime(),
        decision,
        announceProgress
      });
    }
  }

  // 7. Previous execution attempts
  for (const attempt of (previousAttempts || [])) {
    events.push({
      type: 'previous_attempt',
      time: new Date(decision?.decided_at || 0).getTime() + (attempt.attempt + 1),
      attempt,
      decision
    });
  }

  // 8. Current execution result (completed)
  if (result?.result) {
    events.push({
      type: 'execution_result',
      time: new Date(result.completed_at || 0).getTime(),
      result,
      progress,
      decision,
      previousAttempts
    });
  }

  // 9. Review history (previous reviews within current cycle)
  if (reviewHistory && reviewHistory.length > 0) {
    for (let i = 0; i < reviewHistory.length; i++) {
      events.push({
        type: 'review',
        time: new Date(reviewHistory[i].reviewed_at || 0).getTime(),
        review: reviewHistory[i],
        reviewNum: i + 1
      });
      // Remediation after each failed review
      if (decision?.remediation_count || decision?.remediated) {
        const remProg = (i === reviewHistory.length - 1) ? remediationProgress : null;
        events.push({
          type: 'remediation',
          time: new Date(reviewHistory[i].reviewed_at || 0).getTime() + 1,
          decision,
          attempt: i + 1,
          progress: remProg
        });
      }
    }
  }

  // 10. Current review (completed)
  if (review?.verdict) {
    const reviewNum = (reviewHistory?.length > 0) ? (reviewHistory.length + 1) : 0;
    events.push({
      type: 'review',
      time: new Date(review.reviewed_at || 0).getTime(),
      review,
      reviewNum
    });
  }

  // Sort all events chronologically (stable sort preserves insertion order for same timestamp)
  events.sort((a, b) => a.time - b.time);

  let html = '<div class="timeline">';

  // Track which round labels we've already shown
  const shownRoundLabels = new Set();

  // Render sorted events
  for (const ev of events) {
    switch (ev.type) {
      case 'response': {
        // Show round label as a separator when we encounter a new round
        if (!shownRoundLabels.has(ev.round)) {
          shownRoundLabels.add(ev.round);
          html += `<div class="timeline-round-separator">Round ${ev.round}</div>`;
        }
        html += `<div class="timeline-item">${renderResponse(ev.response)}</div>`;
        break;
      }
      case 'comment':
        html += renderCommentItems([ev.comment], taskId);
        break;
      case 'history_decision':
        html += renderDecisionItem(ev.decision);
        break;
      case 'history_announcement':
        html += renderAnnouncementItem(ev.decision);
        break;
      case 'history_execution':
        html += renderExecutionItem(ev.result, false, null, ev.decision);
        break;
      case 'history_review':
        html += renderReviewItem(ev.review);
        break;
      case 'decision':
        html += renderDecisionItem(ev.decision);
        break;
      case 'announcement':
        html += renderAnnouncementItem(ev.decision, false, ev.announceProgress);
        break;
      case 'previous_attempt':
        html += renderPreviousAttemptItem(ev.attempt);
        break;
      case 'execution_result':
        html += renderExecutionItem(ev.result, false, ev.progress, ev.decision);
        break;
      case 'review':
        html += renderReviewItem(ev.review, false, ev.reviewNum);
        break;
      case 'remediation':
        html += renderRemediationItem(ev.decision, ev.attempt, ev.progress);
        break;
    }
  }

  // Append live/pending states at the end (no timestamp - they're happening now)

  // Pending discussion nodes (currently thinking)
  if (isDiscussing) {
    const respondedNodes = [];
    for (const round of (rounds || [])) {
      if (round.round === currentRound) {
        for (const r of round.responses) respondedNodes.push(r.node);
      }
    }
    const pendingNodes = ALL_NODES.filter(n => !respondedNodes.includes(n));
    if (pendingNodes.length > 0) {
      if (!shownRoundLabels.has(currentRound)) {
        shownRoundLabels.add(currentRound);
        html += `<div class="timeline-round-separator">Round ${currentRound}</div>`;
      }
      for (const node of pendingNodes) {
        html += `
        <div class="timeline-item">
          <div class="timeline-response timeline-response-pending">
            <div class="response-header">
              ${nodeBadge(node)}
              <span class="pending-indicator">検討中…</span>
            </div>
          </div>
        </div>`;
      }
    }

    // Consensus check pending (all responded, no decision yet)
    if (pendingNodes.length === 0 && !decision) {
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
  }

  // Live announcement progress
  if (isAnnouncing) {
    html += `
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

  // Live execution progress
  if (isExecuting) {
    const retryCount = decision?.retry_count || 0;
    const attemptLabel = retryCount > 0 ? ` (Attempt ${retryCount + 1})` : '';
    html += `
    <div class="timeline-item timeline-execution-item">
      <div class="timeline-round">Execution${attemptLabel}</div>
      <div class="execution-progress" id="execution-progress">
        <div class="execution-progress-header">
          <span class="execution-progress-title">Execution Progress${attemptLabel}</span>
          ${nodeBadge(decision?.executor || 'panda')}
        </div>
        <div class="progress-events" id="progress-events">
          <div class="progress-streaming"><span class="progress-streaming-dot"></span> Waiting for output...</div>
        </div>
      </div>
    </div>`;
  }

  // Live review in progress
  if (isReviewing && !review?.verdict) {
    const reviewNum = (reviewHistory?.length > 0) ? (reviewHistory.length + 1) : 0;
    const reviewLabel = reviewNum > 0 ? `Review #${reviewNum}` : 'Review';
    html += `
    <div class="timeline-item timeline-review-item">
      <div class="timeline-round">${reviewLabel}</div>
      <div class="timeline-review-card">
        <div class="response-header">
          ${nodeBadge('panda')}
          <span class="pending-indicator">レビュー中…</span>
        </div>
      </div>
    </div>`;
  }

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

// --- Announcement timeline item (completed state only) ---
function renderAnnouncementItem(decision, isAnnouncing = false, announceProgress = null) {
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

// --- Execution timeline item (completed state only) ---
function renderExecutionItem(result, isExecuting, progress, decision) {
  if (!result?.result && !(progress?.length)) return '';

  let inner = '';
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

  return `
    <div class="timeline-item timeline-execution-item">
      <div class="timeline-round">Execution</div>
      ${inner}
    </div>`;
}

// --- Previous execution attempt ---
function renderPreviousAttemptItem(attempt) {
  return `
    <div class="timeline-item timeline-execution-item">
      <details class="previous-attempt">
        <summary class="previous-attempt-summary">Previous Attempt ${attempt.attempt + 1} (interrupted)</summary>
        <div class="previous-attempt-content">
          ${renderProgressSnapshotInline(attempt.events)}
        </div>
      </details>
    </div>`;
}

// --- Remediation timeline item ---
function renderRemediationItem(decision, attempt, progress) {
  if (!decision?.remediation_count && !decision?.remediated) return '';

  let inner = '';
  if (progress?.length) {
    inner = renderProgressSnapshotInline(progress);
  }

  return `
    <div class="timeline-item timeline-remediation-item">
      <div class="timeline-round">Remediation${attempt > 0 ? ' #' + attempt : ''}</div>
      <div class="timeline-remediation-card">
        <div class="flex items-center gap-8 mb-4">
          ${nodeBadge(decision?.executor || 'triceratops')}
          <span class="badge" style="background:rgba(251,191,36,0.15);color:#fbbf24">REMEDIATION</span>
        </div>
        ${inner || '<div class="text-sm text-secondary">修正を実行しました</div>'}
      </div>
    </div>`;
}

// --- Review timeline item (completed state only) ---
function renderReviewItem(review, isReviewing = false, reviewNum = 0) {
  if (!review?.verdict) return '';
  const reviewLabel = reviewNum > 0 ? `Review #${reviewNum}` : 'Review';

  const isPassed = review.verdict === 'pass';
  const verdictClass = isPassed ? 'review-pass' : 'review-fail';
  const verdictLabel = isPassed ? 'PASS' : 'FAIL';
  const violations = review.violations || [];

  return `
    <div class="timeline-item timeline-review-item">
      <div class="timeline-round">${reviewLabel}</div>
      <div class="timeline-review-card ${verdictClass}">
        <div class="flex items-center gap-8 mb-4">
          ${nodeBadge(review.reviewer || 'panda')}
          <span class="badge badge-review badge-review-${review.verdict}">${verdictLabel}</span>
          <span class="text-dim text-sm" style="font-family:var(--font-mono)">${formatTime(review.reviewed_at)}</span>
        </div>
        ${review.summary ? `<div class="review-summary">${escapeHtml(review.summary)}</div>` : ''}
        ${violations.length ? `
          <div class="review-violations mt-4">
            <div class="section-label">Violations</div>
            ${violations.map(v => `<div class="violation-item">${escapeHtml(v)}</div>`).join('')}
          </div>
        ` : ''}
        ${review.remediation_instructions ? `
          <details class="mt-2">
            <summary class="text-sm text-secondary" style="cursor:pointer">Remediation instructions</summary>
            <div class="review-remediation mt-2">${escapeHtml(review.remediation_instructions)}</div>
          </details>
        ` : ''}
      </div>
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

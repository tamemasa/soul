import { nodeBadge } from '../components/node-badge.js';

export async function renderDecisionList(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const decisions = await fetch('/api/decisions').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Decisions</h1>
    </div>
    ${decisions.length > 0 ? decisions.map(d => `
      <div class="card clickable" onclick="location.hash='#/decisions/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${d.task_id}</span>
          <span class="badge badge-status badge-${d.status || d.decision}">${d.status || d.decision}</span>
          ${d.review_verdict ? `<span class="badge badge-review badge-review-${d.review_verdict}">${d.review_verdict === 'pass' ? 'PASS' : 'FAIL'}</span>` : ''}
        </div>
        <div class="text-sm text-secondary" style="font-family:var(--font-mono)">
          ${d.executor ? `Executor: ${d.executor}` : ''} &middot; Round ${d.final_round || '?'} &middot; ${formatTime(d.decided_at)}
        </div>
      </div>
    `).join('') : '<div class="empty-state">No decisions yet</div>'}
  `;
}

export async function renderDecisionDetail(app, taskId) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const data = await fetch(`/api/decisions/${taskId}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${taskId}</h1>
      <a href="#/decisions" class="btn btn-secondary btn-sm">Back</a>
    </div>

    <div class="card">
      <div class="flex items-center gap-8 mb-4">
        <span class="badge badge-status badge-${data.status || data.decision}">${data.decision}</span>
        ${data.executor ? nodeBadge(data.executor) : ''}
        ${data.review_verdict ? `<span class="badge badge-review badge-review-${data.review_verdict}">${data.review_verdict === 'pass' ? 'REVIEW PASS' : 'REVIEW FAIL'}</span>` : ''}
      </div>
      <div class="text-sm text-secondary" style="font-family:var(--font-mono)">
        <div>Round: ${data.final_round || '?'}</div>
        <div>Decided: ${formatTime(data.decided_at)}</div>
        ${data.completed_at ? `<div>Completed: ${formatTime(data.completed_at)}</div>` : ''}
      </div>
      <div class="mt-4">
        <a href="#/discussions/${taskId}" style="color: var(--accent-primary); font-size: 13px;">View full discussion</a>
      </div>
    </div>

    ${data.result ? `
      <div class="section-label" style="margin-top:20px;">Execution Result</div>
      <div class="result-content">${renderMarkdown(data.result)}</div>
    ` : ''}

    ${renderReviewSection(data.review, data.reviewHistory)}
  `;
}

function renderReviewSection(review, reviewHistory) {
  if (!review && (!reviewHistory || reviewHistory.length === 0)) return '';

  let html = '';

  // Show review history (previous reviews) if present
  if (reviewHistory && reviewHistory.length > 0) {
    html += `<div class="section-label" style="margin-top:20px;">Review History</div>`;
    reviewHistory.forEach((r, i) => {
      html += renderReviewCard(r, `Review #${i + 1}`);
    });
  }

  // Show current/latest review
  if (review && review.verdict) {
    const label = reviewHistory && reviewHistory.length > 0 ? `Review #${reviewHistory.length + 1} (Latest)` : 'Review Result';
    html += `<div class="section-label" style="margin-top:20px;">${label}</div>`;
    html += renderReviewCard(review);
  }

  return html;
}

function renderReviewCard(review, label) {
  if (!review || !review.verdict) return '';

  const isPassed = review.verdict === 'pass';
  const verdictClass = isPassed ? 'review-pass' : 'review-fail';
  const verdictLabel = isPassed ? 'PASS' : 'FAIL';
  const violations = review.violations || [];

  return `
    <div class="timeline-review-card ${verdictClass}" style="margin-bottom:12px;">
      <div class="flex items-center gap-8 mb-4">
        ${nodeBadge(review.reviewer || 'panda')}
        <span class="badge badge-review badge-review-${review.verdict}">${verdictLabel}</span>
        <span class="text-dim text-sm">${formatTime(review.reviewed_at)}</span>
      </div>
      ${review.summary ? `<div class="review-summary">${escapeHtml(review.summary)}</div>` : ''}
      ${violations.length ? `
        <div class="review-violations mt-4">
          <div class="section-label" style="margin-top:0;">Violations</div>
          ${violations.map(v => `<div class="violation-item">${escapeHtml(v)}</div>`).join('')}
        </div>
      ` : ''}
      ${review.remediation_instructions ? `
        <details class="mt-2">
          <summary class="text-sm text-secondary" style="cursor:pointer">Remediation instructions</summary>
          <div class="review-remediation mt-2">${escapeHtml(review.remediation_instructions)}</div>
        </details>
      ` : ''}
    </div>`;
}

function escapeHtml(text) {
  return (text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
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

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

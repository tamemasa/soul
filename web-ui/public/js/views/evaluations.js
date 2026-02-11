import { nodeBadge } from '../components/node-badge.js';

export async function renderEvaluationList(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const cycles = await fetch('/api/evaluations').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Evaluations</h1>
      <button class="btn btn-primary" id="trigger-eval">Trigger Evaluation</button>
    </div>
    ${cycles.length > 0 ? cycles.map(c => `
      <div class="card clickable" onclick="location.hash='#/evaluations/${c.cycle_id}'">
        <div class="card-header">
          <span class="card-title" style="font-family:var(--font-mono)">${c.cycle_id}</span>
          <span class="badge badge-status badge-${c.status}">${c.status}</span>
        </div>
        <div class="text-sm text-secondary" style="font-family:var(--font-mono)">
          ${formatTime(c.triggered_at)}
          ${c.retune_targets.length > 0 ? ` &middot; Retune: ${c.retune_targets.join(', ')}` : ''}
        </div>
      </div>
    `).join('') : '<div class="empty-state">No evaluation history</div>'}
  `;

  document.getElementById('trigger-eval').addEventListener('click', async () => {
    const btn = document.getElementById('trigger-eval');
    btn.disabled = true;
    btn.textContent = 'Triggering...';
    try {
      const res = await fetch('/api/evaluations', { method: 'POST' });
      const data = await res.json();
      btn.textContent = 'Triggered';
      setTimeout(() => renderEvaluationList(app), 1000);
    } catch {
      btn.textContent = 'Failed';
      btn.disabled = false;
    }
  });
}

export async function renderEvaluationDetail(app, cycleId) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const data = await fetch(`/api/evaluations/${cycleId}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${cycleId}</h1>
      <a href="#/evaluations" class="btn btn-secondary btn-sm">Back</a>
    </div>

    <div class="card mb-4">
      <div class="flex items-center gap-8">
        <span class="badge badge-status badge-${data.result?.status || data.request?.status}">${data.result?.status || data.request?.status || 'unknown'}</span>
        <span class="text-sm text-secondary" style="font-family:var(--font-mono)">${formatTime(data.request?.triggered_at)}</span>
      </div>
    </div>

    ${data.evaluations.length > 0 ? `
      <div class="section-label">Individual Evaluations</div>
      ${data.evaluations.map(ev => `
        <div class="card">
          <div class="card-header">
            <span>${nodeBadge(ev.evaluator)} &rarr; ${nodeBadge(ev.target)}</span>
            ${ev.needs_retuning ? '<span class="badge badge-reject">Retune recommended</span>' : ''}
          </div>
          ${ev.scores ? `
            <div class="grid-2 mt-2">
              ${Object.entries(ev.scores).map(([k, v]) => `
                <div class="text-sm">
                  <span class="text-secondary">${formatScoreLabel(k)}</span>
                  <span style="font-family:var(--font-mono); margin-left:6px;">${v}</span>
                </div>
              `).join('')}
            </div>
          ` : ''}
          <div class="text-sm text-secondary mt-2">${escapeHtml(ev.reasoning || '')}</div>
        </div>
      `).join('')}
    ` : '<div class="empty-state">No evaluation data yet</div>'}

    ${data.retunes.length > 0 ? `
      <div class="section-label" style="margin-top:20px;">Retuning</div>
      ${data.retunes.map(rt => `
        <div class="card">
          <div class="card-header">
            ${nodeBadge(rt.target)}
            <span class="badge badge-status badge-${rt.status}">${rt.status}</span>
          </div>
          <div class="text-sm text-secondary mt-2" style="font-family:var(--font-mono)">
            New params: <code>${JSON.stringify(rt.new_params)}</code>
          </div>
        </div>
      `).join('')}
    ` : ''}
  `;
}

const SCORE_LABELS = {
  decision_quality: 'Decision Quality',
  collaboration: 'Collaboration',
  effectiveness: 'Effectiveness',
  parameter_balance: 'Param Balance'
};

function formatScoreLabel(key) { return SCORE_LABELS[key] || key; }

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

import { nodeBadge } from '../components/node-badge.js';

export async function renderEvaluationList(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const cycles = await fetch('/api/evaluations').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Evaluations</h1>
      <button class="btn btn-primary" id="trigger-eval">Trigger Evaluation</button>
    </div>
    ${cycles.length > 0 ? cycles.map(c => {
      const hasRetune = c.retune_targets && c.retune_targets.some(t => t && t.length > 0);
      return `
      <div class="card clickable" onclick="location.hash='#/evaluations/${c.cycle_id}'">
        <div class="card-header">
          <span class="card-title" style="font-family:var(--font-mono)">${c.cycle_id}</span>
          <span class="badge badge-status badge-${c.status}">${c.status}</span>
          ${hasRetune ? `<span class="badge badge-reject">Retune: ${c.retune_targets.filter(t => t).join(', ')}</span>` : ''}
        </div>
        <div class="text-sm text-secondary" style="font-family:var(--font-mono)">
          ${formatTime(c.triggered_at)}
          ${c.completed_at ? ` &rarr; ${formatTime(c.completed_at)}` : ''}
        </div>
      </div>`;
    }).join('') : '<div class="empty-state">No evaluation history</div>'}
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

  // Group evaluations by target for summary
  const byTarget = {};
  for (const ev of data.evaluations) {
    if (!byTarget[ev.target]) byTarget[ev.target] = [];
    byTarget[ev.target].push(ev);
  }

  const nodeColors = { panda: '#3B82F6', gorilla: '#EF4444', triceratops: '#A855F7' };

  // Build target summary cards
  const targetSummaryHtml = Object.keys(byTarget).length > 0 ? `
    <div class="section-label">Score Summary</div>
    <div class="grid-3">
      ${Object.entries(byTarget).map(([target, evals]) => {
        const avgOverall = evals.reduce((s, e) => s + (e.overall_score || 0), 0) / evals.length;
        const color = nodeColors[target] || '#8B99B0';
        const scoreKeys = evals[0]?.scores ? Object.keys(evals[0].scores) : [];
        const avgScores = {};
        for (const k of scoreKeys) {
          const vals = evals.map(e => e.scores?.[k]).filter(v => v != null);
          avgScores[k] = vals.length > 0 ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
        }
        const retuneCount = evals.filter(e => e.needs_retuning).length;
        return `
        <div class="card">
          <div class="card-header">
            ${nodeBadge(target)}
            <span style="font-family:var(--font-mono); font-size:1.2rem; font-weight:700; color:${color};">${avgOverall.toFixed(2)}</span>
          </div>
          <div style="margin-top:10px;">
            ${scoreKeys.map(k => `
              <div style="display:flex; align-items:center; gap:6px; margin-bottom:4px;">
                <span class="text-sm text-secondary" style="width:90px; flex-shrink:0;">${formatScoreLabel(k)}</span>
                <div style="flex:1; height:6px; background:var(--bg-elevated); border-radius:3px; overflow:hidden;">
                  <div style="height:100%; width:${(avgScores[k] * 100).toFixed(0)}%; background:${color}; border-radius:3px; opacity:0.8;"></div>
                </div>
                <span class="text-sm" style="font-family:var(--font-mono); width:32px; text-align:right;">${avgScores[k].toFixed(2)}</span>
              </div>
            `).join('')}
          </div>
          ${retuneCount > 0 ? `<div style="margin-top:8px;"><span class="badge badge-reject">${retuneCount}/${evals.length} retune</span></div>` : ''}
        </div>`;
      }).join('')}
    </div>
  ` : '';

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${cycleId}</h1>
      <a href="#/evaluations" class="btn btn-secondary btn-sm">Back</a>
    </div>

    <div class="card mb-4">
      <div style="display:flex; align-items:center; gap:12px; flex-wrap:wrap;">
        <span class="badge badge-status badge-${data.result?.status || data.request?.status}">${data.result?.status || data.request?.status || 'unknown'}</span>
        <span class="text-sm text-secondary" style="font-family:var(--font-mono)">
          ${formatTime(data.request?.triggered_at)}
          ${data.result?.completed_at ? ` &rarr; ${formatTime(data.result.completed_at)}` : ''}
        </span>
        <span class="text-sm text-secondary">${data.request?.triggered_by || ''}</span>
        <span class="badge">${data.evaluations.length} evaluations</span>
      </div>
    </div>

    ${targetSummaryHtml}

    ${data.evaluations.length > 0 ? `
      <div class="section-label">Individual Evaluations</div>
      ${data.evaluations.map((ev, idx) => {
        const color = nodeColors[ev.target] || '#8B99B0';
        return `
        <div class="card">
          <div class="card-header">
            <span>${nodeBadge(ev.evaluator)} &rarr; ${nodeBadge(ev.target)}</span>
            <span style="font-family:var(--font-mono); font-weight:600;">${ev.overall_score != null ? ev.overall_score.toFixed(2) : '--'}</span>
            ${ev.needs_retuning ? '<span class="badge badge-reject">Retune</span>' : '<span class="badge badge-approve">OK</span>'}
          </div>
          ${ev.scores ? `
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px 16px; margin-top:10px;">
              ${Object.entries(ev.scores).map(([k, v]) => `
                <div style="display:flex; align-items:center; gap:6px;">
                  <span class="text-sm text-secondary" style="width:90px; flex-shrink:0;">${formatScoreLabel(k)}</span>
                  <div style="flex:1; height:4px; background:var(--bg-elevated); border-radius:2px; overflow:hidden;">
                    <div style="height:100%; width:${(v * 100).toFixed(0)}%; background:${color}; border-radius:2px; opacity:0.7;"></div>
                  </div>
                  <span class="text-sm" style="font-family:var(--font-mono); width:30px; text-align:right;">${v}</span>
                </div>
              `).join('')}
            </div>
          ` : ''}
          ${ev.needs_retuning && ev.suggested_params ? `
            <div style="margin-top:10px; padding:8px 10px; background:var(--bg-elevated); border-radius:6px;">
              <div class="text-sm text-dim" style="margin-bottom:4px;">Suggested Parameters</div>
              <div style="display:flex; gap:12px; flex-wrap:wrap;">
                ${Object.entries(ev.suggested_params).map(([k, v]) => `
                  <span class="text-sm" style="font-family:var(--font-mono);">${k}: <strong>${v}</strong></span>
                `).join('')}
              </div>
            </div>
          ` : ''}
          ${ev.reasoning ? `
            <details style="margin-top:10px;">
              <summary class="text-sm text-dim" style="cursor:pointer; user-select:none;">Reasoning</summary>
              <div class="text-sm text-secondary" style="margin-top:6px; white-space:pre-wrap; line-height:1.6;">${escapeHtml(ev.reasoning)}</div>
            </details>
          ` : ''}
        </div>`;
      }).join('')}
    ` : '<div class="empty-state">No evaluation data yet</div>'}

    ${data.retunes.length > 0 ? `
      <div class="section-label" style="margin-top:20px;">Applied Retuning</div>
      ${data.retunes.map(rt => `
        <div class="card">
          <div class="card-header">
            ${nodeBadge(rt.target)}
            <span class="badge badge-status badge-${rt.status}">${rt.status}</span>
          </div>
          <div style="margin-top:8px; padding:8px 10px; background:var(--bg-elevated); border-radius:6px;">
            <div class="text-sm text-dim" style="margin-bottom:4px;">New Parameters</div>
            <div style="display:flex; gap:12px; flex-wrap:wrap;">
              ${Object.entries(rt.new_params || {}).map(([k, v]) => `
                <span class="text-sm" style="font-family:var(--font-mono);">${k}: <strong>${v}</strong></span>
              `).join('')}
            </div>
          </div>
          ${rt.applied_at ? `<div class="text-sm text-dim" style="margin-top:6px; font-family:var(--font-mono);">Applied: ${formatTime(rt.applied_at)}</div>` : ''}
        </div>
      `).join('')}
    ` : ''}
  `;
}

const SCORE_LABELS = {
  decision_quality: 'Decision',
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

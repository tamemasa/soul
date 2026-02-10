import { nodeBadge } from '../components/node-badge.js';

export async function renderEvaluationList(app) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const cycles = await fetch('/api/evaluations').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">評価履歴</h1>
      <button class="btn btn-primary" id="trigger-eval">手動評価を発火</button>
    </div>
    ${cycles.length > 0 ? cycles.map(c => `
      <div class="card clickable" onclick="location.hash='#/evaluations/${c.cycle_id}'">
        <div class="card-header">
          <span class="card-title">${c.cycle_id}</span>
          <span class="badge badge-status badge-${c.status}">${c.status}</span>
        </div>
        <div class="text-sm text-secondary">
          ${formatTime(c.triggered_at)}
          ${c.retune_targets.length > 0 ? ` &middot; リチューニング: ${c.retune_targets.join(', ')}` : ''}
        </div>
      </div>
    `).join('') : '<div class="empty-state">評価履歴はまだありません</div>'}
  `;

  document.getElementById('trigger-eval').addEventListener('click', async () => {
    const res = await fetch('/api/evaluations', { method: 'POST' });
    const data = await res.json();
    alert(`評価サイクルを発火しました: ${data.cycle_id}`);
    renderEvaluationList(app);
  });
}

export async function renderEvaluationDetail(app, cycleId) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const data = await fetch(`/api/evaluations/${cycleId}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${cycleId}</h1>
      <a href="#/evaluations" class="btn btn-secondary btn-sm">戻る</a>
    </div>

    <div class="card mb-4">
      <div class="flex items-center gap-8">
        <span class="badge badge-status badge-${data.result?.status || data.request?.status}">${data.result?.status || data.request?.status || '不明'}</span>
        <span class="text-sm text-secondary">${formatTime(data.request?.triggered_at)}</span>
      </div>
    </div>

    ${data.evaluations.length > 0 ? `
      <h2 style="font-size:16px; margin-bottom:12px;">個別評価</h2>
      ${data.evaluations.map(ev => `
        <div class="card">
          <div class="card-header">
            <span>${nodeBadge(ev.evaluator)} → ${nodeBadge(ev.target)}</span>
            ${ev.needs_retuning ? '<span class="badge badge-reject">リチューニング推奨</span>' : ''}
          </div>
          ${ev.scores ? `
            <div class="grid-2 mt-2">
              ${Object.entries(ev.scores).map(([k, v]) => `
                <div class="text-sm">
                  <span class="text-secondary">${formatScoreLabel(k)}:</span>
                  <span style="font-family:var(--font-mono)">${v}</span>
                </div>
              `).join('')}
            </div>
          ` : ''}
          <div class="text-sm text-secondary mt-2">${escapeHtml(ev.reasoning || '')}</div>
        </div>
      `).join('')}
    ` : '<div class="empty-state">評価データはまだありません</div>'}

    ${data.retunes.length > 0 ? `
      <h2 style="font-size:16px; margin:20px 0 12px;">リチューニング</h2>
      ${data.retunes.map(rt => `
        <div class="card">
          <div class="card-header">
            ${nodeBadge(rt.target)}
            <span class="badge badge-status badge-${rt.status}">${rt.status}</span>
          </div>
          <div class="text-sm text-secondary mt-2">
            新パラメータ: <code>${JSON.stringify(rt.new_params)}</code>
          </div>
        </div>
      `).join('')}
    ` : ''}
  `;
}

const SCORE_LABELS = {
  decision_quality: '判断品質',
  collaboration: '協調性',
  effectiveness: '有効性',
  parameter_balance: 'パラメータバランス'
};

function formatScoreLabel(key) { return SCORE_LABELS[key] || key; }

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP'); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

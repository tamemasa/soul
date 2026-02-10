import { nodeBadge } from '../components/node-badge.js';

export async function renderDashboard(app) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';

  const [status, discussions, decisions] = await Promise.all([
    fetch('/api/status').then(r => r.json()),
    fetch('/api/discussions').then(r => r.json()),
    fetch('/api/decisions').then(r => r.json())
  ]);

  const recentActivity = [...discussions.slice(0, 5)];

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">ダッシュボード</h1>
    </div>

    <div class="grid-3">
      ${status.nodes.map(n => `
        <div class="card">
          <div class="card-header">
            ${nodeBadge(n.name)}
          </div>
          ${n.params ? `
            <div class="text-sm text-secondary mt-2">
              リスク: ${n.params.risk_tolerance} / 安全: ${n.params.safety_weight} / 革新: ${n.params.innovation_weight}
            </div>
          ` : ''}
        </div>
      `).join('')}
    </div>

    <div class="stats-row">
      <div class="stat-box">
        <div class="stat-value">${status.counts.pending_tasks}</div>
        <div class="stat-label">未処理タスク</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.active_discussions}</div>
        <div class="stat-label">進行中の議論</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.total_decisions}</div>
        <div class="stat-label">合意済み決定</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.workers}</div>
        <div class="stat-label">Workers</div>
      </div>
    </div>

    <h2 style="font-size:16px; margin-bottom:12px;">最近の議論</h2>
    ${recentActivity.length > 0 ? recentActivity.map(d => `
      <div class="card clickable" onclick="location.hash='#/discussions/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${escapeHtml(d.title)}</span>
          <span class="badge badge-status badge-${d.status}">${d.status}</span>
        </div>
        <div class="text-sm text-secondary">
          ラウンド ${d.current_round} &middot; ${formatTime(d.started_at)}
        </div>
      </div>
    `).join('') : '<div class="empty-state">まだ議論はありません</div>'}
  `;
}

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP'); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

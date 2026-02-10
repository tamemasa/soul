import { nodeBadge } from '../components/node-badge.js';

export async function renderDecisionList(app) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const decisions = await fetch('/api/decisions').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">決定一覧</h1>
    </div>
    ${decisions.length > 0 ? decisions.map(d => `
      <div class="card clickable" onclick="location.hash='#/decisions/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${d.task_id}</span>
          <span class="badge badge-status badge-${d.status || d.decision}">${d.status || d.decision}</span>
        </div>
        <div class="text-sm text-secondary">
          ${d.executor ? `担当: ${d.executor}` : ''} &middot; ラウンド ${d.final_round || '?'} &middot; ${formatTime(d.decided_at)}
        </div>
      </div>
    `).join('') : '<div class="empty-state">決定はまだありません</div>'}
  `;
}

export async function renderDecisionDetail(app, taskId) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const data = await fetch(`/api/decisions/${taskId}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${taskId}</h1>
      <a href="#/decisions" class="btn btn-secondary btn-sm">戻る</a>
    </div>

    <div class="card">
      <div class="flex items-center gap-8 mb-4">
        <span class="badge badge-status badge-${data.status || data.decision}">${data.decision}</span>
        ${data.executor ? nodeBadge(data.executor) : ''}
      </div>
      <div class="text-sm text-secondary">
        <div>ラウンド: ${data.final_round || '?'}</div>
        <div>決定日時: ${formatTime(data.decided_at)}</div>
        ${data.completed_at ? `<div>完了日時: ${formatTime(data.completed_at)}</div>` : ''}
      </div>
      <div class="mt-4">
        <a href="#/discussions/${taskId}" style="color: var(--node-panda); font-size: 13px;">議論の詳細を見る</a>
      </div>
    </div>

    ${data.result ? `
      <h2 style="font-size:16px; margin: 20px 0 12px;">実行結果</h2>
      <div class="result-content">${renderMarkdown(data.result)}</div>
    ` : ''}
  `;
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
  try { return new Date(ts).toLocaleString('ja-JP'); } catch { return ts; }
}

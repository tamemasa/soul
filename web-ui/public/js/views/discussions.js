import { renderTimeline } from '../components/timeline.js';
import { nodeBadge } from '../components/node-badge.js';
import { voteBadge } from '../components/vote-badge.js';

export async function renderDiscussionList(app) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const discussions = await fetch('/api/discussions').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">議論一覧</h1>
    </div>
    ${discussions.length > 0 ? discussions.map(d => `
      <div class="card clickable" onclick="location.hash='#/discussions/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${escapeHtml(d.title)}</span>
          <span class="badge badge-status badge-${d.status}">${d.status}</span>
        </div>
        <div class="text-sm text-secondary">
          ID: ${d.task_id} &middot; ラウンド ${d.current_round} &middot; ${formatTime(d.started_at)}
        </div>
      </div>
    `).join('') : '<div class="empty-state">議論はまだありません</div>'}
  `;
}

export async function renderDiscussionDetail(app, taskId) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const data = await fetch(`/api/discussions/${taskId}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  const decisionHtml = data.decision ? `
    <div class="decision-box ${data.decision.decision === 'rejected' ? 'rejected' : ''}">
      <div class="flex items-center gap-8 mb-4">
        <span style="font-weight:700; font-size:16px;">決定</span>
        <span class="badge badge-status badge-${data.decision.status || data.decision.decision}">${data.decision.decision}</span>
      </div>
      <div class="text-sm">
        <div>担当: ${nodeBadge(data.decision.executor || '未定')}</div>
        <div class="text-secondary mt-2">ラウンド ${data.decision.final_round} で合意 &middot; ${formatTime(data.decision.decided_at)}</div>
      </div>
      ${data.result?.result ? `
        <div class="mt-4">
          <div style="font-weight:600; margin-bottom:8px;">実行結果</div>
          <div class="result-content">${renderMarkdown(data.result.result)}</div>
        </div>
      ` : ''}
    </div>
  ` : '';

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(data.task?.title || taskId)}</h1>
      <a href="#/discussions" class="btn btn-secondary btn-sm">戻る</a>
    </div>

    <div class="card mb-4">
      <div class="flex items-center gap-8">
        <span class="badge badge-status badge-${data.status?.status}">${data.status?.status || '不明'}</span>
        <span class="text-sm text-secondary">ラウンド ${data.status?.current_round || 0} / ${data.status?.max_rounds || 3}</span>
      </div>
      ${data.task?.description ? `<div class="text-secondary mt-2">${escapeHtml(data.task.description)}</div>` : ''}
    </div>

    ${renderTimeline(data.rounds)}
    ${decisionHtml}
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

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

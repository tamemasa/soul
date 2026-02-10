import { nodeBadge } from './node-badge.js';
import { voteBadge } from './vote-badge.js';

export function renderTimeline(rounds) {
  if (!rounds || rounds.length === 0) return '<p class="empty-state">まだ議論が開始されていません</p>';

  return `<div class="timeline">${rounds.map(round => `
    <div class="timeline-item">
      <div class="timeline-round">ラウンド ${round.round}</div>
      ${round.responses.map(r => `
        <div class="timeline-response">
          <div class="response-header">
            ${nodeBadge(r.node)}
            ${voteBadge(r.vote)}
            <span class="text-dim text-sm">${formatTime(r.timestamp)}</span>
          </div>
          <div class="response-opinion">${escapeHtml(r.opinion || '')}</div>
          ${r.concerns && r.concerns.length ? `
            <div class="response-concerns">
              ${r.concerns.map(c => `<div class="concern-item">${escapeHtml(c)}</div>`).join('')}
            </div>
          ` : ''}
          ${r.proposed_approach ? `
            <details class="mt-2">
              <summary class="text-sm text-secondary" style="cursor:pointer">提案アプローチ</summary>
              <div class="response-opinion mt-2">${escapeHtml(r.proposed_approach)}</div>
            </details>
          ` : ''}
        </div>
      `).join('')}
    </div>
  `).join('')}</div>`;
}

function formatTime(ts) {
  if (!ts) return '';
  try {
    return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch { return ts; }
}

function escapeHtml(str) {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

import { nodeBadge } from '../components/node-badge.js';

export async function renderDashboard(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

  const [status, discussions, monitorStatus] = await Promise.all([
    fetch('/api/status').then(r => r.json()),
    fetch('/api/discussions').then(r => r.json()),
    fetch('/api/openclaw/status').then(r => r.json()).catch(() => ({ state: { status: 'unknown', check_count: 0 }, summary: {} }))
  ]);

  const monitorState = monitorStatus.state || { status: 'unknown', check_count: 0 };
  const monitorSummary = monitorStatus.summary || {};
  const bySeverity = monitorSummary.by_severity || {};
  const integrityState = monitorStatus.integrity || {};

  const recentActivity = discussions.slice(0, 5);

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Dashboard</h1>
    </div>

    <div class="grid-3">
      ${status.nodes.map(n => `
        <div class="card node-card-${n.name}">
          <div class="card-header">
            ${nodeBadge(n.name)}
            <div class="node-activity-indicator" id="activity-${n.name}">
              ${renderActivity(n.activity)}
            </div>
          </div>
          ${n.params ? `
            <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:12px;">
              <div class="text-sm"><span class="text-dim">RISK</span> <span style="font-family:var(--font-mono)">${n.params.risk_tolerance}</span></div>
              <div class="text-sm"><span class="text-dim">SAFE</span> <span style="font-family:var(--font-mono)">${n.params.safety_weight}</span></div>
              <div class="text-sm"><span class="text-dim">INNOV</span> <span style="font-family:var(--font-mono)">${n.params.innovation_weight}</span></div>
              <div class="text-sm"><span class="text-dim">FLEX</span> <span style="font-family:var(--font-mono)">${n.params.consensus_flexibility}</span></div>
            </div>
          ` : ''}
        </div>
      `).join('')}
    </div>

    <div class="stats-row">
      <div class="stat-box">
        <div class="stat-value">${status.counts.pending_tasks}</div>
        <div class="stat-label">Pending</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.active_discussions}</div>
        <div class="stat-label">Discussing</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.total_decisions}</div>
        <div class="stat-label">Decisions</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${status.counts.workers}</div>
        <div class="stat-label">Workers</div>
      </div>
    </div>

    <div class="card clickable" onclick="location.hash='#/openclaw'" style="margin-bottom:16px;">
      <div class="card-header">
        <span class="card-title">OpenClaw Monitor</span>
        <span class="badge badge-status badge-${monitorState.status === 'healthy' ? 'approved' : (monitorState.status === 'not_started' || monitorState.status === 'unknown' ? 'discussing' : 'rejected')}">${monitorState.status || 'unknown'}</span>
        ${integrityState.status === 'tampered' ? '<span class="badge badge-status badge-rejected" style="margin-left:4px;">Integrity</span>' : ''}
      </div>
      <div class="text-sm text-dim">
        Checks: ${monitorState.check_count || 0} &middot; Last: ${formatTime(monitorState.last_check_at)}
        ${bySeverity.high > 0 ? ' &middot; <span style="color:var(--error)">' + bySeverity.high + ' high</span>' : ''}
      </div>
    </div>

    <div class="section-label">Recent Activity</div>
    ${recentActivity.length > 0 ? recentActivity.map(d => `
      <div class="card clickable" onclick="location.hash='#/timeline/${d.task_id}'">
        <div class="card-header">
          <span class="card-title">${escapeHtml(d.title)}</span>
          <span class="badge badge-status badge-${d.status}">${d.status}</span>
        </div>
        <div class="text-sm text-dim" style="font-family:var(--font-mono)">
          Round ${d.current_round} &middot; ${formatTime(d.started_at)}
        </div>
      </div>
    `).join('') : '<div class="empty-state">No activity yet</div>'}
  `;
}

function renderActivity(activity) {
  if (window.__renderActivityInline) {
    return window.__renderActivityInline(activity);
  }
  if (!activity || activity.status === 'idle' || activity.status === 'offline') {
    return '<span class="activity-idle">Idle</span>';
  }
  return `<span class="activity-active">${activity.status}</span>`;
}

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

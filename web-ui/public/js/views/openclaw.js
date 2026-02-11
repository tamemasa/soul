export async function renderOpenClaw(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

  const [statusData, alerts, pendingActions, remediation, pandaStatus, pandaAlerts] = await Promise.all([
    fetch('/api/openclaw/status').then(r => r.json()),
    fetch('/api/openclaw/alerts?limit=20').then(r => r.json()),
    fetch('/api/openclaw/pending-actions').then(r => r.json()),
    fetch('/api/openclaw/remediation?limit=20').then(r => r.json()),
    fetch('/api/openclaw/panda-status').then(r => r.json()),
    fetch('/api/openclaw/panda-alerts?limit=20').then(r => r.json())
  ]);

  const state = statusData.state;
  const summary = statusData.summary;
  const pendingCount = pendingActions.filter(a => a.status === 'pending').length;

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Buddy Monitor</h1>
      <span class="badge badge-status badge-${state.status === 'healthy' ? 'approved' : (state.status === 'not_started' ? 'discussing' : 'rejected')}">${state.status || 'unknown'}</span>
    </div>

    <div class="stats-row" style="margin-top:20px;">
      <div class="stat-box">
        <div class="stat-value">${state.check_count || 0}</div>
        <div class="stat-label">Checks</div>
      </div>
      <div class="stat-box">
        <div class="stat-value ${summary.by_severity.high > 0 ? 'text-danger' : ''}">${summary.by_severity.high}</div>
        <div class="stat-label">High</div>
      </div>
      <div class="stat-box">
        <div class="stat-value ${summary.by_severity.medium > 0 ? 'text-warn' : ''}">${summary.by_severity.medium}</div>
        <div class="stat-label">Medium</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${summary.by_severity.low}</div>
        <div class="stat-label">Low</div>
      </div>
    </div>

    <div class="card" style="margin-bottom:12px;">
      <div class="card-header">
        <span class="card-title">Monitor State</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:8px;">
        <div class="text-sm"><span class="text-dim">Last Check</span> ${formatTime(state.last_check_at)}</div>
        <div class="text-sm"><span class="text-dim">Auto Remediation</span> ${state.auto_remediation ? 'Enabled' : 'Manual Approval'}</div>
        <div class="text-sm"><span class="text-dim">Manual Period Until</span> ${formatTime(state.manual_approval_until)}</div>
        <div class="text-sm"><span class="text-dim">Total Alerts</span> ${summary.total_alerts}</div>
      </div>
    </div>

    ${pendingCount > 0 ? `
      <div class="section-label">Pending Actions (${pendingCount})</div>
      ${pendingActions.filter(a => a.status === 'pending').map(a => `
        <div class="card" style="border-left:3px solid var(--warning); margin-bottom:8px;">
          <div class="card-header">
            <span class="card-title">${escapeHtml(a.action_type)}</span>
            <span class="badge badge-status badge-discussing">${a.alert_type}</span>
          </div>
          <div class="text-sm text-dim" style="margin:6px 0;">${escapeHtml(a.description)}</div>
          <div class="text-sm text-dim">${formatTime(a.created_at)}</div>
          <div style="display:flex; gap:8px; margin-top:8px;">
            <button class="btn btn-approve" onclick="approveAction('${a.id}')">Approve</button>
            <button class="btn btn-reject" onclick="rejectAction('${a.id}')">Reject</button>
          </div>
        </div>
      `).join('')}
    ` : ''}

    <div class="section-label">Recent Alerts</div>
    ${alerts.length > 0 ? alerts.map(a => `
      <div class="card" style="border-left:3px solid ${severityColor(a.severity)}; margin-bottom:6px;">
        <div class="card-header">
          <span class="text-sm" style="color:${severityColor(a.severity)}; font-weight:600;">${a.severity.toUpperCase()}</span>
          <span class="badge badge-status">${a.type}</span>
        </div>
        <div class="text-sm" style="margin:4px 0;">${escapeHtml(a.description)}</div>
        <div class="text-sm text-dim">${formatTime(a.timestamp)}</div>
      </div>
    `).join('') : '<div class="empty-state">No alerts</div>'}

    ${remediation.length > 0 ? `
      <div class="section-label">Remediation Log</div>
      ${remediation.map(r => `
        <div class="card" style="margin-bottom:6px;">
          <div class="card-header">
            <span class="text-sm">${escapeHtml(r.action)}</span>
            <span class="badge badge-status">${r.remediation_type}</span>
          </div>
          <div class="text-sm text-dim">${escapeHtml(r.description)} &middot; ${formatTime(r.timestamp)}</div>
        </div>
      `).join('')}
    ` : ''}

    <div class="section-label" style="margin-top:24px;">Panda Policy Monitor</div>
    <div class="card" style="margin-bottom:12px;">
      <div class="card-header">
        <span class="card-title">Policy Compliance</span>
        <span class="badge badge-status badge-${pandaStatus.status === 'healthy' ? 'approved' : (pandaStatus.status === 'not_started' ? 'discussing' : 'rejected')}">${pandaStatus.status || 'not started'}</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:8px;">
        <div class="text-sm"><span class="text-dim">Last Check</span> ${formatTime(pandaStatus.last_check_at)}</div>
        <div class="text-sm"><span class="text-dim">Check Count</span> ${pandaStatus.check_count || 0}</div>
        <div class="text-sm"><span class="text-dim">Interval</span> ${pandaStatus.interval_seconds ? (pandaStatus.interval_seconds / 60) + 'min' : '5min'}</div>
        <div class="text-sm"><span class="text-dim">Messages Tracked</span> ${pandaStatus.last_message_count || 0}</div>
      </div>
    </div>

    ${pandaAlerts.length > 0 ? `
      <div class="section-label">Panda Alerts</div>
      ${pandaAlerts.map(a => `
        <div class="card" style="border-left:3px solid ${severityColor(a.severity)}; margin-bottom:6px;">
          <div class="card-header">
            <span class="text-sm" style="color:${severityColor(a.severity)}; font-weight:600;">${(a.severity || 'info').toUpperCase()}</span>
            <span class="badge badge-status">${a.type}</span>
          </div>
          <div class="text-sm" style="margin:4px 0;">${escapeHtml(a.description)}</div>
          <div class="text-sm text-dim">${formatTime(a.timestamp)}</div>
        </div>
      `).join('')}
    ` : '<div class="empty-state" style="margin-bottom:12px;">No panda alerts</div>'}
  `;

}

// Global action handlers
window.approveAction = async function(id) {
  if (!confirm('Are you sure you want to approve this action?')) return;
  await fetch(`/api/openclaw/pending-actions/${id}/approve`, { method: 'POST' });
  location.hash = '#/openclaw'; // refresh
  setTimeout(() => { const app = document.getElementById('app'); renderOpenClaw(app); }, 100);
};

window.rejectAction = async function(id) {
  if (!confirm('Reject this action?')) return;
  await fetch(`/api/openclaw/pending-actions/${id}/reject`, { method: 'POST' });
  location.hash = '#/openclaw';
  setTimeout(() => { const app = document.getElementById('app'); renderOpenClaw(app); }, 100);
};

function severityColor(severity) {
  switch (severity) {
    case 'high': return 'var(--error, #ef4444)';
    case 'medium': return 'var(--warning, #f59e0b)';
    case 'low': return 'var(--text-dim, #6b7280)';
    default: return 'var(--text-dim)';
  }
}

function formatTime(ts) {
  if (!ts) return '-';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Unified OpenClaw Monitor Dashboard
// Consolidates policy, security, and integrity monitoring into a single view

let currentFilter = 'all'; // all, policy, security, integrity

export async function renderOpenClaw(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

  const [statusData, alerts, pendingActions, remediation, integrity] = await Promise.all([
    fetch('/api/openclaw/status').then(r => r.json()),
    fetch('/api/openclaw/alerts?limit=30').then(r => r.json()),
    fetch('/api/openclaw/pending-actions').then(r => r.json()),
    fetch('/api/openclaw/remediation?limit=20').then(r => r.json()),
    fetch('/api/openclaw/integrity').then(r => r.json()).catch(() => ({ status: 'unknown' }))
  ]);

  const state = statusData.state || {};
  const summary = statusData.summary || {};
  const bySeverity = summary.by_severity || {};
  const byCategory = summary.by_category || {};
  const buddyState = statusData.buddy_state;
  const pendingCount = pendingActions.filter(a => a.status === 'pending').length;

  // Filter alerts by category
  const filteredAlerts = currentFilter === 'all'
    ? alerts
    : alerts.filter(a => (a.category || 'policy') === currentFilter);

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">OpenClaw Monitor</h1>
      <span class="badge badge-status badge-${statusBadge(state.status)}">${state.status || 'unknown'}</span>
      ${state.parallel_mode ? '<span class="badge badge-status badge-discussing" style="margin-left:6px;">Parallel Mode</span>' : ''}
    </div>

    <!-- Category Status Indicators -->
    <div class="stats-row" style="margin-top:16px;">
      <div class="stat-box" style="border-top:3px solid var(--primary, #3b82f6);">
        <div class="stat-value">${byCategory.policy || 0}</div>
        <div class="stat-label">Policy</div>
      </div>
      <div class="stat-box" style="border-top:3px solid var(--error, #ef4444);">
        <div class="stat-value">${byCategory.security || 0}</div>
        <div class="stat-label">Security</div>
      </div>
      <div class="stat-box" style="border-top:3px solid var(--warning, #f59e0b);">
        <div class="stat-value">${integrityDisplay(integrity)}</div>
        <div class="stat-label">Integrity</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${state.check_count || 0}</div>
        <div class="stat-label">Checks</div>
      </div>
    </div>

    <!-- Severity Summary -->
    <div class="stats-row" style="margin-top:8px;">
      <div class="stat-box">
        <div class="stat-value ${bySeverity.high > 0 ? 'text-danger' : ''}">${bySeverity.high || 0}</div>
        <div class="stat-label">High</div>
      </div>
      <div class="stat-box">
        <div class="stat-value ${bySeverity.medium > 0 ? 'text-warn' : ''}">${bySeverity.medium || 0}</div>
        <div class="stat-label">Medium</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${bySeverity.low || 0}</div>
        <div class="stat-label">Low</div>
      </div>
      <div class="stat-box">
        <div class="stat-value">${summary.total_alerts || 0}</div>
        <div class="stat-label">Total</div>
      </div>
    </div>

    <!-- Monitor State -->
    <div class="card" style="margin-top:12px; margin-bottom:12px;">
      <div class="card-header">
        <span class="card-title">Monitor State</span>
        <span class="badge badge-status">${state.monitor_type || 'unified'}</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:8px;">
        <div class="text-sm"><span class="text-dim">Last Check</span> ${formatTime(state.last_check_at)}</div>
        <div class="text-sm"><span class="text-dim">Interval</span> ${state.interval_seconds ? (state.interval_seconds / 60) + 'min' : '5min'}</div>
        <div class="text-sm"><span class="text-dim">Messages</span> ${state.last_message_count || 0}</div>
        <div class="text-sm"><span class="text-dim">Operator</span> Panda</div>
      </div>
    </div>

    <!-- Personality Integrity Card -->
    <div class="card" style="margin-bottom:12px; border-left:3px solid ${integrity.status === 'ok' ? 'var(--success, #22c55e)' : (integrity.status === 'tampered' ? 'var(--error, #ef4444)' : 'var(--text-dim)')};">
      <div class="card-header">
        <span class="card-title">Personality Integrity</span>
        <span class="badge badge-status badge-${integrity.status === 'ok' ? 'approved' : (integrity.status === 'tampered' ? 'rejected' : 'discussing')}">${integrity.status || 'unknown'}</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:8px;">
        <div class="text-sm"><span class="text-dim">SOUL.md</span> ${integrity.soul_md_hash ? integrity.soul_md_hash.substring(0, 8) + '...' : '-'}</div>
        <div class="text-sm"><span class="text-dim">AGENTS.md</span> ${integrity.agents_md_hash ? integrity.agents_md_hash.substring(0, 8) + '...' : '-'}</div>
        <div class="text-sm"><span class="text-dim">Last Verified</span> ${formatTime(integrity.checked_at)}</div>
        ${integrity.last_issue ? `<div class="text-sm text-danger">${escapeHtml(integrity.last_issue)}</div>` : ''}
      </div>
    </div>

    ${buddyState ? `
    <!-- Legacy Buddy State (parallel mode) -->
    <div class="card" style="margin-bottom:12px; opacity:0.7;">
      <div class="card-header">
        <span class="card-title">Buddy Monitor (Legacy)</span>
        <span class="badge badge-status badge-${statusBadge(buddyState.status)}">${buddyState.status || 'unknown'}</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-top:8px;">
        <div class="text-sm"><span class="text-dim">Last Check</span> ${formatTime(buddyState.last_check_at)}</div>
        <div class="text-sm"><span class="text-dim">Check Count</span> ${buddyState.check_count || 0}</div>
      </div>
    </div>
    ` : ''}

    <!-- Pending Actions -->
    ${pendingCount > 0 ? `
      <div class="section-label">Pending Actions (${pendingCount})</div>
      ${pendingActions.filter(a => a.status === 'pending').map(a => `
        <div class="card" style="border-left:3px solid var(--warning); margin-bottom:8px;">
          <div class="card-header">
            <span class="card-title">${escapeHtml(a.action_type)}</span>
            <span class="badge badge-status badge-discussing">${escapeHtml(a.alert_type)}</span>
            ${a.category ? `<span class="badge badge-status">${a.category}</span>` : ''}
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

    <!-- Alert Filter -->
    <div class="section-label" style="display:flex; align-items:center; gap:8px;">
      <span>Alerts</span>
      <div style="display:flex; gap:4px; margin-left:auto;">
        ${['all', 'policy', 'security', 'integrity'].map(cat => `
          <button class="btn ${currentFilter === cat ? 'btn-approve' : ''}"
                  style="padding:2px 8px; font-size:11px;"
                  onclick="window.__filterAlerts('${cat}')">${cat}</button>
        `).join('')}
      </div>
    </div>

    ${filteredAlerts.length > 0 ? filteredAlerts.map(a => `
      <div class="card" style="border-left:3px solid ${severityColor(a.severity)}; margin-bottom:6px;">
        <div class="card-header">
          <span class="text-sm" style="color:${severityColor(a.severity)}; font-weight:600;">${(a.severity || 'info').toUpperCase()}</span>
          <span class="badge badge-status">${escapeHtml(a.type || '')}</span>
          ${a.category ? `<span class="badge badge-status" style="opacity:0.7;">${a.category}</span>` : ''}
        </div>
        <div class="text-sm" style="margin:4px 0;">${escapeHtml(a.description || '')}</div>
        <div class="text-sm text-dim">${formatTime(a.timestamp)}</div>
      </div>
    `).join('') : '<div class="empty-state">No alerts</div>'}

    ${remediation.length > 0 ? `
      <div class="section-label">Remediation Log</div>
      ${remediation.map(r => `
        <div class="card" style="margin-bottom:6px;">
          <div class="card-header">
            <span class="text-sm">${escapeHtml(r.action || '')}</span>
            <span class="badge badge-status">${escapeHtml(r.remediation_type || '')}</span>
          </div>
          <div class="text-sm text-dim">${escapeHtml(r.description || '')} &middot; ${formatTime(r.timestamp)}</div>
        </div>
      `).join('')}
    ` : ''}
  `;
}

// Alert filter handler
window.__filterAlerts = function(category) {
  currentFilter = category;
  const app = document.getElementById('app');
  renderOpenClaw(app);
};

// Global action handlers
window.approveAction = async function(id) {
  if (!confirm('Are you sure you want to approve this action?')) return;
  await fetch(`/api/openclaw/pending-actions/${id}/approve`, { method: 'POST' });
  location.hash = '#/openclaw';
  setTimeout(() => { const app = document.getElementById('app'); renderOpenClaw(app); }, 100);
};

window.rejectAction = async function(id) {
  if (!confirm('Reject this action?')) return;
  await fetch(`/api/openclaw/pending-actions/${id}/reject`, { method: 'POST' });
  location.hash = '#/openclaw';
  setTimeout(() => { const app = document.getElementById('app'); renderOpenClaw(app); }, 100);
};

function statusBadge(status) {
  if (status === 'healthy' || status === 'ok') return 'approved';
  if (status === 'not_started' || status === 'unknown') return 'discussing';
  return 'rejected';
}

function integrityDisplay(integrity) {
  if (!integrity || integrity.status === 'unknown') return '?';
  if (integrity.status === 'ok') return 'OK';
  return '!!';
}

function severityColor(severity) {
  switch (severity) {
    case 'high': case 'critical': return 'var(--error, #ef4444)';
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

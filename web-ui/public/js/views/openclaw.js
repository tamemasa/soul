// Unified OpenClaw Monitor Dashboard
// Consolidates policy, security, and integrity monitoring + conversation log + avatar

import { renderAvatar, getEmotionLabel } from '../components/openclaw-avatar.js';

let currentFilter = 'all'; // all, policy, security, integrity
let currentTab = 'monitoring'; // 'monitoring' | 'conversations'
let currentEmotion = 'idle';
let conversationFilter = { platform: 'all', direction: 'all', search: '' };
let loadedMessages = [];
let oldestTimestamp = null;
let hasMore = false;

export async function renderOpenClaw(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

  // Fetch emotion state alongside other data
  const [statusData, alerts, pendingActions, remediation, integrity, researchRequests, emotionData] = await Promise.all([
    fetch('/api/openclaw/status').then(r => r.json()),
    fetch('/api/openclaw/alerts?limit=30').then(r => r.json()),
    fetch('/api/openclaw/pending-actions').then(r => r.json()),
    fetch('/api/openclaw/remediation?limit=20').then(r => r.json()),
    fetch('/api/openclaw/integrity').then(r => r.json()).catch(() => ({ status: 'unknown' })),
    fetch('/api/openclaw/research-requests').then(r => r.json()).catch(() => []),
    fetch('/api/openclaw/emotion-state').then(r => r.json()).catch(() => ({ emotion: 'idle', source: 'default', last_message_at: null, monitor_status: 'unknown' }))
  ]);

  currentEmotion = emotionData.emotion || 'idle';

  const state = statusData.state || {};
  const summary = statusData.summary || {};
  const bySeverity = summary.by_severity || {};
  const byCategory = summary.by_category || {};
  const pendingCount = pendingActions.filter(a => a.status === 'pending').length;

  // Filter alerts by category
  const filteredAlerts = currentFilter === 'all'
    ? alerts
    : alerts.filter(a => (a.category || 'policy') === currentFilter);

  const lastActiveAgo = emotionData.last_message_at ? formatRelativeTime(emotionData.last_message_at) : '-';

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">OpenClaw Monitor</h1>
      <span class="badge badge-status badge-${statusBadge(state.status)}">${state.status || 'unknown'}</span>
    </div>

    <!-- Avatar Section -->
    <div class="avatar-section">
      ${renderAvatar(currentEmotion)}
      <div class="avatar-status">
        <div class="avatar-emotion-label">${getEmotionLabel(currentEmotion)}</div>
        <div class="text-sm text-dim">Source: ${emotionData.source || 'default'}</div>
      </div>
      <div class="avatar-meta">
        <span>Last active: ${lastActiveAgo}</span>
        <span>Monitor: ${emotionData.monitor_status || 'unknown'}</span>
      </div>
    </div>

    <!-- Tabs -->
    <div class="tabs">
      <button class="tab ${currentTab === 'monitoring' ? 'active' : ''}" onclick="window.__switchOpenClawTab('monitoring')">モニタリング</button>
      <button class="tab ${currentTab === 'conversations' ? 'active' : ''}" onclick="window.__switchOpenClawTab('conversations')">会話ログ</button>
    </div>

    <!-- Tab Content -->
    <div id="openclaw-tab-content">
      ${currentTab === 'monitoring'
        ? renderMonitoringTab(state, summary, bySeverity, byCategory, pendingCount, pendingActions, filteredAlerts, remediation, researchRequests, integrity)
        : '<div class="loading"><div class="spinner"></div></div>'}
    </div>
  `;

  // Load conversations if on conversations tab
  if (currentTab === 'conversations') {
    await loadConversations();
  }
}

function renderMonitoringTab(state, summary, bySeverity, byCategory, pendingCount, pendingActions, filteredAlerts, remediation, researchRequests, integrity) {
  return `
    <!-- Monitor Summary -->
    <div class="text-sm text-dim" style="display:flex; gap:12px; flex-wrap:wrap; align-items:center;">
      <span>Last: ${formatTime(state.last_check_at)}</span>
      <span>ポリシー: 5min / フル: 10min</span>
      <span>Checks: ${state.check_count || 0}</span>
      <span>Operator: Panda</span>
      <button id="btn-force-check" class="btn" style="padding:2px 10px; font-size:11px; margin-left:auto;"
              onclick="window.__triggerManualCheck()">手動チェック実行</button>
    </div>

    <!-- Check Results -->
    <div class="stats-row" style="margin-top:16px;">
      <div class="stat-box" style="border-top:3px solid var(--primary, #3b82f6);">
        <div class="stat-value">${byCategory.policy || 0}</div>
        <div class="stat-label">Policy</div>
      </div>
      <div class="stat-box" style="border-top:3px solid var(--error, #ef4444);">
        <div class="stat-value">${byCategory.security || 0}</div>
        <div class="stat-label">Security</div>
      </div>
      <div class="stat-box" style="border-top:3px solid ${integrity.status === 'ok' ? 'var(--success, #22c55e)' : (integrity.status === 'tampered' ? 'var(--error, #ef4444)' : 'var(--warning, #f59e0b)')};">
        <div class="stat-value">${integrityDisplay(integrity)}</div>
        <div class="stat-label">Integrity</div>
        ${integrity.status !== 'unknown' ? `<div class="text-sm text-dim" style="font-size:10px; margin-top:2px;">${formatTime(integrity.checked_at)}</div>` : ''}
      </div>
      <div class="stat-box">
        <div class="stat-value">${summary.total_alerts || 0}</div>
        <div class="stat-label">Alerts</div>
      </div>
    </div>

    <!-- Alert Severity -->
    ${(summary.total_alerts || 0) > 0 ? `
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

    <!-- Research Requests -->
    <div class="section-label">Research Requests (${researchRequests.length})</div>
    ${researchRequests.length > 0 ? researchRequests.map(r => `
      <div class="card" style="border-left:3px solid ${researchPhaseBorderColor(r.phase)}; margin-bottom:8px;">
        <div class="card-header">
          <span class="card-title">${escapeHtml((r.title || '').replace('[OpenClaw Research] ', ''))}</span>
          <span class="badge badge-status badge-${researchPhaseBadge(r.phase)}">${r.phase}</span>
          ${r.request_type ? `<span class="badge badge-status">${r.request_type}</span>` : ''}
        </div>
        <div class="text-sm text-dim" style="margin:4px 0;">${escapeHtml(truncate(r.description || '', 150))}</div>
        <div class="text-sm text-dim" style="display:flex; gap:12px;">
          <span>${formatTime(r.created_at)}</span>
          ${r.id ? `<a href="#/discussions/${r.id}" style="color:var(--primary);">詳細</a>` : ''}
        </div>
        ${r.result && r.result.summary ? `
          <div style="margin-top:8px; padding:8px; background:var(--bg-secondary); border-radius:4px;">
            <div class="text-sm" style="font-weight:600; margin-bottom:4px;">結果</div>
            <div class="text-sm">${escapeHtml(truncate(r.result.summary || r.result.result || '', 300))}</div>
          </div>
        ` : ''}
      </div>
    `).join('') : '<div class="empty-state">No research requests</div>'}
  `;
}

async function loadConversations(append) {
  if (!append) {
    loadedMessages = [];
    oldestTimestamp = null;
    hasMore = false;
  }

  const params = new URLSearchParams({ limit: '100' });
  if (conversationFilter.platform !== 'all') params.set('platform', conversationFilter.platform);
  if (oldestTimestamp && append) params.set('before', oldestTimestamp);

  try {
    const data = await fetch(`/api/openclaw/conversations?${params}`).then(r => r.json());
    if (append) {
      loadedMessages.push(...data.messages);
    } else {
      loadedMessages = data.messages;
    }
    hasMore = data.has_more;
    oldestTimestamp = data.oldest_timestamp;
  } catch {
    loadedMessages = [];
    hasMore = false;
  }

  renderConversationTab();
}

function renderConversationTab() {
  const container = document.getElementById('openclaw-tab-content');
  if (!container) return;

  // Apply client-side filters
  let filtered = loadedMessages;
  if (conversationFilter.direction !== 'all') {
    filtered = filtered.filter(m => m.direction === conversationFilter.direction);
  }
  if (conversationFilter.search) {
    const q = conversationFilter.search.toLowerCase();
    filtered = filtered.filter(m => (m.content || '').toLowerCase().includes(q));
  }

  container.innerHTML = `
    <!-- Filter Bar -->
    <div class="conv-filter-bar">
      <div class="conv-filter-group">
        ${['all', 'line', 'discord'].map(p => `
          <button class="conv-filter-btn ${conversationFilter.platform === p ? 'active' : ''}"
                  onclick="window.__convFilterPlatform('${p}')">${p === 'all' ? 'All' : p.charAt(0).toUpperCase() + p.slice(1)}</button>
        `).join('')}
      </div>
      <div class="conv-filter-group">
        ${[['all', 'All'], ['inbound', '受信'], ['outbound', '送信']].map(([v, l]) => `
          <button class="conv-filter-btn ${conversationFilter.direction === v ? 'active' : ''}"
                  onclick="window.__convFilterDirection('${v}')">${l}</button>
        `).join('')}
      </div>
      <input type="text" class="conv-search" placeholder="検索..."
             value="${escapeHtml(conversationFilter.search)}"
             oninput="window.__convFilterSearch(this.value)" />
    </div>

    <!-- Messages -->
    ${filtered.length > 0 ? filtered.map(m => renderMessageCard(m)).join('') : '<div class="empty-state">会話データがまだありません</div>'}

    ${hasMore ? '<button class="conv-load-more" onclick="window.__convLoadMore()">さらに読み込む</button>' : ''}
  `;
}

function renderMessageCard(m) {
  const platformBadge = m.platform === 'line'
    ? '<span class="badge badge-line">LINE</span>'
    : '<span class="badge badge-discord">Discord</span>';
  const dirLabel = m.direction === 'inbound' ? '受信' : '送信';
  const emotionBadge = m.direction === 'outbound' && m.emotion_hint
    ? `<span class="conv-emotion">${escapeHtml(m.emotion_hint)}</span>`
    : '';

  return `
    <div class="conv-message ${m.direction}">
      <div class="conv-header">
        ${platformBadge}
        <span class="conv-user">${escapeHtml(m.user || 'unknown')}</span>
        <span class="conv-direction">(${dirLabel})</span>
        ${emotionBadge}
        <span class="conv-time">${formatMessageTime(m.timestamp)}</span>
      </div>
      <div class="conv-body">${escapeHtml(m.content || '')}</div>
    </div>
  `;
}

// Tab switch handler
window.__switchOpenClawTab = function(tab) {
  currentTab = tab;
  const app = document.getElementById('app');
  renderOpenClaw(app);
};

// Conversation filter handlers
window.__convFilterPlatform = function(platform) {
  conversationFilter.platform = platform;
  loadConversations();
};

window.__convFilterDirection = function(direction) {
  conversationFilter.direction = direction;
  renderConversationTab();
};

window.__convFilterSearch = function(search) {
  conversationFilter.search = search;
  renderConversationTab();
};

window.__convLoadMore = function() {
  loadConversations(true);
};

// Refresh avatar emotion state (works regardless of active tab)
async function refreshAvatarEmotion() {
  try {
    const emotionData = await fetch('/api/openclaw/emotion-state').then(r => r.json());
    currentEmotion = emotionData.emotion || 'idle';
    const avatarContainer = document.querySelector('.avatar-section');
    if (avatarContainer) {
      const lastActiveAgo = emotionData.last_message_at ? formatRelativeTime(emotionData.last_message_at) : '-';
      avatarContainer.innerHTML = `
        ${renderAvatar(currentEmotion)}
        <div class="avatar-status">
          <div class="avatar-emotion-label">${getEmotionLabel(currentEmotion)}</div>
          <div class="text-sm text-dim">Source: ${emotionData.source || 'default'}</div>
        </div>
        <div class="avatar-meta">
          <span>Last active: ${lastActiveAgo}</span>
          <span>Monitor: ${emotionData.monitor_status || 'unknown'}</span>
        </div>
      `;
    }
  } catch { /* ignore */ }
}

// Refresh conversations (called from SSE handler)
window.__refreshOpenClawConversations = async function() {
  // Always refresh avatar emotion, even when on monitoring tab
  await refreshAvatarEmotion();

  if (currentTab === 'conversations') {
    await loadConversations();
  }
};

// 手動チェックトリガーハンドラー (60秒クールダウン)
let __forceCheckCooldown = false;
window.__triggerManualCheck = async function() {
  if (__forceCheckCooldown) return;
  const btn = document.getElementById('btn-force-check');
  if (!btn) return;
  btn.disabled = true;
  btn.textContent = '実行中...';
  __forceCheckCooldown = true;
  try {
    const res = await fetch('/api/openclaw/trigger-check', { method: 'POST' });
    if (res.ok) {
      btn.textContent = 'トリガー済み';
    } else {
      const data = await res.json();
      btn.textContent = data.error || 'エラー';
    }
  } catch (e) {
    btn.textContent = 'エラー';
  }
  setTimeout(() => {
    __forceCheckCooldown = false;
    if (btn) { btn.disabled = false; btn.textContent = '手動チェック実行'; }
  }, 60000);
};

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

function formatMessageTime(ts) {
  if (!ts) return '-';
  try {
    const d = new Date(ts);
    const now = new Date();
    if (d.toDateString() === now.toDateString()) {
      return d.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' });
    }
    return d.toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch { return ts; }
}

function formatRelativeTime(ts) {
  if (!ts) return '-';
  try {
    const diff = Date.now() - new Date(ts).getTime();
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) return 'just now';
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return `${days}d ago`;
  } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function truncate(str, maxLen) {
  if (!str || str.length <= maxLen) return str || '';
  return str.slice(0, maxLen) + '...';
}

function researchPhaseBorderColor(phase) {
  switch (phase) {
    case 'completed': case 'archived': return 'var(--success, #22c55e)';
    case 'decided': return 'var(--primary, #3b82f6)';
    case 'discussing': return 'var(--warning, #f59e0b)';
    case 'inbox': return 'var(--text-dim, #6b7280)';
    default: return 'var(--text-dim)';
  }
}

function researchPhaseBadge(phase) {
  switch (phase) {
    case 'completed': case 'archived': return 'approved';
    case 'decided': return 'approved';
    case 'discussing': return 'discussing';
    case 'inbox': return 'discussing';
    default: return 'discussing';
  }
}

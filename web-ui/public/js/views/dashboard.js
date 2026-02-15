import { nodeBadge } from '../components/node-badge.js';

// Track Chart.js instances for destroy/recreate
let cpuTempChart = null;
let memDiskChart = null;
let tokenCostChart = null;

export async function renderDashboard(app) {
  const isRerender = !!app.querySelector('.page-title');
  const prevScrollY = isRerender ? window.scrollY : -1;
  if (!isRerender) {
    app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  }

  const [status, discussions, monitorStatus, broadcastStatus, personalityData, metrics, tokenUsage, latestEval] = await Promise.all([
    fetch('/api/status').then(r => r.json()),
    fetch('/api/discussions').then(r => r.json()),
    fetch('/api/openclaw/status').then(r => r.json()).catch(() => ({ state: { status: 'unknown', check_count: 0 }, summary: {} })),
    fetch('/api/broadcast/status').then(r => r.json()).catch(() => ({ broadcast: { status: 'not_started' }, engine: {}, trigger: null })),
    fetch('/api/personality/history').then(r => r.json()).catch(() => ({ trigger: null, cycles: [] })),
    fetch('/api/metrics').then(r => r.json()).catch(() => []),
    fetch('/api/token-usage').then(r => r.json()).catch(() => ({ today: { total_input: 0, total_output: 0, total_cost: 0, by_node: {} }, daily: [], budget: null })),
    fetch('/api/evaluations/latest').then(r => r.json()).catch(() => null)
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
      <div class="stat-box">
        <div class="stat-value">${status.counts.archived_tasks || 0}</div>
        <div class="stat-label">Archived</div>
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

    ${renderPersonalityCard(personalityData)}

    ${renderEvaluationCard(latestEval)}

    ${renderBroadcastSection(broadcastStatus)}

    ${renderTokenUsageSection(tokenUsage)}

    ${renderMetricsSection(metrics)}

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

  if (prevScrollY >= 0) {
    window.scrollTo(0, prevScrollY);
  }

  attachBroadcastTrigger();
  attachPlanSelect();
  renderMetricsCharts(metrics);
  renderTokenCostChart(tokenUsage);
}

function renderPersonalityCard(pd) {
  const trigger = pd.trigger;
  const cycles = pd.cycles || [];
  const latest = cycles[0];

  const statusLabel = trigger ? trigger.status : 'unknown';
  const statusBadge = statusLabel === 'completed' ? 'approved'
    : statusLabel === 'error' ? 'rejected'
    : 'discussing';

  return `
    <div class="card clickable" onclick="location.hash='#/personality'" style="margin-bottom:16px;">
      <div class="card-header">
        <span class="card-title">Personality Improvement</span>
        <span class="badge badge-status badge-${statusBadge}">${statusLabel}</span>
        <span class="badge">${cycles.length} cycles</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:12px;">
        <div class="text-sm"><span class="text-dim">Last</span> ${trigger ? formatTime(trigger.updated_at) : '--'}</div>
        <div class="text-sm"><span class="text-dim">By</span> ${trigger ? trigger.triggered_by || '--' : '--'}</div>
      </div>
      ${latest ? `<div class="text-sm text-secondary" style="margin-top:8px;">${escapeHtml(truncateSummary(latest.summary, 100))}</div>` : ''}
    </div>`;
}

function renderEvaluationCard(ev) {
  if (!ev) return '';

  const statusBadge = ev.status === 'completed' ? 'approved'
    : ev.status === 'pending' ? 'discussing'
    : ev.status === 'in_progress' ? 'discussing'
    : 'rejected';

  const nodeColors = { panda: '#3B82F6', gorilla: '#EF4444', triceratops: '#A855F7' };
  const nodeNames = Object.keys(ev.summary || {});

  const scoreRows = nodeNames.map(node => {
    const s = ev.summary[node];
    const overall = s.overall != null ? s.overall.toFixed(2) : '--';
    const color = nodeColors[node] || '#8B99B0';
    return `
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:4px;">
        <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:${color};"></span>
        <span class="text-sm" style="width:80px;">${node}</span>
        <span style="font-family:var(--font-mono); font-size:0.9rem; font-weight:600;">${overall}</span>
        <div style="flex:1; height:4px; background:var(--bg-elevated); border-radius:2px; overflow:hidden;">
          <div style="height:100%; width:${s.overall != null ? (s.overall * 100) : 0}%; background:${color}; border-radius:2px;"></div>
        </div>
      </div>`;
  }).join('');

  const hasRetune = ev.retune_targets && ev.retune_targets.some(t => t && t.length > 0);

  return `
    <div class="card clickable" onclick="location.hash='#/evaluations/${ev.cycle_id}'" style="margin-bottom:16px;">
      <div class="card-header">
        <span class="card-title">Evaluation</span>
        <span class="badge badge-status badge-${statusBadge}">${ev.status}</span>
        <span class="badge">${ev.evaluation_count || 0} reviews</span>
        ${hasRetune ? '<span class="badge badge-reject">Retuned</span>' : ''}
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:12px;">
        <div class="text-sm"><span class="text-dim">Triggered</span> ${formatTime(ev.triggered_at)}</div>
        <div class="text-sm"><span class="text-dim">Completed</span> ${formatTime(ev.completed_at)}</div>
      </div>
      ${nodeNames.length > 0 ? `
        <div style="margin-top:12px;">
          <div class="text-sm text-dim" style="margin-bottom:6px;">Average Scores</div>
          ${scoreRows}
        </div>
      ` : ''}
    </div>`;
}

function truncateSummary(str, max) {
  if (!str || str.length <= max) return str || '';
  return str.substring(0, max) + '...';
}

function renderBroadcastSection(bs) {
  const broadcast = bs.broadcast || {};
  const engine = bs.engine || {};
  const trigger = bs.trigger || {};

  const statusLabel = broadcast.status || 'not_started';
  const statusBadge = statusLabel === 'completed' ? 'approved'
    : statusLabel === 'delivering' ? 'discussing'
    : statusLabel === 'scheduled' ? 'discussing'
    : statusLabel === 'error' ? 'rejected'
    : 'discussing';

  const nextScheduled = broadcast.next_scheduled_at
    ? formatTime(broadcast.next_scheduled_at)
    : '--';
  const lastDelivered = broadcast.last_delivered_at
    ? formatTime(broadcast.last_delivered_at)
    : '--';

  const deliveryResults = (broadcast.last_deliveries || []).map(d =>
    `<span class="badge badge-status badge-${d.status === 'success' ? 'approved' : d.status === 'dryrun' ? 'discussing' : 'rejected'}" style="margin-right:4px;">${d.destination}: ${d.status}</span>`
  ).join('');

  const destinations = trigger.destinations
    ? trigger.destinations.join(', ')
    : '--';

  const activeChats = broadcast.active_chats != null ? broadcast.active_chats : '--';

  return `
    <div class="card" style="margin-bottom:16px;">
      <div class="card-header">
        <span class="card-title">Info Broadcast</span>
        <span class="badge badge-status badge-${statusBadge}">${statusLabel}</span>
        <span class="badge" style="margin-left:4px;">${engine.mode || 'unknown'}</span>
      </div>
      <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:12px;">
        <div class="text-sm"><span class="text-dim">Next</span> ${nextScheduled}</div>
        <div class="text-sm"><span class="text-dim">Last</span> ${lastDelivered}</div>
        <div class="text-sm"><span class="text-dim">Window</span> ${trigger.window || '--'}</div>
        <div class="text-sm"><span class="text-dim">Dest</span> ${destinations}</div>
        <div class="text-sm"><span class="text-dim">Active</span> ${activeChats} chats</div>
      </div>
      ${deliveryResults ? `<div style="margin-top:8px;">${deliveryResults}</div>` : ''}
      <div style="margin-top:12px;">
        <button class="btn btn-primary" id="broadcast-trigger-btn" style="font-size:0.85rem; padding:6px 16px;">
          Trigger Now
        </button>
      </div>
    </div>`;
}

function attachBroadcastTrigger() {
  const btn = document.getElementById('broadcast-trigger-btn');
  if (!btn) return;
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    btn.textContent = 'Triggering...';
    try {
      const res = await fetch('/api/broadcast/trigger', { method: 'POST' });
      const data = await res.json();
      if (res.ok) {
        btn.textContent = 'Triggered!';
        setTimeout(() => { btn.textContent = 'Trigger Now'; btn.disabled = false; }, 3000);
      } else {
        btn.textContent = data.error || 'Error';
        setTimeout(() => { btn.textContent = 'Trigger Now'; btn.disabled = false; }, 3000);
      }
    } catch {
      btn.textContent = 'Error';
      setTimeout(() => { btn.textContent = 'Trigger Now'; btn.disabled = false; }, 3000);
    }
  });
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

function formatTokenCount(n) {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

function formatCost(usd) {
  if (usd >= 1) return '$' + usd.toFixed(2);
  if (usd >= 0.01) return '$' + usd.toFixed(3);
  return '$' + usd.toFixed(4);
}

function renderSubscriptionGauges(sub) {
  if (!sub) return '';

  const planOptions = [
    { key: 'pro', label: 'Pro ($20/mo)' },
    { key: 'max_5x', label: 'Max 5x ($100/mo)' },
    { key: 'max_20x', label: 'Max 20x ($200/mo)' }
  ];

  const weeklyPct = Math.min(sub.weekly.pct, 100);
  const dailyPct = Math.min(sub.daily.pct, 100);
  const gaugeColor = pct => pct > 85 ? 'var(--error)' : pct > 60 ? 'var(--warning)' : 'var(--success)';

  let recommendHtml = '';
  if (sub.recommended) {
    const r = sub.recommended;
    recommendHtml = `
      <div class="plan-recommendation">
        <span class="text-sm" style="color:var(--success); font-weight:600;">Recommended: ${r.label} ($${r.price_usd}/mo)</span>
        <span class="text-sm text-secondary" style="margin-left:8px;">${escapeHtml(r.reason)}</span>
      </div>`;
  }

  return `
    <div class="subscription-header">
      <span class="text-sm text-dim">Subscription Plan</span>
      <select class="plan-select" id="plan-select">
        ${planOptions.map(p => `<option value="${p.key}" ${p.key === sub.plan ? 'selected' : ''}>${p.label}</option>`).join('')}
      </select>
    </div>
    <div class="subscription-gauges">
      <div class="gauge-card">
        <div class="text-sm" style="display:flex; justify-content:space-between; margin-bottom:6px;">
          <span class="text-dim">Weekly Remaining</span>
          <span style="font-family:var(--font-mono); font-size:12px;">${formatTokenCount(sub.weekly.used)} / ${formatTokenCount(sub.weekly.limit)}</span>
        </div>
        <div class="gauge-bar">
          <div class="gauge-bar-fill" style="width:${weeklyPct.toFixed(1)}%; background:${gaugeColor(weeklyPct)};"></div>
        </div>
        <div class="text-sm text-dim" style="margin-top:4px; text-align:right;">
          ${formatTokenCount(sub.weekly.remaining)} remaining (${weeklyPct.toFixed(1)}% used)
        </div>
      </div>
      <div class="gauge-card">
        <div class="text-sm" style="display:flex; justify-content:space-between; margin-bottom:6px;">
          <span class="text-dim">Daily Remaining</span>
          <span style="font-family:var(--font-mono); font-size:12px;">${formatTokenCount(sub.daily.used)} / ${formatTokenCount(sub.daily.limit)}</span>
        </div>
        <div class="gauge-bar">
          <div class="gauge-bar-fill" style="width:${dailyPct.toFixed(1)}%; background:${gaugeColor(dailyPct)};"></div>
        </div>
        <div class="text-sm text-dim" style="margin-top:4px; text-align:right;">
          ${formatTokenCount(sub.daily.remaining)} remaining (${dailyPct.toFixed(1)}% used)
        </div>
      </div>
    </div>
    ${recommendHtml}`;
}

function attachPlanSelect() {
  const sel = document.getElementById('plan-select');
  if (!sel) return;
  sel.addEventListener('change', async () => {
    const plan = sel.value;
    sel.disabled = true;
    try {
      const res = await fetch('/api/subscription', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ plan })
      });
      if (!res.ok) throw new Error('Failed');
      // Re-render dashboard
      const app = document.getElementById('app');
      if (app) {
        const { renderDashboard } = await import('./dashboard.js');
        renderDashboard(app);
      }
    } catch {
      sel.disabled = false;
    }
  });
}

function renderTokenUsageSection(tu) {
  const today = tu.today || {};
  const budget = tu.budget;
  const sub = tu.subscription;
  const totalTokens = (today.total_input || 0) + (today.total_output || 0);

  let budgetHtml = '';
  if (budget) {
    const pct = Math.min(budget.usage_pct || 0, 100);
    const barColor = pct >= 95 ? 'var(--error)' : pct >= 80 ? 'var(--warning)' : 'var(--success)';
    budgetHtml = `
      <div style="margin-top:12px;">
        <div class="text-sm" style="display:flex; justify-content:space-between; margin-bottom:4px;">
          <span class="text-dim">Monthly Budget</span>
          <span style="font-family:var(--font-mono)">${formatCost(budget.monthly_spent_usd)} / ${formatCost(budget.monthly_budget_usd)}</span>
        </div>
        <div style="height:6px; background:var(--bg-elevated); border-radius:3px; overflow:hidden;">
          <div style="height:100%; width:${pct.toFixed(1)}%; background:${barColor}; border-radius:3px; transition:width 0.3s ease;"></div>
        </div>
        <div class="text-sm text-dim" style="margin-top:4px; text-align:right;">
          ${formatCost(budget.monthly_remaining_usd)} remaining (${pct.toFixed(1)}% used)
        </div>
      </div>`;
  }

  // Node breakdown
  const byNode = today.by_node || {};
  const nodeNames = Object.keys(byNode);
  const nodeColors = { panda: '#3B82F6', gorilla: '#EF4444', triceratops: '#A855F7' };
  const nodeBreakdown = nodeNames.length > 0
    ? `<div style="display:flex; gap:12px; margin-top:8px; flex-wrap:wrap;">
        ${nodeNames.map(n => `
          <div class="text-sm">
            <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:${nodeColors[n] || '#8B99B0'}; margin-right:4px;"></span>
            <span class="text-dim">${n}</span>
            <span style="font-family:var(--font-mono)">${formatCost(byNode[n].cost)}</span>
          </div>
        `).join('')}
      </div>`
    : '';

  return `
    <div class="section-label">Token Usage</div>
    ${renderSubscriptionGauges(sub)}
    <div class="stats-row">
      <div class="stat-box">
        <div class="stat-value" style="color:#60A5FA">${formatTokenCount(totalTokens)}</div>
        <div class="stat-label">Today Total</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#34D399">${formatTokenCount(today.total_input || 0)}</div>
        <div class="stat-label">Input</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#A855F7">${formatTokenCount(today.total_output || 0)}</div>
        <div class="stat-label">Output</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#F59E0B">${formatCost(today.total_cost || 0)}</div>
        <div class="stat-label">Cost</div>
      </div>
    </div>
    ${nodeBreakdown}
    ${budgetHtml}
    <div class="metrics-chart-container" style="margin-top:12px;">
      <div class="metrics-chart-title">Daily Token Cost (7 days)</div>
      <canvas id="chart-token-cost"></canvas>
    </div>`;
}

function renderTokenCostChart(tu) {
  const daily = (tu && tu.daily) || [];
  if (daily.length === 0) return;
  if (typeof Chart === 'undefined') return;

  if (tokenCostChart) { tokenCostChart.destroy(); tokenCostChart = null; }

  const ctx = document.getElementById('chart-token-cost');
  if (!ctx) return;

  const labels = daily.map(d => d.date);
  const gridColor = 'rgba(30,41,59,0.7)';
  const tickColor = '#4B5972';

  tokenCostChart = new Chart(ctx, {
    type: 'bar',
    data: {
      labels,
      datasets: [
        {
          label: 'Input Tokens',
          data: daily.map(d => d.input),
          backgroundColor: 'rgba(52,211,153,0.7)',
          borderColor: '#34D399',
          borderWidth: 1,
          yAxisID: 'y'
        },
        {
          label: 'Output Tokens',
          data: daily.map(d => d.output),
          backgroundColor: 'rgba(168,85,247,0.7)',
          borderColor: '#A855F7',
          borderWidth: 1,
          yAxisID: 'y'
        },
        {
          label: 'Cost (USD)',
          data: daily.map(d => d.cost),
          type: 'line',
          borderColor: '#F59E0B',
          backgroundColor: 'rgba(245,158,11,0.1)',
          borderWidth: 2,
          pointRadius: 3,
          pointBackgroundColor: '#F59E0B',
          fill: false,
          tension: 0.3,
          yAxisID: 'y1'
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: {
          labels: { color: '#8B99B0', font: { size: 11 }, boxWidth: 12, padding: 12 }
        },
        tooltip: {
          backgroundColor: '#1A2332',
          titleColor: '#E8EDF5',
          bodyColor: '#8B99B0',
          borderColor: '#1E293B',
          borderWidth: 1,
          padding: 10,
          callbacks: {
            label: function(context) {
              if (context.dataset.yAxisID === 'y1') {
                return context.dataset.label + ': $' + context.parsed.y.toFixed(4);
              }
              return context.dataset.label + ': ' + formatTokenCount(context.parsed.y);
            }
          }
        }
      },
      scales: {
        x: {
          stacked: true,
          grid: { color: gridColor },
          ticks: { color: tickColor, font: { size: 10 } }
        },
        y: {
          stacked: true,
          position: 'left',
          grid: { color: gridColor },
          ticks: {
            color: tickColor,
            font: { size: 10 },
            callback: v => formatTokenCount(v)
          }
        },
        y1: {
          position: 'right',
          grid: { drawOnChartArea: false },
          ticks: {
            color: '#F59E0B',
            font: { size: 10 },
            callback: v => '$' + v.toFixed(2)
          }
        }
      }
    }
  });
}

function renderMetricsSection(metrics) {
  if (!metrics || metrics.length === 0) {
    return '';
  }

  const latest = metrics[metrics.length - 1];

  return `
    <div class="section-label">Host Metrics</div>
    <div class="stats-row">
      <div class="stat-box">
        <div class="stat-value" style="color:#60A5FA">${latest.cpu}%</div>
        <div class="stat-label">CPU</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#A855F7">${latest.mem_pct}%</div>
        <div class="stat-label">RAM</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#34D399">${latest.disk_pct}%</div>
        <div class="stat-label">Disk</div>
      </div>
      <div class="stat-box">
        <div class="stat-value" style="color:#F59E0B">${latest.temp}&deg;C</div>
        <div class="stat-label">Temp</div>
      </div>
    </div>
    <div class="grid-2">
      <div class="metrics-chart-container">
        <div class="metrics-chart-title">CPU & Temperature</div>
        <canvas id="chart-cpu-temp"></canvas>
      </div>
      <div class="metrics-chart-container">
        <div class="metrics-chart-title">Memory & Disk</div>
        <canvas id="chart-mem-disk"></canvas>
      </div>
    </div>`;
}

function renderMetricsCharts(metrics) {
  if (!metrics || metrics.length === 0) return;
  if (typeof Chart === 'undefined') return;

  // Destroy previous instances
  if (cpuTempChart) { cpuTempChart.destroy(); cpuTempChart = null; }
  if (memDiskChart) { memDiskChart.destroy(); memDiskChart = null; }

  const labels = metrics.map(m => new Date(m.timestamp));

  const chartDefaults = {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { mode: 'index', intersect: false },
    plugins: {
      legend: {
        labels: { color: '#8B99B0', font: { size: 11 }, boxWidth: 12, padding: 12 }
      },
      tooltip: {
        backgroundColor: '#1A2332',
        titleColor: '#E8EDF5',
        bodyColor: '#8B99B0',
        borderColor: '#1E293B',
        borderWidth: 1,
        padding: 10
      }
    }
  };

  const gridColor = 'rgba(30,41,59,0.7)';
  const tickColor = '#4B5972';

  // --- CPU + Temp chart (dual Y axis) ---
  const ctxCpu = document.getElementById('chart-cpu-temp');
  if (ctxCpu) {
    cpuTempChart = new Chart(ctxCpu, {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'CPU %',
            data: metrics.map(m => m.cpu),
            borderColor: '#60A5FA',
            backgroundColor: 'rgba(96,165,250,0.1)',
            borderWidth: 2,
            pointRadius: 0,
            fill: true,
            tension: 0.3,
            yAxisID: 'y'
          },
          {
            label: 'Temp \u00B0C',
            data: metrics.map(m => m.temp),
            borderColor: '#F59E0B',
            backgroundColor: 'rgba(245,158,11,0.1)',
            borderWidth: 2,
            pointRadius: 0,
            fill: false,
            tension: 0.3,
            yAxisID: 'y1'
          }
        ]
      },
      options: {
        ...chartDefaults,
        scales: {
          x: {
            type: 'time',
            time: { tooltipFormat: 'HH:mm', displayFormats: { hour: 'HH:mm', minute: 'HH:mm' } },
            grid: { color: gridColor },
            ticks: { color: tickColor, font: { size: 10 }, maxTicksLimit: 8 }
          },
          y: {
            position: 'left',
            min: 0, max: 100,
            grid: { color: gridColor },
            ticks: { color: '#60A5FA', font: { size: 10 }, callback: v => v + '%' }
          },
          y1: {
            position: 'right',
            min: 30, max: 90,
            grid: { drawOnChartArea: false },
            ticks: { color: '#F59E0B', font: { size: 10 }, callback: v => v + '\u00B0' }
          }
        }
      }
    });
  }

  // --- Memory + Disk chart ---
  const ctxMem = document.getElementById('chart-mem-disk');
  if (ctxMem) {
    memDiskChart = new Chart(ctxMem, {
      type: 'line',
      data: {
        labels,
        datasets: [
          {
            label: 'Memory %',
            data: metrics.map(m => m.mem_pct),
            borderColor: '#A855F7',
            backgroundColor: 'rgba(168,85,247,0.1)',
            borderWidth: 2,
            pointRadius: 0,
            fill: true,
            tension: 0.3
          },
          {
            label: 'Disk %',
            data: metrics.map(m => m.disk_pct),
            borderColor: '#34D399',
            backgroundColor: 'rgba(52,211,153,0.1)',
            borderWidth: 2,
            pointRadius: 0,
            fill: true,
            tension: 0.3
          }
        ]
      },
      options: {
        ...chartDefaults,
        scales: {
          x: {
            type: 'time',
            time: { tooltipFormat: 'HH:mm', displayFormats: { hour: 'HH:mm', minute: 'HH:mm' } },
            grid: { color: gridColor },
            ticks: { color: tickColor, font: { size: 10 }, maxTicksLimit: 8 }
          },
          y: {
            min: 0, max: 100,
            grid: { color: gridColor },
            ticks: { color: tickColor, font: { size: 10 }, callback: v => v + '%' }
          }
        }
      }
    });
  }
}

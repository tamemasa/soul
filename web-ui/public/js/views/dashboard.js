import { nodeBadge } from '../components/node-badge.js';

// Track Chart.js instances for destroy/recreate
let cpuTempChart = null;
let memDiskChart = null;

export async function renderDashboard(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

  const [status, discussions, monitorStatus, broadcastStatus, metrics] = await Promise.all([
    fetch('/api/status').then(r => r.json()),
    fetch('/api/discussions').then(r => r.json()),
    fetch('/api/openclaw/status').then(r => r.json()).catch(() => ({ state: { status: 'unknown', check_count: 0 }, summary: {} })),
    fetch('/api/broadcast/status').then(r => r.json()).catch(() => ({ broadcast: { status: 'not_started' }, engine: {}, trigger: null })),
    fetch('/api/metrics').then(r => r.json()).catch(() => [])
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

    ${renderBroadcastSection(broadcastStatus)}

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

  attachBroadcastTrigger();
  renderMetricsCharts(metrics);
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

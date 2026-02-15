import { renderNav } from './components/nav.js';
import { renderDashboard } from './views/dashboard.js';
import { renderTaskForm } from './views/task-form.js';
import { renderTimelineList, renderDiscussionDetail } from './views/discussions.js';
import { renderParams } from './views/params.js';
import { renderEvaluationList, renderEvaluationDetail } from './views/evaluations.js';
import { renderPersonalityList, renderPersonalityDetail } from './views/personality.js';
import { renderLogs } from './views/logs.js';
import { renderOpenClaw } from './views/openclaw.js';

const app = document.getElementById('app');

// Simple hash router
async function route() {
  const hash = location.hash.slice(1) || '/dashboard';
  const parts = hash.split('/').filter(Boolean);
  const path = '/' + parts[0];

  renderNav(hash);

  // Only remove detail-view class when navigating away from detail pages
  const isDetailRoute = (['timeline', 'discussions', 'decisions'].includes(parts[0]) && parts[1]);
  if (!isDetailRoute) {
    app.classList.remove('detail-view');
  }

  try {
    switch (path) {
      case '/dashboard':
        await renderDashboard(app);
        break;
      case '/tasks':
        await renderTaskForm(app);
        break;
      case '/timeline':
      case '/discussions':
        if (parts[1]) {
          await renderDiscussionDetail(app, parts[1]);
        } else {
          await renderTimelineList(app);
        }
        break;
      case '/decisions':
        if (parts[1]) {
          await renderDiscussionDetail(app, parts[1]);
        } else {
          await renderTimelineList(app);
        }
        break;
      case '/params':
        await renderParams(app);
        break;
      case '/evaluations':
        if (parts[1]) {
          await renderEvaluationDetail(app, parts[1]);
        } else {
          await renderEvaluationList(app);
        }
        break;
      case '/personality':
        if (parts[1]) {
          await renderPersonalityDetail(app, parts[1]);
        } else {
          await renderPersonalityList(app);
        }
        break;
      case '/logs':
        await renderLogs(app);
        break;
      case '/openclaw':
        await renderOpenClaw(app);
        break;
      default:
        await renderDashboard(app);
    }
  } catch (err) {
    app.innerHTML = `<div class="empty-state">Error: ${err.message}</div>`;
  }
}

// Debounce for SSE-triggered re-renders
let _refreshTimer = null;
function debouncedRoute(delay = 1000) {
  if (_refreshTimer) clearTimeout(_refreshTimer);
  _refreshTimer = setTimeout(() => { _refreshTimer = null; route(); }, delay);
}

// SSE for real-time updates
let eventSource = null;
function connectSSE() {
  eventSource = new EventSource('/api/events');
  eventSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'connected') return;

      const hash = location.hash.slice(1) || '/dashboard';

      // Activity changes: update dashboard inline or refresh discussions
      if (data.type === 'activity:changed') {
        if (hash.startsWith('/dashboard')) {
          updateActivityBadges();
          return;
        }
        if (hash.startsWith('/timeline') || hash.startsWith('/discussions')) {
          updateActivityBadges();
          return;
        }
        return;
      }

      // OpenClaw conversation updates: targeted refresh instead of full re-render
      if (hash.startsWith('/openclaw') && data.type === 'conversation:updated') {
        if (window.__refreshOpenClawConversations) {
          window.__refreshOpenClawConversations();
        }
        return;
      }

      const parts2 = hash.split('/').filter(Boolean);
      const isDetailView = (parts2[0] === 'timeline' || parts2[0] === 'discussions' || parts2[0] === 'decisions') && parts2[1];
      const isDiscussionEvent = data.type === 'discussion:updated' || data.type === 'decision:updated';

      // Detail view: skip SSE re-renders entirely — status polling handles in-place updates
      if (isDetailView && isDiscussionEvent) {
        return;
      }

      // Full re-render for other events (debounced)
      const shouldRefresh =
        (hash.startsWith('/dashboard') && (isDiscussionEvent || data.type === 'metrics:updated' || data.type === 'task:created' || data.type === 'task:updated')) ||
        (hash.startsWith('/timeline') && isDiscussionEvent) ||
        (hash.startsWith('/discussions') && isDiscussionEvent) ||
        (hash.startsWith('/decisions') && data.type === 'decision:updated') ||
        (hash.startsWith('/params') && data.type === 'params:changed') ||
        (hash.startsWith('/evaluations') && data.type === 'evaluation:updated') ||
        (hash.startsWith('/personality') && data.type === 'personality:updated');
      if (shouldRefresh) {
        debouncedRoute();
      }
    } catch { /* ignore parse errors */ }
  };
  eventSource.onerror = () => {
    eventSource.close();
    setTimeout(connectSSE, 5000);
  };
}

// Lightweight activity badge update (no full re-render)
async function updateActivityBadges() {
  try {
    const activities = await fetch('/api/activity').then(r => r.json());
    for (const [node, activity] of Object.entries(activities)) {
      const el = document.getElementById(`activity-${node}`);
      if (el) {
        el.innerHTML = renderActivityInline(activity);
      }
    }
  } catch { /* ignore */ }
}

function renderActivityInline(activity) {
  if (!activity || activity.status === 'idle' || activity.status === 'offline') {
    return '<span class="activity-idle">Idle</span>';
  }
  const labels = {
    discussing: 'Discussing',
    announcing: 'Announcing',
    executing: 'Executing',
    evaluating: 'Evaluating',
    broadcasting_news: 'Broadcasting',
    generating_suggestion: 'Suggesting'
  };
  const label = labels[activity.status] || activity.status;
  const detail = activity.task_id ? activity.task_id.replace('task_', '').substring(0, 10) : (activity.target || '');
  return `<span class="activity-active">${label}</span>${detail ? `<span class="activity-detail">${detail}</span>` : ''}`;
}

// Expose for dashboard.js
window.__renderActivityInline = renderActivityInline;

// Init
window.addEventListener('hashchange', route);
route();
connectSSE();

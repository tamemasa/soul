import { renderNav } from './components/nav.js';
import { renderDashboard } from './views/dashboard.js';
import { renderTaskForm } from './views/task-form.js';
import { renderDiscussionList, renderDiscussionDetail } from './views/discussions.js';
import { renderDecisionList, renderDecisionDetail } from './views/decisions.js';
import { renderParams } from './views/params.js';
import { renderEvaluationList, renderEvaluationDetail } from './views/evaluations.js';
import { renderLogs } from './views/logs.js';

const app = document.getElementById('app');

// Simple hash router
async function route() {
  const hash = location.hash.slice(1) || '/dashboard';
  const parts = hash.split('/').filter(Boolean);
  const path = '/' + parts[0];

  renderNav(hash);

  try {
    switch (path) {
      case '/dashboard':
        await renderDashboard(app);
        break;
      case '/tasks':
        await renderTaskForm(app);
        break;
      case '/discussions':
        if (parts[1]) {
          await renderDiscussionDetail(app, parts[1]);
        } else {
          await renderDiscussionList(app);
        }
        break;
      case '/decisions':
        if (parts[1]) {
          await renderDecisionDetail(app, parts[1]);
        } else {
          await renderDecisionList(app);
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
      case '/logs':
        await renderLogs(app);
        break;
      default:
        await renderDashboard(app);
    }
  } catch (err) {
    app.innerHTML = `<div class="empty-state">エラーが発生しました: ${err.message}</div>`;
  }
}

// SSE for real-time updates
let eventSource = null;
function connectSSE() {
  eventSource = new EventSource('/api/events');
  eventSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'connected') return;
      // Re-render current view on relevant changes
      const hash = location.hash.slice(1) || '/dashboard';
      const shouldRefresh =
        (hash.startsWith('/dashboard')) ||
        (hash.startsWith('/discussions') && data.type === 'discussion:updated') ||
        (hash.startsWith('/decisions') && data.type === 'decision:updated') ||
        (hash.startsWith('/params') && data.type === 'params:changed') ||
        (hash.startsWith('/evaluations') && data.type === 'evaluation:updated');
      if (shouldRefresh) {
        route();
      }
    } catch { /* ignore parse errors */ }
  };
  eventSource.onerror = () => {
    eventSource.close();
    setTimeout(connectSSE, 5000);
  };
}

// Init
window.addEventListener('hashchange', route);
route();
connectSSE();

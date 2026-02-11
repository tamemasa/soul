// Minimal SVG icons (stroke-based, 18x18)
const ICONS = {
  dashboard: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="2" width="5.5" height="5.5" rx="1"/><rect x="10.5" y="2" width="5.5" height="5.5" rx="1"/><rect x="2" y="10.5" width="5.5" height="5.5" rx="1"/><rect x="10.5" y="10.5" width="5.5" height="5.5" rx="1"/></svg>',
  task: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="9" cy="9" r="7"/><path d="M9 5v4l3 2"/></svg>',
  discussion: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 4h12a1 1 0 011 1v6a1 1 0 01-1 1H6l-3 3V5a1 1 0 011-1z"/></svg>',
  decision: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M5 9l3 3 5-6"/><circle cx="9" cy="9" r="7"/></svg>',
  params: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 5h12M3 9h12M3 13h12"/><circle cx="6" cy="5" r="1.5" fill="currentColor"/><circle cx="12" cy="9" r="1.5" fill="currentColor"/><circle cx="8" cy="13" r="1.5" fill="currentColor"/></svg>',
  evaluation: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 14V8l3-3 3 4 3-6 3 5v6z"/></svg>',
  logs: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 4h10M4 7h7M4 10h10M4 13h5"/></svg>',
  buddy: '<svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M9 2a4 4 0 014 4c0 2-2 3-4 5-2-2-4-3-4-5a4 4 0 014-4z"/><path d="M4 14c0-2.2 2.2-4 5-4s5 1.8 5 4"/></svg>'
};

const NAV_ITEMS = [
  { path: '/dashboard', icon: 'dashboard', label: 'Dashboard' },
  { path: '/tasks/new', icon: 'task', label: 'New Task' },
  { path: '/timeline', icon: 'discussion', label: 'Timeline' },
  { path: '/params', icon: 'params', label: 'Parameters' },
  { path: '/evaluations', icon: 'evaluation', label: 'Evaluations' },
  { path: '/logs', icon: 'logs', label: 'Logs' },
  { path: '/openclaw', icon: 'buddy', label: 'Buddy' }
];

export function renderNav(currentPath) {
  const container = document.getElementById('nav-links');
  container.innerHTML = NAV_ITEMS.map(item => {
    const active = currentPath === item.path
      || (item.path === '/dashboard' && currentPath === '/')
      || (item.path === '/timeline' && (currentPath.startsWith('/timeline') || currentPath.startsWith('/discussions') || currentPath.startsWith('/decisions')))
      || (item.path === '/openclaw' && currentPath.startsWith('/openclaw'));
    return `<a class="nav-item ${active ? 'active' : ''}" href="#${item.path}">
      <span class="nav-icon">${ICONS[item.icon]}</span>
      <span class="nav-text">${item.label}</span>
    </a>`;
  }).join('');
}

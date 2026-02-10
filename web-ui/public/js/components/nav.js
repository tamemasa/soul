const NAV_ITEMS = [
  { path: '/dashboard', icon: '\u{1F4CA}', label: '\u30C0\u30C3\u30B7\u30E5\u30DC\u30FC\u30C9' },
  { path: '/tasks/new', icon: '\u{2795}', label: '\u30BF\u30B9\u30AF\u6295\u5165' },
  { path: '/discussions', icon: '\u{1F4AC}', label: '\u8B70\u8AD6' },
  { path: '/decisions', icon: '\u{2705}', label: '\u6C7A\u5B9A' },
  { path: '/params', icon: '\u{2699}\uFE0F', label: '\u30D1\u30E9\u30E1\u30FC\u30BF' },
  { path: '/evaluations', icon: '\u{1F4CB}', label: '\u8A55\u4FA1' },
  { path: '/logs', icon: '\u{1F4DD}', label: '\u30ED\u30B0' }
];

export function renderNav(currentPath) {
  const container = document.getElementById('nav-links');
  container.innerHTML = NAV_ITEMS.map(item => {
    const active = currentPath === item.path || (item.path === '/dashboard' && currentPath === '/');
    return `<a class="nav-item ${active ? 'active' : ''}" href="#${item.path}">
      <span class="nav-icon">${item.icon}</span>
      <span class="nav-text">${item.label}</span>
    </a>`;
  }).join('');
}

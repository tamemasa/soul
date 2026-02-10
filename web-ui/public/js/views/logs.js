const ALL_NODES = ['panda', 'gorilla', 'triceratops', 'scheduler'];
const NODE_COLORS = {
  panda: 'var(--node-panda)',
  gorilla: 'var(--node-gorilla)',
  triceratops: 'var(--node-triceratops)',
  scheduler: 'var(--status-pending)'
};

export async function renderLogs(app) {
  const dates = await fetch('/api/logs').then(r => r.json());
  const today = dates[0] || new Date().toISOString().split('T')[0];

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">ログビューア</h1>
      <select class="form-select" id="log-date" style="width:auto;">
        ${dates.map(d => `<option value="${d}" ${d === today ? 'selected' : ''}>${d}</option>`).join('')}
        ${dates.length === 0 ? `<option value="${today}">${today}</option>` : ''}
      </select>
    </div>

    <div class="tabs" id="log-tabs">
      ${ALL_NODES.map((n, i) => `
        <button class="tab ${i === 0 ? 'active' : ''}" data-node="${n}"
          style="${i === 0 ? `border-bottom: 2px solid ${NODE_COLORS[n]}` : ''}">${n}</button>
      `).join('')}
    </div>

    <div class="flex items-center gap-8 mb-4">
      <span class="text-sm text-secondary">表示行数:</span>
      <select class="form-select" id="log-lines" style="width:auto;">
        <option value="30">30</option>
        <option value="50" selected>50</option>
        <option value="100">100</option>
        <option value="200">200</option>
      </select>
      <button class="btn btn-sm btn-secondary" id="log-refresh">更新</button>
    </div>

    <div class="log-content" id="log-content">ログを読み込み中...</div>
  `;

  let currentNode = ALL_NODES[0];

  async function loadLog() {
    const date = document.getElementById('log-date').value;
    const lines = document.getElementById('log-lines').value;
    const el = document.getElementById('log-content');
    try {
      const data = await fetch(`/api/logs/${date}/${currentNode}?lines=${lines}`).then(r => r.json());
      el.textContent = data.content || '(ログなし)';
      el.scrollTop = el.scrollHeight;
    } catch {
      el.textContent = '(ログを取得できません)';
    }
  }

  // Tab click
  document.getElementById('log-tabs').addEventListener('click', (e) => {
    const btn = e.target.closest('.tab');
    if (!btn) return;
    currentNode = btn.dataset.node;
    document.querySelectorAll('#log-tabs .tab').forEach(t => {
      t.classList.remove('active');
      t.style.borderBottom = '';
    });
    btn.classList.add('active');
    btn.style.borderBottom = `2px solid ${NODE_COLORS[currentNode]}`;
    loadLog();
  });

  document.getElementById('log-date').addEventListener('change', loadLog);
  document.getElementById('log-lines').addEventListener('change', loadLog);
  document.getElementById('log-refresh').addEventListener('click', loadLog);

  loadLog();
}

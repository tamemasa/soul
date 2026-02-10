const PARAM_LABELS = {
  risk_tolerance: 'リスク許容度',
  innovation_weight: '革新性の重み',
  safety_weight: '安全性の重み',
  thoroughness: '検証の徹底度',
  consensus_flexibility: '合意への柔軟性'
};

const NODE_COLORS = {
  panda: 'var(--node-panda)',
  gorilla: 'var(--node-gorilla)',
  triceratops: 'var(--node-triceratops)'
};

export async function renderParams(app) {
  app.innerHTML = '<div class="loading">読み込み中...</div>';
  const nodes = await fetch('/api/nodes').then(r => r.json());

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">パラメータ管理</h1>
    </div>

    <div class="grid-3">
      ${nodes.map(node => `
        <div class="card" id="params-${node.name}">
          <div class="card-header">
            <span class="badge badge-node badge-${node.name}">${node.name}</span>
            <button class="btn btn-sm btn-secondary" onclick="saveParams('${node.name}')">保存</button>
          </div>
          <div class="mt-4">
            ${Object.entries(node.params || {}).map(([key, val]) => `
              <div class="param-row">
                <span class="param-label">${PARAM_LABELS[key] || key}</span>
                <input type="range" class="param-slider" min="0" max="1" step="0.05" value="${val}"
                  data-node="${node.name}" data-key="${key}"
                  style="accent-color: ${NODE_COLORS[node.name]}"
                  oninput="this.nextElementSibling.textContent = this.value">
                <span class="param-value">${val}</span>
              </div>
            `).join('')}
          </div>
          <div id="save-result-${node.name}" class="mt-2 text-sm"></div>
        </div>
      `).join('')}
    </div>

    <h2 style="font-size:16px; margin: 20px 0 12px;">パラメータ比較</h2>
    <div class="card">
      <table style="width:100%; font-size:13px; border-collapse:collapse;">
        <thead>
          <tr>
            <th style="text-align:left; padding:8px; border-bottom:1px solid var(--border);">パラメータ</th>
            ${nodes.map(n => `<th style="text-align:center; padding:8px; border-bottom:1px solid var(--border); color:${NODE_COLORS[n.name]}">${n.name}</th>`).join('')}
          </tr>
        </thead>
        <tbody>
          ${Object.keys(PARAM_LABELS).map(key => `
            <tr>
              <td style="padding:8px; border-bottom:1px solid var(--border);">${PARAM_LABELS[key]}</td>
              ${nodes.map(n => {
                const val = n.params?.[key] ?? '-';
                return `<td style="text-align:center; padding:8px; border-bottom:1px solid var(--border); font-family:var(--font-mono);">${val}</td>`;
              }).join('')}
            </tr>
          `).join('')}
        </tbody>
      </table>
    </div>
  `;

  // Make saveParams available globally
  window.saveParams = async (name) => {
    const sliders = document.querySelectorAll(`input[data-node="${name}"]`);
    const params = {};
    sliders.forEach(s => { params[s.dataset.key] = parseFloat(s.value); });

    try {
      await fetch(`/api/nodes/${name}/params`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(params)
      });
      const el = document.getElementById(`save-result-${name}`);
      el.style.color = 'var(--vote-approve)';
      el.textContent = '保存しました';
      setTimeout(() => { el.textContent = ''; }, 3000);
    } catch (err) {
      const el = document.getElementById(`save-result-${name}`);
      el.style.color = 'var(--vote-reject)';
      el.textContent = 'エラー: ' + err.message;
    }
  };
}

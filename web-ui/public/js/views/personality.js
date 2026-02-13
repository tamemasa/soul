export async function renderPersonalityList(app) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const data = await fetch('/api/personality/history').then(r => r.json());
  const trigger = data.trigger;
  const cycles = data.cycles || [];

  const statusBadge = trigger
    ? `<span class="badge badge-status badge-${statusClass(trigger.status)}">${trigger.status}</span>`
    : '<span class="badge badge-status badge-discussing">unknown</span>';

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">Personality Improvement</h1>
      ${statusBadge}
    </div>

    ${trigger ? `
      <div class="card" style="margin-bottom:16px;">
        <div class="card-header">
          <span class="card-title">Current Status</span>
        </div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:8px;">
          <div class="text-sm"><span class="text-dim">Triggered</span> ${formatTime(trigger.triggered_at)}</div>
          <div class="text-sm"><span class="text-dim">Updated</span> ${formatTime(trigger.updated_at)}</div>
          <div class="text-sm"><span class="text-dim">By</span> ${trigger.triggered_by || '--'}</div>
          <div class="text-sm"><span class="text-dim">Detail</span> ${escapeHtml(trigger.detail || '--')}</div>
        </div>
      </div>
    ` : ''}

    <div class="section-label">History (${cycles.length} cycles)</div>
    ${cycles.length > 0 ? cycles.map(c => `
      <div class="card clickable" onclick="location.hash='#/personality/${c.id}'">
        <div class="card-header">
          <span class="card-title text-sm" style="font-family:var(--font-mono)">${c.id}</span>
          <span class="badge">${c.changes_count} changes</span>
        </div>
        <div class="text-sm text-secondary" style="margin-top:6px;">
          ${escapeHtml(truncate(c.summary, 120))}
        </div>
        <div class="text-sm text-dim" style="margin-top:4px; font-family:var(--font-mono);">
          ${formatTime(c.timestamp)} &middot; ${c.files_changed.join(', ')}
        </div>
      </div>
    `).join('') : '<div class="empty-state">No improvement history yet</div>'}
  `;
}

export async function renderPersonalityDetail(app, id) {
  app.innerHTML = '<div class="loading"><div class="spinner"></div></div>';
  const data = await fetch(`/api/personality/history/${id}`).then(r => r.json());

  if (data.error) {
    app.innerHTML = `<div class="empty-state">${data.error}</div>`;
    return;
  }

  const { history, answers, pending } = data;

  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title" style="font-family:var(--font-mono)">${id}</h1>
      <a href="#/personality" class="btn btn-secondary btn-sm">Back</a>
    </div>

    <div class="card mb-4">
      <div class="flex items-center gap-8">
        <span class="text-sm text-secondary" style="font-family:var(--font-mono)">${formatTime(history.timestamp)}</span>
      </div>
      <div class="text-sm" style="margin-top:8px;">${escapeHtml(history.summary || '')}</div>
    </div>

    ${pending && pending.questions ? `
      <div class="section-label">Questions & Answers</div>
      ${pending.questions.map((q, i) => {
        const answer = answers && answers.parsed_answers
          ? answers.parsed_answers.find(a => a.question_id === q.id)
          : null;
        return `
          <div class="card">
            <div class="card-header">
              <span class="badge badge-node badge-panda">Q${q.id}</span>
              <span class="text-sm text-dim">${escapeHtml(q.category)}</span>
            </div>
            <div class="text-sm" style="margin-top:8px;">${escapeHtml(q.question)}</div>
            ${q.purpose ? `<div class="text-sm text-dim" style="margin-top:4px;font-style:italic;">${escapeHtml(q.purpose)}</div>` : ''}
            ${answer ? `
              <div style="margin-top:10px; padding:8px 12px; background:var(--bg-primary); border-radius:var(--radius); border-left:3px solid var(--accent);">
                <div class="text-sm text-dim" style="margin-bottom:4px;">Answer</div>
                <div class="text-sm">${escapeHtml(answer.answer)}</div>
              </div>
            ` : ''}
          </div>
        `;
      }).join('')}
    ` : ''}

    ${history.changes && history.changes.length > 0 ? `
      <div class="section-label">Changes (${history.changes.length})</div>
      ${history.changes.map(ch => `
        <div class="card">
          <div class="card-header">
            <span class="badge">${escapeHtml(ch.file)}</span>
            <span class="badge badge-status badge-${ch.type === 'add' ? 'approved' : 'discussing'}">${ch.type}</span>
          </div>
          <div class="text-sm text-secondary" style="margin-top:6px;">
            ${escapeHtml(ch.section || '')} &middot; ${escapeHtml(ch.description || '')}
          </div>
          ${ch.old_text ? `
            <div class="diff-block" style="margin-top:8px;">
              <div class="diff-old">${escapeHtml(ch.old_text)}</div>
              <div class="diff-arrow">&#8595;</div>
              <div class="diff-new">${escapeHtml(ch.new_text)}</div>
            </div>
          ` : ch.new_text ? `
            <div class="diff-block" style="margin-top:8px;">
              <div class="diff-new">${escapeHtml(ch.new_text)}</div>
            </div>
          ` : ''}
        </div>
      `).join('')}
    ` : ''}

    ${history.hashes_before || history.hashes_after ? `
      <div class="section-label">File Hashes</div>
      <div class="card">
        <div style="display:grid; grid-template-columns:auto 1fr 1fr; gap:8px; font-family:var(--font-mono);" class="text-sm">
          <div class="text-dim">File</div><div class="text-dim">Before</div><div class="text-dim">After</div>
          ${Object.keys(history.hashes_before || {}).map(key => `
            <div>${key}</div>
            <div class="text-dim">${(history.hashes_before[key] || '').substring(0, 12)}</div>
            <div${history.hashes_before[key] !== (history.hashes_after || {})[key] ? ' style="color:var(--accent)"' : ''}>${((history.hashes_after || {})[key] || '').substring(0, 12)}</div>
          `).join('')}
        </div>
      </div>
    ` : ''}
  `;
}

function statusClass(status) {
  if (status === 'completed') return 'approved';
  if (status === 'error' || status === 'failed') return 'rejected';
  return 'discussing';
}

function formatTime(ts) {
  if (!ts) return '';
  try { return new Date(ts).toLocaleString('ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch { return ts; }
}

function escapeHtml(str) {
  return (str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function truncate(str, max) {
  if (!str || str.length <= max) return str || '';
  return str.substring(0, max) + '...';
}

export async function renderTaskForm(app) {
  app.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">タスク投入</h1>
    </div>

    <div class="card">
      <form id="task-form">
        <div class="form-group">
          <label class="form-label">タイトル *</label>
          <input class="form-input" name="title" placeholder="タスクの概要を入力" required>
        </div>

        <div class="form-group">
          <label class="form-label">詳細説明</label>
          <textarea class="form-textarea" name="description" placeholder="詳しい説明（任意）"></textarea>
        </div>

        <div class="grid-2">
          <div class="form-group">
            <label class="form-label">種別</label>
            <select class="form-select" name="type">
              <option value="task">タスク（実行あり）</option>
              <option value="question">質問（議論のみ）</option>
            </select>
          </div>

          <div class="form-group">
            <label class="form-label">優先度</label>
            <select class="form-select" name="priority">
              <option value="low">低</option>
              <option value="medium" selected>中</option>
              <option value="high">高</option>
            </select>
          </div>
        </div>

        <button type="submit" class="btn btn-primary">投入する</button>
      </form>
      <div id="task-result" class="mt-4" style="display:none;"></div>
    </div>
  `;

  document.getElementById('task-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const form = e.target;
    const data = {
      title: form.title.value,
      description: form.description.value || form.title.value,
      type: form.type.value,
      priority: form.priority.value
    };

    try {
      const res = await fetch('/api/tasks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      });
      const task = await res.json();
      const resultDiv = document.getElementById('task-result');
      resultDiv.style.display = 'block';
      resultDiv.innerHTML = `
        <div style="color: var(--vote-approve); font-weight: 600;">
          タスクを投入しました: ${task.id}
        </div>
        <div class="text-sm text-secondary mt-2">
          Brainノードが検知し、議論を開始します。
          <a href="#/discussions" style="color: var(--node-panda);">議論一覧を見る</a>
        </div>
      `;
      form.reset();
    } catch (err) {
      alert('エラーが発生しました: ' + err.message);
    }
  });
}

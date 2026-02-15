const { Router } = require('express');
const fs = require('fs').promises;
const path = require('path');
const { readJson } = require('../lib/shared-reader');

module.exports = function (sharedDir) {
  const router = Router();

  router.get('/metrics', async (req, res) => {
    const data = await readJson(path.join(sharedDir, 'host_metrics', 'metrics.json'));
    res.json(data || []);
  });

  router.get('/token-usage', async (req, res) => {
    const usageFile = path.join(sharedDir, 'host_metrics', 'token_usage.jsonl');
    let lines = [];
    try {
      const content = await fs.readFile(usageFile, 'utf-8');
      lines = content.trim().split('\n').filter(Boolean).map(l => {
        try { return JSON.parse(l); } catch { return null; }
      }).filter(Boolean);
    } catch {
      // File doesn't exist yet — return empty data
    }

    const now = new Date();
    const todayStr = now.toISOString().slice(0, 10);
    const currentMonth = now.toISOString().slice(0, 7);

    // Today's totals
    const todayEntries = lines.filter(l => l.timestamp && l.timestamp.startsWith(todayStr));
    const today = {
      total_input: todayEntries.reduce((s, l) => s + (l.input_tokens || 0), 0),
      total_output: todayEntries.reduce((s, l) => s + (l.output_tokens || 0), 0),
      total_cache_read: todayEntries.reduce((s, l) => s + (l.cache_read_input_tokens || 0), 0),
      total_cache_create: todayEntries.reduce((s, l) => s + (l.cache_creation_input_tokens || 0), 0),
      total_cost: todayEntries.reduce((s, l) => s + (l.cost_usd || 0), 0),
      by_node: {}
    };
    for (const entry of todayEntries) {
      const node = entry.node || 'unknown';
      if (!today.by_node[node]) {
        today.by_node[node] = { input: 0, output: 0, cost: 0 };
      }
      today.by_node[node].input += entry.input_tokens || 0;
      today.by_node[node].output += entry.output_tokens || 0;
      today.by_node[node].cost += entry.cost_usd || 0;
    }

    // Daily aggregation (last 7 days)
    const daily = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
      const dateStr = d.toISOString().slice(0, 10);
      const dayEntries = lines.filter(l => l.timestamp && l.timestamp.startsWith(dateStr));
      daily.push({
        date: dateStr,
        input: dayEntries.reduce((s, l) => s + (l.input_tokens || 0), 0),
        output: dayEntries.reduce((s, l) => s + (l.output_tokens || 0), 0),
        cost: dayEntries.reduce((s, l) => s + (l.cost_usd || 0), 0)
      });
    }

    // Monthly cost for budget calculation
    const monthEntries = lines.filter(l => l.timestamp && l.timestamp.startsWith(currentMonth));
    const monthlyCost = monthEntries.reduce((s, l) => s + (l.cost_usd || 0), 0);

    // Budget info
    let budget = null;
    const budgetData = await readJson(path.join(sharedDir, 'config', 'token_budget.json'));
    if (budgetData && budgetData.monthly_budget_usd) {
      budget = {
        monthly_budget_usd: budgetData.monthly_budget_usd,
        monthly_spent_usd: monthlyCost,
        monthly_remaining_usd: budgetData.monthly_budget_usd - monthlyCost,
        usage_pct: (monthlyCost / budgetData.monthly_budget_usd) * 100
      };
    }

    res.json({ today, daily, budget });
  });

  return router;
};

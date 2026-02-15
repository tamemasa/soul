const { Router } = require('express');
const fs = require('fs').promises;
const path = require('path');
const { readJson } = require('../lib/shared-reader');

const SUBSCRIPTION_PLANS = {
  pro:      { label: 'Pro',      price_usd: 20,  weekly_output_limit: 1_000_000 },
  max_5x:   { label: 'Max 5x',  price_usd: 100, weekly_output_limit: 5_000_000 },
  max_20x:  { label: 'Max 20x', price_usd: 200, weekly_output_limit: 20_000_000 }
};

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

    // Subscription usage
    let subscription = null;
    const planKey = (budgetData && budgetData.subscription_plan) || 'max_20x';
    const plan = SUBSCRIPTION_PLANS[planKey];
    if (plan) {
      // Week start: Monday 00:00 UTC
      const dayOfWeek = now.getUTCDay(); // 0=Sun, 1=Mon, ...
      const daysSinceMonday = dayOfWeek === 0 ? 6 : dayOfWeek - 1;
      const weekStart = new Date(now);
      weekStart.setUTCDate(weekStart.getUTCDate() - daysSinceMonday);
      weekStart.setUTCHours(0, 0, 0, 0);
      const weekStartStr = weekStart.toISOString().slice(0, 10);

      // Today start
      const todayStart = todayStr;

      // Filter entries for this week and today (output tokens only)
      const weeklyOutput = lines
        .filter(l => l.timestamp && l.timestamp.slice(0, 10) >= weekStartStr)
        .reduce((s, l) => s + (l.output_tokens || 0), 0);

      const dailyOutput = todayEntries
        .reduce((s, l) => s + (l.output_tokens || 0), 0);

      const dailyLimit = Math.round(plan.weekly_output_limit / 7);

      const weeklyPct = plan.weekly_output_limit > 0
        ? (weeklyOutput / plan.weekly_output_limit) * 100 : 0;
      const dailyPct = dailyLimit > 0
        ? (dailyOutput / dailyLimit) * 100 : 0;

      // Recommend optimal plan based on 7-day average output
      const last7Output = daily.reduce((s, d) => s + (d.output || 0), 0);
      const avgDailyOutput = last7Output / 7;
      const projectedWeekly = avgDailyOutput * 7;

      let recommended = null;
      const planEntries = Object.entries(SUBSCRIPTION_PLANS)
        .sort((a, b) => a[1].price_usd - b[1].price_usd);
      for (const [key, p] of planEntries) {
        if (projectedWeekly <= p.weekly_output_limit * 0.85) {
          if (key !== planKey) {
            const saving = plan.price_usd - p.price_usd;
            recommended = {
              plan: key,
              label: p.label,
              price_usd: p.price_usd,
              reason: saving > 0
                ? `Weekly avg ${formatTokens(projectedWeekly)} output fits ${p.label} limit. Save $${saving}/mo`
                : `Weekly avg ${formatTokens(projectedWeekly)} output. ${p.label} gives more headroom`
            };
          }
          break;
        }
      }

      subscription = {
        plan: planKey,
        label: plan.label,
        price_usd: plan.price_usd,
        weekly: {
          limit: plan.weekly_output_limit,
          used: weeklyOutput,
          remaining: Math.max(0, plan.weekly_output_limit - weeklyOutput),
          pct: Math.round(weeklyPct * 10) / 10
        },
        daily: {
          limit: dailyLimit,
          used: dailyOutput,
          remaining: Math.max(0, dailyLimit - dailyOutput),
          pct: Math.round(dailyPct * 10) / 10
        },
        recommended
      };
    }

    res.json({ today, daily, budget, subscription });
  });

  router.patch('/subscription', async (req, res) => {
    const { plan } = req.body || {};
    if (!plan || !SUBSCRIPTION_PLANS[plan]) {
      return res.status(400).json({ error: 'Invalid plan. Valid: ' + Object.keys(SUBSCRIPTION_PLANS).join(', ') });
    }

    const configPath = path.join(sharedDir, 'config', 'token_budget.json');
    let config = {};
    try {
      const raw = await fs.readFile(configPath, 'utf-8');
      config = JSON.parse(raw);
    } catch {
      // start fresh
    }

    config.subscription_plan = plan;
    await fs.writeFile(configPath, JSON.stringify(config, null, 2) + '\n', 'utf-8');

    res.json({ ok: true, plan, label: SUBSCRIPTION_PLANS[plan].label });
  });

  return router;
};

function formatTokens(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + 'M';
  if (n >= 1_000) return (n / 1_000).toFixed(1) + 'K';
  return String(Math.round(n));
}

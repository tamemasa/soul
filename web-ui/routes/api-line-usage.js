const { Router } = require('express');

const CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes
let cache = null;
let cacheTime = 0;

module.exports = function () {
  const router = Router();

  router.get('/line-usage', async (req, res) => {
    const token = process.env.LINE_CHANNEL_ACCESS_TOKEN || '';

    if (!token) {
      return res.json({ quota: 200, used: null, remaining: null, pct: null, error: 'TOKEN_NOT_SET' });
    }

    const now = Date.now();
    if (cache && (now - cacheTime) < CACHE_TTL_MS) {
      return res.json(cache);
    }

    try {
      const headers = { Authorization: `Bearer ${token}` };
      const [quotaRes, consumptionRes] = await Promise.all([
        fetch('https://api.line.me/v2/bot/message/quota', { headers }),
        fetch('https://api.line.me/v2/bot/message/quota/consumption', { headers })
      ]);

      if (!quotaRes.ok || !consumptionRes.ok) {
        return res.json({ quota: 200, used: null, remaining: null, pct: null, error: 'API_ERROR' });
      }

      const quotaData = await quotaRes.json();
      const consumptionData = await consumptionRes.json();

      const quota = quotaData.value || 200;
      const used = consumptionData.totalUsage || 0;
      const remaining = Math.max(quota - used, 0);
      const pct = quota > 0 ? (used / quota) * 100 : 0;

      cache = {
        quota,
        used,
        remaining,
        pct: Math.round(pct * 10) / 10,
        fetched_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
      };
      cacheTime = now;

      res.json(cache);
    } catch (err) {
      res.json({ quota: 200, used: null, remaining: null, pct: null, error: 'FETCH_ERROR' });
    }
  });

  return router;
};

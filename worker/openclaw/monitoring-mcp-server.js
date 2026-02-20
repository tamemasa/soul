#!/usr/bin/env node
"use strict";

// MCP Server for Soul monitoring data access.
// Provides tools for OpenClaw to query system status, alerts, and reports.

const { Server } = require("@modelcontextprotocol/sdk/server/index.js");
const { StdioServerTransport } = require("@modelcontextprotocol/sdk/server/stdio.js");
const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} = require("@modelcontextprotocol/sdk/types.js");
const fs = require("fs");
const path = require("path");

const MONITORING_DIR = process.env.MONITORING_DIR || "/shared/monitoring";
const ALERTS_DIR = process.env.ALERTS_DIR || "/shared/alerts";

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  process.stderr.write(`[${ts}] [monitoring-mcp] ${msg}\n`);
}

function readJSON(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

// --- Tool implementations ---

function getSystemStatus() {
  const latestPath = path.join(MONITORING_DIR, "latest.json");
  const data = readJSON(latestPath);
  if (!data) {
    return { error: "No monitoring data available at " + latestPath };
  }
  return data;
}

function listAlerts({ severity, resolved, limit } = {}) {
  const alertLimit = Math.min(limit || 20, 50);
  let files;
  try {
    files = fs
      .readdirSync(ALERTS_DIR)
      .filter((f) => f.startsWith("unified_alert_") && f.endsWith(".json"))
      .sort()
      .reverse()
      .slice(0, 100); // scan at most 100 recent files
  } catch {
    return { error: "Cannot read alerts directory: " + ALERTS_DIR, alerts: [] };
  }

  const alerts = [];
  for (const file of files) {
    if (alerts.length >= alertLimit) break;
    const data = readJSON(path.join(ALERTS_DIR, file));
    if (!data) continue;

    // Apply filters
    if (severity && data.severity !== severity) continue;
    if (resolved === true && data.resolved !== true) continue;
    if (resolved === false && data.resolved === true) continue;

    alerts.push({
      id: data.id,
      created_at: data.created_at,
      severity: data.severity,
      type: data.type,
      category: data.category,
      description: data.description,
      resolved: data.resolved || false,
      resolved_at: data.resolved_at || null,
    });
  }

  return { total: alerts.length, alerts };
}

function getAlertDetail({ alert_id }) {
  if (!alert_id) {
    return { error: "alert_id is required" };
  }

  // Try direct file match
  const directPath = path.join(ALERTS_DIR, alert_id + ".json");
  const data = readJSON(directPath);
  if (data) return data;

  // Search in archive
  const archivePath = path.join(ALERTS_DIR, "archive", alert_id + ".json");
  const archiveData = readJSON(archivePath);
  if (archiveData) return archiveData;

  return { error: "Alert not found: " + alert_id };
}

function getLatestReport() {
  const reportsDir = path.join(MONITORING_DIR, "reports");
  let files;
  try {
    files = fs
      .readdirSync(reportsDir)
      .filter((f) => f.startsWith("report_") && f.endsWith(".json"))
      .sort()
      .reverse();
  } catch {
    return { error: "Cannot read reports directory: " + reportsDir };
  }

  if (files.length === 0) {
    return { error: "No reports found" };
  }

  const data = readJSON(path.join(reportsDir, files[0]));
  if (!data) {
    return { error: "Failed to read latest report: " + files[0] };
  }
  return data;
}

// --- MCP Server setup ---

async function main() {
  const server = new Server(
    { name: "soul-monitoring", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "get_system_status",
        description:
          "現在のシステム監視ステータスを取得する。ヘルスチェック結果、コンプライアンススコア等を含む。【バディモード専用】オーナー確認済みの場合のみ使用すること。",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "list_alerts",
        description:
          "アラート一覧を取得する。severity/resolved でフィルタ可能。【バディモード専用】オーナー確認済みの場合のみ使用すること。",
        inputSchema: {
          type: "object",
          properties: {
            severity: {
              type: "string",
              enum: ["critical", "high", "medium", "low"],
              description: "フィルタするseverityレベル",
            },
            resolved: {
              type: "boolean",
              description: "true=解決済みのみ、false=未解決のみ、省略=全件",
            },
            limit: {
              type: "number",
              description: "取得件数上限（デフォルト20、最大50）",
            },
          },
        },
      },
      {
        name: "get_alert_detail",
        description: "特定のアラートIDの詳細情報を取得する。【バディモード専用】オーナー確認済みの場合のみ使用すること。",
        inputSchema: {
          type: "object",
          properties: {
            alert_id: {
              type: "string",
              description: "アラートID（例: unified_alert_1771562242_3177）",
            },
          },
          required: ["alert_id"],
        },
      },
      {
        name: "get_latest_report",
        description:
          "最新の監視レポートを取得する。違反詳細、コンプライアンス分析等を含む。【バディモード専用】オーナー確認済みの場合のみ使用すること。",
        inputSchema: { type: "object", properties: {} },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    let result;
    switch (name) {
      case "get_system_status":
        result = getSystemStatus();
        break;
      case "list_alerts":
        result = listAlerts(args || {});
        break;
      case "get_alert_detail":
        result = getAlertDetail(args || {});
        break;
      case "get_latest_report":
        result = getLatestReport();
        break;
      default:
        return {
          content: [{ type: "text", text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }

    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("Monitoring MCP server started");
}

main().catch((err) => {
  log("Fatal error: " + err.message);
  process.exit(1);
});

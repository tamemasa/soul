#!/usr/bin/env node
"use strict";

// Fetches Google Calendar iCal data and writes a human-readable Markdown file
// with events for today ± 7 days. Runs in a loop every 5 minutes.

const https = require("https");
const http = require("http");
const fs = require("fs");
const path = require("path");

const CONFIG_PATH = process.env.GCAL_CONFIG_PATH || "/app/gcal-calendars.json";
const OUTPUT_PATH =
  process.env.GCAL_OUTPUT_PATH ||
  "/home/openclaw/.openclaw/workspace/CALENDAR.md";
const INTERVAL_MS = 5 * 60 * 1000;

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  console.error(`[${ts}] [gcal-sync] ${msg}`);
}

function fetchURL(url) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("https") ? https : http;
    mod
      .get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return fetchURL(res.headers.location).then(resolve, reject);
        }
        if (res.statusCode !== 200) {
          return reject(new Error(`HTTP ${res.statusCode}`));
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

// Minimal ICS parser - extracts VEVENTs with key fields
function parseICS(icsText) {
  const events = [];
  const blocks = icsText.split("BEGIN:VEVENT");
  for (let i = 1; i < blocks.length; i++) {
    const block = blocks[i].split("END:VEVENT")[0];
    const ev = {};
    // Handle folded lines (RFC 5545: lines starting with space/tab are continuations)
    const unfolded = block.replace(/\r?\n[ \t]/g, "");
    for (const line of unfolded.split(/\r?\n/)) {
      const m = line.match(/^(DTSTART[^:]*):(.+)/);
      if (m) {
        ev.dtstart = m[2].trim();
        ev.dtstartParams = m[1];
      }
      const m2 = line.match(/^(DTEND[^:]*):(.+)/);
      if (m2) ev.dtend = m2[2].trim();
      if (line.startsWith("SUMMARY:"))
        ev.summary = line.slice(8).replace(/\\,/g, ",").replace(/\\n/g, "\n").trim();
      if (line.startsWith("DESCRIPTION:"))
        ev.description = line
          .slice(12)
          .replace(/\\,/g, ",")
          .replace(/\\n/g, "\n")
          .trim();
      if (line.startsWith("LOCATION:"))
        ev.location = line.slice(9).replace(/\\,/g, ",").trim();
    }
    if (ev.dtstart) events.push(ev);
  }
  return events;
}

function parseICSDate(str) {
  // 20260219T030000Z or 20260219
  const m = str.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/);
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m;
  if (h !== undefined) {
    return new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +s));
  }
  return new Date(+y, +mo - 1, +d);
}

function formatJST(date, allDay) {
  if (allDay) {
    return `${date.getFullYear()}/${String(date.getMonth() + 1).padStart(2, "0")}/${String(date.getDate()).padStart(2, "0")}`;
  }
  const jst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return `${jst.getUTCFullYear()}/${String(jst.getUTCMonth() + 1).padStart(2, "0")}/${String(jst.getUTCDate()).padStart(2, "0")} ${String(jst.getUTCHours()).padStart(2, "0")}:${String(jst.getUTCMinutes()).padStart(2, "0")}`;
}

function dateKey(date) {
  const jst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return `${jst.getUTCFullYear()}-${String(jst.getUTCMonth() + 1).padStart(2, "0")}-${String(jst.getUTCDate()).padStart(2, "0")}`;
}

const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
function dateSectionHeader(dateStr) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const dt = new Date(y, m - 1, d);
  const wd = WEEKDAYS[dt.getDay()];
  return `${m}/${d}（${wd}）`;
}

async function sync() {
  let calendars;
  try {
    calendars = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  } catch (e) {
    log(`No calendar config: ${e.message}`);
    return;
  }
  if (calendars.length === 0) return;

  const now = new Date();
  const rangeStart = new Date(now);
  rangeStart.setMonth(rangeStart.getMonth() - 2);
  rangeStart.setHours(0, 0, 0, 0);
  const rangeEnd = new Date(now);
  rangeEnd.setMonth(rangeEnd.getMonth() + 1);
  rangeEnd.setHours(23, 59, 59, 999);

  const allEvents = [];

  for (const cal of calendars) {
    try {
      const ics = await fetchURL(cal.url);
      const events = parseICS(ics);
      for (const ev of events) {
        const start = parseICSDate(ev.dtstart);
        if (!start) continue;
        const end = ev.dtend ? parseICSDate(ev.dtend) : start;
        if (start <= rangeEnd && end >= rangeStart) {
          const allDay =
            ev.dtstartParams?.includes("VALUE=DATE") ||
            ev.dtstart.length === 8;
          allEvents.push({
            calendar: cal.name,
            summary: ev.summary || "(無題)",
            start,
            end,
            allDay,
            location: ev.location,
            description: ev.description,
            dateKey: dateKey(start),
          });
        }
      }
      log(`Fetched ${cal.name}: ${events.length} total, ${allEvents.length} in range`);
    } catch (e) {
      log(`ERROR fetching ${cal.name}: ${e.message}`);
    }
  }

  // Sort by start time
  allEvents.sort((a, b) => a.start - b.start);

  // Group by date
  const byDate = new Map();
  for (const ev of allEvents) {
    if (!byDate.has(ev.dateKey)) byDate.set(ev.dateKey, []);
    byDate.get(ev.dateKey).push(ev);
  }

  // Build Markdown
  const todayKey = dateKey(now);
  const lines = [
    "# カレンダー予定",
    "",
    `最終更新: ${formatJST(now, false)} JST`,
    "",
  ];

  for (const [dk, events] of byDate) {
    const isToday = dk === todayKey;
    lines.push(`## ${dateSectionHeader(dk)}${isToday ? "（今日）" : ""}`);
    lines.push("");
    for (const ev of events) {
      const calLabel = calendars.length > 1 ? ` [${ev.calendar}]` : "";
      const timeStr = ev.allDay
        ? "終日"
        : `${formatJST(ev.start, false)} ~ ${formatJST(ev.end, false)}`;
      lines.push(`- **${ev.summary}**${calLabel} (${timeStr})`);
      if (ev.location) lines.push(`  - 場所: ${ev.location}`);
      if (ev.description) {
        // Show first 300 chars of description
        const desc = ev.description.slice(0, 300).replace(/\n/g, " ");
        lines.push(`  - ${desc}`);
      }
    }
    lines.push("");
  }

  if (allEvents.length === 0) {
    lines.push("予定はありません。");
    lines.push("");
  }

  fs.writeFileSync(OUTPUT_PATH, lines.join("\n"), "utf8");
  log(`Wrote ${allEvents.length} events to CALENDAR.md`);
}

async function main() {
  log("Starting calendar sync loop");
  while (true) {
    try {
      await sync();
    } catch (e) {
      log(`Sync error: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }
}

main();

#!/usr/bin/env node
// scripts/integrations/slack/event-flush.mjs (R23 이관본 — archive 원본 경로: docs/design/archive/R3-R4-original-drafts/event-flush.mjs)

/**
 * 왜:
 * - 이 파일은 오직 outbound 전송만 담당한다.
 * - events.jsonl 을 상시 tail 하면서 Slack 으로 fan-out 하고,
 *   실패는 재시도 후 DLQ 로 떨어뜨린다.
 * - 상태는 append-only JSONL 로그로 남겨 재시작 시 마지막 cursor 를 복원한다.
 *
 * 기대하는 외부 routes JSON 예시:
 * {
 *   "routes": {
 *     "spawn_prepared":      { "lanes": ["session-thread"] },
 *     "spawn_success":       { "lanes": ["session-thread"] },
 *     "spawn_failure":       { "lanes": ["company-hq"], "template": "generic" },
 *     "approval_required":   { "lanes": ["approvals"], "template": "approval_required" },
 *     "plan_validated":      { "lanes": ["session-thread"] },
 *     "approved":            { "lanes": ["audit", "session-thread"] },
 *     "rejected":            { "lanes": ["audit", "session-thread"] },
 *     "compact_result_ready":{ "lanes": ["company-hq"] },
 *     "export_promoted":     { "lanes": ["company-hq"] },
 *     "sentinel_detected":   { "lanes": ["company-hq"] },
 *     "worker_timeout":      { "lanes": ["session-thread", "audit"] }
 *   }
 * }
 *
 * 멀티 채널 webhook 구성 방법:
 * 1) SLACK_WEBHOOK_URLS_JSON='{"approvals":["https://hooks.slack..."],"audit":["https://hooks.slack..."]}'
 * 2) 또는 개별 env:
 *    SLACK_WEBHOOK_URL_APPROVALS="https://hooks.slack..."
 *    SLACK_WEBHOOK_URL_AUDIT="https://hooks.slack...,https://hooks.slack..."
 * 3) 단일 fallback:
 *    SLACK_WEBHOOK_URL="https://hooks.slack..."
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { promises as fsp } from 'node:fs';

// R23: one-shot / dry-run mode flags
// --once : 1회 flush 후 process.exit(0). watchers/interval 생성 0.
//          bash harness 가 company-emit.sh 직후 호출하는 방식. daemon/launchd 금지.
// --check: routes.json 파싱 dry-run만 수행 후 exit. doctor [10/10] ACTIVE 실재화용.
const ONCE_MODE  = process.argv.includes('--once');
const CHECK_MODE = process.argv.includes('--check');

const runtimeRoot = process.env.COMPANY_RUNTIME_ROOT ?? '.company-runtime';
const eventsPath = process.env.COMPANY_EVENTS_PATH ?? path.join(runtimeRoot, 'events.jsonl');
const routesPath = process.env.SLACK_ROUTES_PATH ?? path.join('config', 'slack-routes.json');
const stateLogPath = process.env.EVENT_FLUSH_STATE_PATH ?? path.join(runtimeRoot, 'relay', 'state.jsonl');
const dlqPath = process.env.EVENT_FLUSH_DLQ_PATH ?? path.join(runtimeRoot, 'dlq', 'slack-events.jsonl');

const pollIntervalMs = Number(process.env.EVENT_FLUSH_POLL_INTERVAL_MS ?? 2000);
const watchDebounceMs = Number(process.env.EVENT_FLUSH_WATCH_DEBOUNCE_MS ?? 250);
const initialBackoffMs = Number(process.env.EVENT_FLUSH_INITIAL_BACKOFF_MS ?? 1000);
const maxBackoffMs = Number(process.env.EVENT_FLUSH_MAX_BACKOFF_MS ?? 30000);
const maxAttempts = Number(process.env.EVENT_FLUSH_MAX_ATTEMPTS ?? 6);
const bootstrapMode = (process.env.EVENT_FLUSH_BOOTSTRAP_MODE ?? 'end').toLowerCase();

const supportedTaxonomy = [
  'spawn_prepared',
  'spawn_success',
  'spawn_failure',
  'approval_required',
  'plan_validated',
  'approved',
  'rejected',
  'compact_result_ready',
  'export_promoted',
  'sentinel_detected',
  'worker_timeout',
];

const eventAliases = {
  approval_rejected: 'rejected',
};

const state = {
  cursor: {
    fileId: null,
    seen: 0,
  },
  routesCache: {
    mtimeMs: -1,
    routes: {},
  },
  scanning: false,
  rerunRequested: false,
  watchTimer: null,
  watchers: [],
};

await ensureDirectories();

// R23 --check: routes.json 파싱 dry-run만 수행 후 종료 (watchers/cursor 불필요)
if (CHECK_MODE) {
  await refreshRoutesIfChanged();
  const count = Object.keys(state.routesCache.routes).length;
  console.log(`[event-flush] --check OK routes=${count} path=${routesPath}`);
  process.exit(0);
}

state.cursor = await loadLastCursor();
const webhookMap = loadWebhookMap();

// R23 --once: webhook 미설정 시 silent skip (daemon 모드는 throw 유지)
if (Object.keys(webhookMap).length === 0) {
  if (ONCE_MODE) {
    console.warn('[event-flush] --once: webhook 미설정, scan skip');
    process.exit(0);
  }
  throw new Error(
    'Slack webhook 구성이 없습니다. SLACK_WEBHOOK_URL 또는 SLACK_WEBHOOK_URLS_JSON 또는 SLACK_WEBHOOK_URL_<LANE> 를 설정하세요.',
  );
}

await bootstrapCursorIfNeeded();
await scanNow(ONCE_MODE ? 'once' : 'startup');

// R23 --once: scan 1회 완료 후 종료. watcher/interval/signal handler 생성 0.
if (ONCE_MODE) {
  process.exit(0);
}

startWatchers();

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

console.log(`[event-flush] watching ${eventsPath}`);
console.log(`[event-flush] routes from ${routesPath}`);
console.log(`[event-flush] polling every ${pollIntervalMs}ms`);

const pollHandle = setInterval(() => scheduleScan('poll'), pollIntervalMs);

function shutdown() {
  clearInterval(pollHandle);
  clearTimeout(state.watchTimer);
  for (const watcher of state.watchers) {
    try {
      watcher.close();
    } catch {
      // 왜: 종료 시 watcher close 실패는 치명적이지 않다.
    }
  }
  process.exit(0);
}

function startWatchers() {
  const watchTargets = new Set([
    path.dirname(eventsPath),
    path.dirname(routesPath),
  ]);

  for (const watchDir of watchTargets) {
    try {
      const watcher = fs.watch(watchDir, (_eventType, filename) => {
        const basename = filename?.toString?.() ?? '';
        if (
          basename === path.basename(eventsPath) ||
          basename === path.basename(routesPath) ||
          basename === ''
        ) {
          scheduleScan(`watch:${watchDir}`);
        }
      });
      state.watchers.push(watcher);
    } catch (error) {
      console.warn(`[event-flush] fs.watch disabled for ${watchDir}: ${error.message}`);
    }
  }
}

function scheduleScan(source) {
  clearTimeout(state.watchTimer);
  state.watchTimer = setTimeout(() => {
    void scanNow(source);
  }, watchDebounceMs);
}

async function scanNow(source) {
  if (state.scanning) {
    state.rerunRequested = true;
    return;
  }

  state.scanning = true;
  state.rerunRequested = false;

  try {
    await refreshRoutesIfChanged();

    const stat = await safeStat(eventsPath);
    if (!stat) {
      return;
    }

    const currentFileId = serializeFileId(stat);

    if (!state.cursor.fileId) {
      state.cursor = { fileId: currentFileId, seen: bootstrapMode === 'beginning' ? 0 : stat.size };
      await appendStateRecord({
        kind: 'bootstrap',
        source,
        file_id: currentFileId,
        seen: state.cursor.seen,
        mode: bootstrapMode,
      });
    }

    if (state.cursor.fileId !== currentFileId) {
      // 왜: log rotation/truncate 가 발생해도 상태로그는 append-only 로 남기고,
      // 새 파일 세대에서는 seen=0 으로 다시 시작한다.
      state.cursor = { fileId: currentFileId, seen: 0 };
      await appendStateRecord({
        kind: 'rotation',
        source,
        file_id: currentFileId,
        seen: 0,
      });
    }

    if (stat.size <= state.cursor.seen) {
      return;
    }

    const raw = await readFileRange(eventsPath, state.cursor.seen, stat.size - 1);
    const lastNewlineIndex = raw.lastIndexOf('\n');

    if (lastNewlineIndex === -1) {
      // 왜: 마지막 줄이 아직 flush 중일 수 있으므로 cursor 를 전진시키지 않고 다음 poll 을 기다린다.
      return;
    }

    const processable = raw.slice(0, lastNewlineIndex + 1);
    const lines = processable.split('\n').filter(Boolean);

    let cursorSeen = state.cursor.seen;

    for (const line of lines) {
      const lineBytes = Buffer.byteLength(`${line}\n`, 'utf8');
      try {
        await processLine(line);
      } catch (error) {
        // 왜: 최종 안전판. processLine 내부에서 대부분 DLQ 처리되지만
        // 여기서도 놓친 예외를 잡아 cursor 정체를 방지한다.
        await appendDlqRecord({
          failed_at: new Date().toISOString(),
          reason: 'unhandled_process_error',
          error: error.message,
          raw_line: line,
        });
      } finally {
        cursorSeen += lineBytes;
        state.cursor = {
          fileId: currentFileId,
          seen: cursorSeen,
        };
        await appendStateRecord({
          kind: 'cursor',
          source,
          file_id: currentFileId,
          seen: cursorSeen,
        });
      }
    }
  } finally {
    state.scanning = false;
    if (state.rerunRequested) {
      state.rerunRequested = false;
      void scanNow('rerun');
    }
  }
}

async function processLine(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch (error) {
    await appendDlqRecord({
      failed_at: new Date().toISOString(),
      reason: 'invalid_json',
      error: error.message,
      raw_line: line,
    });
    return;
  }

  const eventName = normalizeEventName(event.event);
  const route = state.routesCache.routes[eventName];

  if (!route || route.enabled === false) {
    return;
  }

  const payload = buildSlackPayload({
    ...event,
    event: eventName,
  }, route);

  // R26 Phase 4b: thread_ts 주입 — slack-callback 이 이전에 기록한 slack-thread.env 가 존재하면
  // 후속 이벤트를 동일 Slack thread 에 reply 로 라우팅한다. append-only 패치.
  // 실패는 모두 silent skip (payload 원본 유지).
  await maybeAttachThreadTs(payload, event);

  const deliveries = expandDeliveries(route, webhookMap);

  if (deliveries.length === 0) {
    await appendDlqRecord({
      failed_at: new Date().toISOString(),
      reason: 'no_webhook_for_route',
      event: eventName,
      route,
      raw_event: event,
    });
    return;
  }

  for (const delivery of deliveries) {
    const result = await postSlackWithRetry({
      url: delivery.url,
      lane: delivery.lane,
      payload,
      event,
    });

    if (!result.ok) {
      await appendDlqRecord({
        failed_at: new Date().toISOString(),
        reason: 'slack_delivery_failed',
        event: eventName,
        lane: delivery.lane,
        url: redactWebhookUrl(delivery.url),
        attempts: result.attempts,
        error: result.error,
        raw_event: event,
      });
    }
  }
}

function expandDeliveries(route, webhookMapRef) {
  const deliveries = [];
  for (const lane of route.lanes) {
    const urls = webhookMapRef[lane] ?? webhookMapRef.default ?? [];
    for (const url of urls) {
      deliveries.push({ lane, url });
    }
  }
  return deliveries;
}

async function postSlackWithRetry({ url, lane, payload, event }) {
  let lastError = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json; charset=utf-8',
        },
        body: JSON.stringify(payload),
      });

      if (response.ok) {
        return { ok: true, attempts: attempt };
      }

      const responseBody = await response.text();
      const retryAfterHeader = response.headers.get('retry-after');
      const retryAfterMs = retryAfterHeader ? Number(retryAfterHeader) * 1000 : null;

      const error = new Error(
        `Slack webhook ${response.status} ${response.statusText} lane=${lane} body=${truncate(responseBody, 400)}`,
      );

      // 왜: 4xx(429 제외)는 재시도로 회복될 가능성이 낮으므로 즉시 실패로 본다.
      if (response.status >= 400 && response.status < 500 && response.status !== 429) {
        throw makeNonRetryable(error);
      }

      lastError = error;
      if (attempt < maxAttempts) {
        await sleep(computeBackoffMs(attempt, retryAfterMs));
      }
    } catch (error) {
      lastError = error;
      if (error.nonRetryable || attempt >= maxAttempts) {
        break;
      }
      await sleep(computeBackoffMs(attempt));
    }
  }

  return {
    ok: false,
    attempts: maxAttempts,
    error: lastError?.message ?? 'unknown delivery failure',
    event_id: makeEventId(event),
  };
}

function buildSlackPayload(event, route) {
  const template = route.template ?? (event.event === 'approval_required' ? 'approval_required' : 'generic');
  if (template === 'approval_required') {
    return buildApprovalRequiredPayload(event);
  }
  return buildGenericPayload(event);
}

function buildApprovalRequiredPayload(event) {
  const canApprove =
    typeof event.session_id === 'string' &&
    typeof event.worker === 'string' &&
    typeof event.plan_sha256 === 'string';

  const idempotencyKey = event.idempotency_key ?? makeEventId(event);
  const actionValue = JSON.stringify({
    session_id: event.session_id,
    worker: event.worker,
    plan_sha256: event.plan_sha256,
    idempotency_key: idempotencyKey,
  });

  const blocks = [
    {
      type: 'header',
      text: {
        type: 'plain_text',
        text: `승인 필요 · ${event.worker ?? 'unknown-worker'}`,
        emoji: true,
      },
    },
    {
      type: 'section',
      fields: compact([
        mrkdwnField('*Session*', event.session_id ?? 'unknown'),
        mrkdwnField('*Worker*', event.worker ?? 'unknown'),
        mrkdwnField('*Plan SHA256*', `\`${truncate(event.plan_sha256 ?? 'missing', 64)}\``),
        mrkdwnField('*Idempotency*', `\`${truncate(idempotencyKey, 64)}\``),
      ]),
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*Goal*\n${truncate(renderMultiline(event.goal, 'goal 없음'), 2900)}`,
      },
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*Outputs*\n${truncate(renderBulletList(event.outputs, '- 없음'), 2900)}`,
      },
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*Risks*\n${truncate(renderBulletList(event.risks, '- 없음'), 2900)}`,
      },
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*MCP*\n${truncate(renderBulletList(event.mcp ?? event.mcp_footprints, '- 없음'), 2900)}`,
      },
    },
  ];

  if (canApprove) {
    const actions = [
      {
        type: 'button',
        style: 'primary',
        text: {
          type: 'plain_text',
          text: 'Approve',
          emoji: true,
        },
        action_id: `approve|${event.session_id}|${event.worker}|${event.plan_sha256}|${idempotencyKey}`,
        value: actionValue,
      },
      {
        type: 'button',
        style: 'danger',
        text: {
          type: 'plain_text',
          text: 'Reject',
          emoji: true,
        },
        action_id: `reject|${event.session_id}|${event.worker}|${event.plan_sha256}|${idempotencyKey}`,
        value: actionValue,
      },
    ];

    if (event.plan_url) {
      actions.push({
        type: 'button',
        text: {
          type: 'plain_text',
          text: 'Open Plan',
          emoji: true,
        },
        url: event.plan_url,
        action_id: `open_plan|${event.session_id}|${event.worker}|${event.plan_sha256}|${idempotencyKey}`,
        value: actionValue,
      });
    }

    blocks.push({
      type: 'actions',
      block_id: `approval_actions|${event.session_id}|${event.worker}|${event.plan_sha256}|${idempotencyKey}`,
      elements: actions,
    });
  } else {
    blocks.push({
      type: 'context',
      elements: [
        {
          type: 'mrkdwn',
          text: ':warning: session_id / worker / plan_sha256 중 일부가 없어 인터랙티브 승인 버튼을 렌더링하지 않았습니다.',
        },
      ],
    });
  }

  return {
    text: `approval_required · ${event.session_id ?? 'unknown'} · ${event.worker ?? 'unknown'}`,
    blocks,
  };
}

function buildGenericPayload(event) {
  const summary =
    event.message ??
    event.summary ??
    event.reason ??
    event.goal ??
    `${event.event} 이벤트가 발생했습니다.`;

  const blocks = [
    {
      type: 'header',
      text: {
        type: 'plain_text',
        text: `${event.event} · ${event.worker ?? 'leader'}`,
        emoji: true,
      },
    },
    {
      type: 'section',
      fields: compact([
        mrkdwnField('*Session*', event.session_id ?? 'unknown'),
        mrkdwnField('*Worker*', event.worker ?? 'leader'),
      ]),
    },
    {
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: truncate(renderMultiline(summary, '요약 없음'), 2900),
      },
    },
  ];

  if (event.outputs || event.dest) {
    blocks.push({
      type: 'section',
      text: {
        type: 'mrkdwn',
        text: `*Artifacts*\n${truncate(renderBulletList(event.outputs ?? event.dest, '- 없음'), 2900)}`,
      },
    });
  }

  return {
    text: `${event.event} · ${event.session_id ?? 'unknown'} · ${event.worker ?? 'leader'}`,
    blocks,
  };
}

function mrkdwnField(label, value) {
  return {
    type: 'mrkdwn',
    text: `${label}\n${value}`,
  };
}

function renderMultiline(value, fallback) {
  if (value == null) return fallback;
  if (Array.isArray(value)) return value.map(String).join('\n');
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  return String(value);
}

function renderBulletList(value, fallback) {
  if (value == null) return fallback;
  if (Array.isArray(value)) {
    return value.length === 0 ? fallback : value.map((item) => `- ${stringifyInline(item)}`).join('\n');
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value);
    if (entries.length === 0) return fallback;
    return entries.map(([key, item]) => `- ${key}: ${stringifyInline(item)}`).join('\n');
  }
  return String(value);
}

function stringifyInline(value) {
  if (value == null) return '없음';
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

async function refreshRoutesIfChanged() {
  const stat = await safeStat(routesPath);
  if (!stat) {
    state.routesCache = {
      mtimeMs: -1,
      routes: {},
    };
    return;
  }

  if (state.routesCache.mtimeMs === stat.mtimeMs) {
    return;
  }

  const raw = await fsp.readFile(routesPath, 'utf8');
  const parsed = JSON.parse(raw);
  const normalizedRoutes = normalizeRoutes(parsed);
  warnRouteCoverage(normalizedRoutes);

  state.routesCache = {
    mtimeMs: stat.mtimeMs,
    routes: normalizedRoutes,
  };
}

function normalizeRoutes(doc) {
  const routeEntries = doc.routes ?? doc;
  const normalized = {};

  for (const [eventName, entry] of Object.entries(routeEntries)) {
    const normalizedEventName = normalizeEventName(eventName);

    if (entry === false || entry == null) {
      normalized[normalizedEventName] = {
        enabled: false,
        lanes: [],
        template: 'generic',
      };
      continue;
    }

    if (typeof entry === 'string') {
      normalized[normalizedEventName] = {
        enabled: true,
        lanes: [normalizeLane(entry)],
        template: normalizedEventName === 'approval_required' ? 'approval_required' : 'generic',
      };
      continue;
    }

    if (Array.isArray(entry)) {
      normalized[normalizedEventName] = {
        enabled: true,
        lanes: entry.map(normalizeLane),
        template: normalizedEventName === 'approval_required' ? 'approval_required' : 'generic',
      };
      continue;
    }

    const lanes = toArray(entry.lanes ?? entry.channels ?? entry.channel ?? []);
    normalized[normalizedEventName] = {
      enabled: entry.enabled !== false,
      lanes: unique(lanes.map(normalizeLane)),
      template:
        entry.template ??
        (normalizedEventName === 'approval_required' ? 'approval_required' : 'generic'),
    };
  }

  return normalized;
}

function warnRouteCoverage(routes) {
  const missing = supportedTaxonomy.filter((eventName) => !Object.hasOwn(routes, eventName));
  if (missing.length > 0) {
    console.warn(
      `[event-flush] routes JSON does not explicitly map these taxonomy events: ${missing.join(', ')}`,
    );
  }
}

function loadWebhookMap() {
  const map = {};

  if (process.env.SLACK_WEBHOOK_URL) {
    map.default = splitCsv(process.env.SLACK_WEBHOOK_URL);
  }

  if (process.env.SLACK_WEBHOOK_URLS_JSON) {
    const parsed = JSON.parse(process.env.SLACK_WEBHOOK_URLS_JSON);
    for (const [lane, value] of Object.entries(parsed)) {
      map[normalizeLane(lane)] = toArray(value).flatMap(splitCsv);
    }
  }

  for (const [key, value] of Object.entries(process.env)) {
    if (!key.startsWith('SLACK_WEBHOOK_URL_')) continue;
    const lane = normalizeLane(key.slice('SLACK_WEBHOOK_URL_'.length));
    map[lane] = splitCsv(value);
  }

  for (const [lane, urls] of Object.entries(map)) {
    map[lane] = unique(urls.filter(Boolean));
  }

  return map;
}

async function bootstrapCursorIfNeeded() {
  const stat = await safeStat(eventsPath);
  if (!stat) return;

  if (!state.cursor.fileId) {
    state.cursor = {
      fileId: serializeFileId(stat),
      seen: bootstrapMode === 'beginning' ? 0 : stat.size,
    };
    await appendStateRecord({
      kind: 'bootstrap',
      file_id: state.cursor.fileId,
      seen: state.cursor.seen,
      mode: bootstrapMode,
    });
  }
}

async function loadLastCursor() {
  const stat = await safeStat(stateLogPath);
  if (!stat) {
    return { fileId: null, seen: 0 };
  }

  const raw = await fsp.readFile(stateLogPath, 'utf8');
  const lines = raw.split('\n').filter(Boolean);

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      const record = JSON.parse(lines[index]);
      if (typeof record.file_id === 'string' && typeof record.seen === 'number') {
        return {
          fileId: record.file_id,
          seen: record.seen,
        };
      }
    } catch {
      // 왜: 상태로그 끝부분 일부가 깨져도 가장 마지막 유효 cursor 로 복구한다.
    }
  }

  return { fileId: null, seen: 0 };
}

async function appendStateRecord(record) {
  await appendJsonLine(stateLogPath, {
    ts: new Date().toISOString(),
    ...record,
  });
}

async function appendDlqRecord(record) {
  await appendJsonLine(dlqPath, record);
}

async function appendJsonLine(filePath, record) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.appendFile(filePath, `${JSON.stringify(record)}\n`, 'utf8');
}

async function ensureDirectories() {
  await fsp.mkdir(path.dirname(stateLogPath), { recursive: true });
  await fsp.mkdir(path.dirname(dlqPath), { recursive: true });
}

async function safeStat(filePath) {
  try {
    return await fsp.stat(filePath);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function readFileRange(filePath, start, end) {
  return new Promise((resolve, reject) => {
    let data = '';
    const stream = fs.createReadStream(filePath, {
      start,
      end,
      encoding: 'utf8',
    });

    stream.on('data', (chunk) => {
      data += chunk;
    });
    stream.on('error', reject);
    stream.on('end', () => resolve(data));
  });
}

function serializeFileId(stat) {
  return `${stat.dev}:${stat.ino}`;
}

function normalizeEventName(eventName) {
  return eventAliases[eventName] ?? eventName;
}

function normalizeLane(raw) {
  return String(raw).trim().toLowerCase().replace(/_/g, '-');
}

function splitCsv(value) {
  return String(value)
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function toArray(value) {
  return Array.isArray(value) ? value : [value];
}

function unique(items) {
  return [...new Set(items)];
}

function compact(items) {
  return items.filter(Boolean);
}

function computeBackoffMs(attempt, retryAfterMs = null) {
  if (Number.isFinite(retryAfterMs) && retryAfterMs > 0) {
    return Math.min(retryAfterMs, maxBackoffMs);
  }
  return Math.min(initialBackoffMs * (2 ** (attempt - 1)), maxBackoffMs);
}

function makeNonRetryable(error) {
  error.nonRetryable = true;
  return error;
}

function makeEventId(event) {
  const basis = JSON.stringify({
    event: event.event,
    session_id: event.session_id,
    worker: event.worker,
    plan_sha256: event.plan_sha256,
    idempotency_key: event.idempotency_key,
    ts: event.ts,
  });
  return crypto.createHash('sha256').update(basis).digest('hex').slice(0, 24);
}

function redactWebhookUrl(url) {
  try {
    const parsed = new URL(url);
    return `${parsed.origin}${parsed.pathname.slice(0, 16)}...`;
  } catch {
    return 'invalid-webhook-url';
  }
}

function truncate(value, maxLength) {
  const text = String(value ?? '');
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1)}…`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// R26 Phase 4b: slack-thread.env 읽어 payload 에 thread_ts 주입 (best-effort, append-only 신설)
//
// 왜:
//   R25 에서 slack-callback 이 approval 버튼 클릭 직후 session 별 slack-thread.env 를 저장.
//   R26 에서는 후속 이벤트(worker_timeout / sentinel_detected / export_promoted 등) 가
//   동일 thread 에 reply 로 이어지도록 payload 에 thread_ts 를 얹는다.
//
// 경계:
//   - 이 함수는 payload 원본을 mutate 한다 (새 객체 생성 비용 절약). event 에 session_id 가 없으면 무동작.
//   - 파일 없음 / 파싱 실패 / SLACK_THREAD_TS 값 없음 → 모두 silent skip.
//   - Slack Incoming Webhook 이 thread_ts 를 honor 하지 않는 경우라도 payload 에 필드가 있는 것만으로는
//     회귀를 유발하지 않는다 (버려짐). 실 workspace 동작 여부는 MANUAL_VERIFY.md 5-3 에서 수동 검증.
//   - path traversal 방어: session_id 는 영숫자/하이픈/언더스코어만 허용 (slack-callback 의 sanitizeSegment 동일 정책).
async function maybeAttachThreadTs(payload, event) {
  try {
    if (!payload || typeof payload !== 'object') return;
    const sessionId = event?.session_id;
    if (!sessionId || typeof sessionId !== 'string') return;

    // sanitize (path traversal 방어)
    const safeSession = sessionId.replace(/[^A-Za-z0-9_\-]/g, '_');
    const threadEnvPath = path.join(runtimeRoot, 'sessions', safeSession, 'slack-thread.env');

    const content = await fsp.readFile(threadEnvPath, 'utf8').catch(() => null);
    if (!content) return;

    // SLACK_THREAD_TS=... 추출. 값은 sanitize 되어 저장되므로 newline/따옴표 없음.
    const match = content.match(/^SLACK_THREAD_TS=([^\r\n]+)$/m);
    if (!match) return;
    const threadTs = match[1].trim();
    if (!threadTs) return;

    // root-level thread_ts 필드 주입 (Slack 공식 필드명).
    // 이미 존재하면 덮어쓰지 않는다 — 상위 빌더가 명시적으로 설정한 값을 존중.
    if (payload.thread_ts == null) {
      payload.thread_ts = threadTs;
    }
  } catch {
    // best-effort: 어떤 예외도 상위로 전파하지 않는다.
  }
}

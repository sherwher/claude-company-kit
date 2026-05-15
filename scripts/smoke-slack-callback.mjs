#!/usr/bin/env node
// scripts/smoke-slack-callback.mjs (R24 신규)
// Node 모듈 import + mock IncomingMessage/ServerResponse 로 handler 4 시나리오 검증.
// 실 Slack workspace 호출 0 건. ssh/github-dispatch 호출 0 건 (REMOTE_EXEC_BACKEND=smoke).
//
// 사용: node scripts/smoke-slack-callback.mjs
// exit 0 = 전 시나리오 PASS, exit 1 = 하나 이상 FAIL.

import crypto from 'node:crypto';
import path from 'node:path';
import { promises as fsp } from 'node:fs';
import os from 'node:os';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── 1. 임시 런타임 디렉토리 + mock compact-plan.json 생성 ──────────────────────
const tmpRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'r24-smoke-'));
const sessionId = 'feature-smoke';
const worker = 'frontend-engineer';
const planDir = path.join(tmpRoot, 'sessions', sessionId, 'workers', worker);
await fsp.mkdir(planDir, { recursive: true });
const planContent = '{"mock":"plan","v":1}\n';
const planBuffer = Buffer.from(planContent, 'utf8');
await fsp.writeFile(path.join(planDir, 'compact-plan.json'), planBuffer);
const realSha = crypto.createHash('sha256').update(planBuffer).digest('hex');

// ── 2. env 주입 (handler import 이전 — top-level await 로 보장) ───────────────
process.env.COMPANY_RUNTIME_ROOT = tmpRoot;
process.env.SLACK_SIGNING_SECRET = 'dev-only-secret-r24-smoke';
process.env.IDEMPOTENCY_BACKEND = 'memory';      // in-process Map (globalThis)
process.env.REMOTE_EXEC_BACKEND = 'smoke';       // 운영본 R24 smoke 분기 사용
process.env.PLAN_SOURCE_BACKEND = 'fs';
process.env.SLACK_REPLAY_WINDOW_SECONDS = '300';

// ── 3. handler import (env lock-in 후) ────────────────────────────────────────
const callbackPath = path.join(__dirname, 'integrations', 'slack', 'slack-callback.mjs');
const mod = await import(callbackPath);
const handler = mod.default;

// ── 4. globalThis idempotency map 초기화 (시나리오 간 격리) ──────────────────
function resetIdempotency() {
  if (globalThis.__companySlackIdempotencyMap) {
    globalThis.__companySlackIdempotencyMap.clear();
  }
}

// ── 5. mock req/res 팩토리 ─────────────────────────────────────────────────────
const SIGNING_SECRET = process.env.SLACK_SIGNING_SECRET;

function makeReq(rawBody, { contentType = 'application/x-www-form-urlencoded', ageOffset = 0 } = {}) {
  const ts = String(Math.floor(Date.now() / 1000) - ageOffset);
  const base = `v0:${ts}:${rawBody}`;
  const sig = 'v0=' + crypto.createHmac('sha256', SIGNING_SECRET).update(base).digest('hex');

  const stream = Readable.from([Buffer.from(rawBody, 'utf8')]);
  // IncomingMessage 호환 속성 부착
  stream.method = 'POST';
  stream.headers = {
    'content-type': contentType,
    'x-slack-request-timestamp': ts,
    'x-slack-signature': sig,
  };
  return stream;
}

function makeRes() {
  return {
    statusCode: 200,
    _headers: {},
    _body: '',
    _done: false,
    setHeader(k, v) { this._headers[k.toLowerCase()] = v; },
    end(s) {
      this._body = String(s ?? '');
      this._done = true;
    },
  };
}

function makePayload({
  action = 'approve',
  planSha = realSha,
  idemKey,
  sessionIdOverride,
  threadTs,
  channelId = 'C_SMOKE',
  messageTs = '1234567890.000000',
} = {}) {
  const sid = sessionIdOverride ?? sessionId;
  const key = idemKey ?? `${sid}:${worker}:${planSha.slice(0, 8)}`;
  const actionId = `${action}|${sid}|${worker}|${planSha}|${key}`;
  const value = JSON.stringify({
    session_id: sid,
    worker,
    plan_sha256: planSha,
    idempotency_key: key,
  });
  const message = { ts: messageTs };
  if (threadTs) message.thread_ts = threadTs;
  const payload = {
    type: 'block_actions',
    user: { id: 'U_SMOKE', username: 'smoke-leader' },
    channel: { id: channelId },
    message,
    actions: [{ action_id: actionId, value }],
  };
  return 'payload=' + encodeURIComponent(JSON.stringify(payload));
}

// ── 6. 시나리오 실행 헬퍼 ──────────────────────────────────────────────────────
async function runScenario(name, rawBody, reqOpts = {}) {
  const req = makeReq(rawBody, reqOpts);
  const res = makeRes();
  try {
    await handler(req, res);
  } catch (err) {
    return { name, statusCode: 500, body: `[handler threw] ${err.message}`, error: err };
  }
  let parsed = null;
  try {
    parsed = JSON.parse(res._body);
  } catch {
    // text/plain 응답
  }
  return {
    name,
    statusCode: res.statusCode,
    body: res._body,
    text: parsed?.text ?? res._body,
  };
}

// ── 7. 4 시나리오 실행 ────────────────────────────────────────────────────────
const results = [];
let failed = 0;

function assert(r, condition, description) {
  if (condition) {
    console.log(`  PASS  ${description}`);
  } else {
    console.error(`  FAIL  ${description}`);
    console.error(`        statusCode=${r.statusCode} text=${JSON.stringify(r.text).slice(0, 200)}`);
    failed += 1;
  }
}

// ─── 시나리오 A: approve 정상 ──────────────────────────────────────────────────
console.log('\n[A] approve 정상');
resetIdempotency();
{
  const rawBody = makePayload({ action: 'approve', planSha: realSha });
  const r = await runScenario('A-approve', rawBody);
  results.push(r);
  assert(r, r.statusCode === 200, 'statusCode=200');
  assert(r, r.text.includes('승인 완료'), `text includes '승인 완료'`);
}

// ─── 시나리오 B: reject 정상 ──────────────────────────────────────────────────
console.log('\n[B] reject 정상');
resetIdempotency();
{
  const rawBody = makePayload({ action: 'reject', planSha: realSha });
  const r = await runScenario('B-reject', rawBody);
  results.push(r);
  assert(r, r.statusCode === 200, 'statusCode=200');
  assert(r, r.text.includes('거절 완료'), `text includes '거절 완료'`);
}

// ─── 시나리오 C: stale plan ────────────────────────────────────────────────────
console.log('\n[C] stale plan');
resetIdempotency();
{
  const staleSha = 'deadbeef'.repeat(8); // 64자 hex, 실제 sha 와 불일치
  const rawBody = makePayload({ action: 'approve', planSha: staleSha });
  const r = await runScenario('C-stale', rawBody);
  results.push(r);
  assert(r, r.statusCode === 200, 'statusCode=200');
  assert(r, r.text.includes('만료된 계획서'), `text includes '만료된 계획서'`);
}

// ─── 시나리오 D: duplicate (동일 idem_key 2회 연속) ──────────────────────────
console.log('\n[D] duplicate');
resetIdempotency();
{
  const idemKey = `${sessionId}:${worker}:${realSha.slice(0, 8)}`;
  const rawBody = makePayload({ action: 'approve', planSha: realSha, idemKey });

  // 첫 번째 요청
  const r1 = await runScenario('D-first', rawBody);
  results.push(r1);
  assert(r1, r1.statusCode === 200, '[1st] statusCode=200');
  assert(r1, r1.text.includes('승인 완료'), `[1st] text includes '승인 완료'`);

  // 두 번째 요청 (동일 idem_key — 중복 감지)
  const r2 = await runScenario('D-duplicate', rawBody);
  results.push(r2);
  assert(r2, r2.statusCode === 200, '[2nd] statusCode=200');
  assert(r2, r2.text.includes('이미 처리 중인 요청'), `[2nd] text includes '이미 처리 중인 요청'`);
}

// ─── 시나리오 E (R25 Phase 4a): thread_ts 영속화 검증 ────────────────────────
// 별도 session id + 명시 thread_ts 페이로드 → `.company-runtime/sessions/{id}/slack-thread.env`
// 파일이 생성되고 기대 값을 포함하는지 확인.
console.log('\n[E] thread_ts persist (R25 Phase 4a)');
resetIdempotency();
{
  const threadSessionId = 'feature-smoke-thread';
  const threadPlanDir = path.join(tmpRoot, 'sessions', threadSessionId, 'workers', worker);
  await fsp.mkdir(threadPlanDir, { recursive: true });
  await fsp.writeFile(path.join(threadPlanDir, 'compact-plan.json'), planBuffer);
  const expectedThreadTs = '1700000000.111111';
  const expectedChannelId = 'C_R25_THREAD';
  const rawBody = makePayload({
    action: 'approve',
    planSha: realSha,
    sessionIdOverride: threadSessionId,
    threadTs: expectedThreadTs,
    channelId: expectedChannelId,
    messageTs: '1700000001.222222',
  });
  const r = await runScenario('E-thread-persist', rawBody);
  results.push(r);
  assert(r, r.statusCode === 200, 'statusCode=200');
  assert(r, r.text.includes('승인 완료'), `text includes '승인 완료'`);

  const envPath = path.join(tmpRoot, 'sessions', threadSessionId, 'slack-thread.env');
  let envExists = false;
  let envContent = '';
  try {
    envContent = await fsp.readFile(envPath, 'utf8');
    envExists = true;
  } catch {}
  assert(r, envExists, `slack-thread.env 파일 생성됨 (${envPath})`);
  assert(r, envContent.includes(`SLACK_THREAD_TS=${expectedThreadTs}`), `SLACK_THREAD_TS=${expectedThreadTs}`);
  assert(r, envContent.includes(`SLACK_CHANNEL_ID=${expectedChannelId}`), `SLACK_CHANNEL_ID=${expectedChannelId}`);
  assert(r, envContent.includes(`SLACK_SESSION_ID=${threadSessionId}`), `SLACK_SESSION_ID=${threadSessionId}`);
}

// ── 8. 임시 디렉토리 정리 ─────────────────────────────────────────────────────
await fsp.rm(tmpRoot, { recursive: true, force: true });

// ── 9. 결과 요약 + exit code ──────────────────────────────────────────────────
console.log('\n─────────────────────────────────────────');
const total = 16; // A×2 + B×2 + C×2 + D×4 + E×6 / 총 assert 호출 수 (R25 Phase 4a)
const passed = total - failed;
console.log(`결과: ${passed}/${total} PASS  ${failed} FAIL`);

if (failed === 0) {
  console.log('smoke-slack-callback: ALL PASS');
  process.exit(0);
} else {
  console.error('smoke-slack-callback: FAIL');
  process.exit(1);
}

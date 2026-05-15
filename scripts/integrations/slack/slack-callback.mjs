// scripts/integrations/slack/slack-callback.mjs (R24 이관본 — archive 원본: docs/design/archive/R3-R4-original-drafts/slack-callback.mjs)
// R24 경계: 이 파일은 HTTP 서버 런타임을 내장하지 않는다. 배포는 사용자 책임 (Vercel/CF Workers/Lambda 등).
//          운영 위치에서는 한국어 §5 패치 7 개소 + smoke backend 분기만 적용. HMAC / idempotency / remote-exec backend 전수 보존.
//          backend=smoke 는 smoke-slack-callback.mjs 전용. 운영 배포 시 ssh/github-dispatch 만 허용.
// api/slack-callback.mjs
import crypto from 'node:crypto';
import path from 'node:path';
import { promises as fsp } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const runtimeRoot = process.env.COMPANY_RUNTIME_ROOT ?? '.company-runtime';
const remoteExecBackend = process.env.REMOTE_EXEC_BACKEND ?? 'ssh'; // 'ssh' | 'github-dispatch'
const planSourceBackend = process.env.PLAN_SOURCE_BACKEND ?? 'fs'; // 'fs' | 'ssh'
const idempotencyBackend =
  process.env.IDEMPOTENCY_BACKEND ??
  (remoteExecBackend === 'github-dispatch' ? 'github-ref' : remoteExecBackend === 'ssh' ? 'ssh-lock' : 'memory');

const slackSigningSecret = process.env.SLACK_SIGNING_SECRET ?? '';
const replayWindowSeconds = Number(process.env.SLACK_REPLAY_WINDOW_SECONDS ?? 300);

const sshHost = process.env.SSH_HOST ?? '';
const sshUser = process.env.SSH_USER ?? '';
const sshPort = Number(process.env.SSH_PORT ?? 22);
const sshProjectRoot = process.env.SSH_PROJECT_ROOT ?? '';
const sshRuntimeRoot = process.env.SSH_RUNTIME_ROOT ?? '.company-runtime';
const sshTimeoutMs = Number(process.env.SSH_TIMEOUT_MS ?? 8000);

const githubRepo = process.env.GITHUB_REPO ?? ''; // owner/repo
const githubToken = process.env.GITHUB_TOKEN ?? '';
const githubApiBase = process.env.GITHUB_API_BASE ?? 'https://api.github.com';
const githubDispatchApproveType = process.env.GITHUB_DISPATCH_APPROVE_TYPE ?? 'company-approve';
const githubDispatchRejectType = process.env.GITHUB_DISPATCH_REJECT_TYPE ?? 'company-reject';

const localMemoryIdempotency = globalThis.__companySlackIdempotencyMap ?? new Map();
globalThis.__companySlackIdempotencyMap = localMemoryIdempotency;

// 왜: Next.js 스타일로 끼워 넣는 경우 body parser 를 끄지 않으면 raw body 서명 검증이 깨진다.
export const config = {
  api: {
    bodyParser: false,
  },
};

export default async function handler(req, res) {
  try {
    if (req.method !== 'POST') {
      return sendJson(res, 405, { error: 'method_not_allowed' });
    }

    if (!slackSigningSecret) {
      return sendJson(res, 500, { error: 'missing_slack_signing_secret' });
    }

    const rawBodyBuffer = await readRawBody(req);
    const rawBody = rawBodyBuffer.toString('utf8');

    const verification = verifySlackRequest({
      headers: req.headers,
      rawBody,
      signingSecret: slackSigningSecret,
      replayWindowSeconds,
    });

    if (!verification.ok) {
      // R24 §5 패치: slack_request_too_old 는 모바일 한국어 메시지로 교체. 그 외 401/405/500 은 원문 유지.
      if (verification.message === 'slack_request_too_old') {
        return sendSlackEphemeral(res, [
          '보안 세션이 만료되었습니다. 다시 승인을 요청하십시오.',
          '버튼 생성 후 5분이 경과했습니다. 계획서를 재발행하십시오.',
        ].join('\n'));
      }
      return sendText(res, verification.statusCode, verification.message);
    }

    const payload = parseSlackPayload(rawBody, getHeader(req.headers, 'content-type'));
    const actionContext = extractActionContext(payload);

    const currentPlan = await loadCurrentPlan(actionContext);
    const currentPlanSha256 = sha256(currentPlan);

    if (currentPlanSha256 !== actionContext.planSha256) {
      return sendSlackEphemeral(res, [
        '만료된 계획서입니다. 최신 메시지의 승인 버튼을 누르십시오.',
        '워커가 계획을 수정하여 이전 버튼이 무효화되었습니다. 채널 하단의 새 메시지를 확인하십시오.',
        `현재 plan_sha256=${currentPlanSha256}`,
        `클릭된 plan_sha256=${actionContext.planSha256}`,
      ].join('\n'));
    }

    // R25 Phase 4a §6: thread_ts persist — 계획서 sha 검증 통과 직후, idempotency claim 이전에
    // best-effort 로 Slack thread 컨텍스트를 `.company-runtime/sessions/{id}/slack-thread.env` 에 기록.
    // 이후 worker_timeout / sentinel_detected 등 후속 이벤트가 동일 thread 에 reply 하기 위함.
    // 실패는 무시 (best-effort) — callback 주 흐름을 막지 않는다.
    try {
      await persistSlackThread({
        sessionId: actionContext.sessionId,
        threadTs: payload.message?.thread_ts ?? payload.message?.ts ?? '',
        channelId: payload.channel?.id ?? '',
        messageTs: payload.message?.ts ?? '',
      });
    } catch (threadPersistError) {
      console.warn('[slack-callback] thread_ts persist skipped:', threadPersistError.message);
    }

    const claim = await claimIdempotency({
      key: actionContext.idempotencyKey,
      action: actionContext.action,
      sessionId: actionContext.sessionId,
      worker: actionContext.worker,
      actorId: payload.user?.id ?? 'unknown',
    });

    if (!claim.ok) {
      return sendSlackEphemeral(
        res,
        [
          '이미 처리 중인 요청입니다. 잠시만 기다려 주십시오.',
          '네트워크 지연으로 처리가 늦어질 수 있습니다. 중복 클릭은 무시되니 결과 반영을 기다리십시오.',
          `중복방지키: ${actionContext.idempotencyKey}`,
        ].join('\n'),
      );
    }

    const remoteResult = await runRemoteAction({
      actionContext,
      payload,
      currentPlanSha256,
    });

    if (!remoteResult.ok) {
      // 왜: Slack 재시도로 인한 중복 실행을 막기 위해 200으로 응답하되,
      // 원격 처리 실패 사실을 명시한다. idempotency lock 은 그대로 유지한다.
      return sendSlackEphemeral(
        res,
        [
          '승인 실패. 원격 서버 연결 상태를 확인하십시오.',
          '중복 클릭은 차단됩니다. 운영자가 로그를 확인해 수동 복구하십시오.',
          `backend=${remoteExecBackend}`,
          `reason=${remoteResult.error}`,
        ].join('\n'),
      );
    }

    return sendSlackEphemeral(
      res,
      actionContext.action === 'approve'
        ? `승인 완료. 요청을 정상 처리했습니다. (세션: ${actionContext.sessionId} / 워커: ${actionContext.worker})`
        : `거절 완료. 요청을 정상 처리했습니다. (세션: ${actionContext.sessionId} / 워커: ${actionContext.worker})`,
    );
  } catch (error) {
    console.error('[slack-callback] unhandled error:', error);
    return sendSlackEphemeral(
      res,
      [
        '시스템 오류. 잠시 후 다시 시도하십시오.',
        `운영자에게 다음 오류를 전달하십시오: ${error.message}`,
      ].join('\n'),
    );
  }
}

function verifySlackRequest({ headers, rawBody, signingSecret, replayWindowSeconds: maxAgeSeconds }) {
  const timestamp = getHeader(headers, 'x-slack-request-timestamp');
  const signature = getHeader(headers, 'x-slack-signature');

  if (!timestamp || !signature) {
    return {
      ok: false,
      statusCode: 401,
      message: 'missing_slack_signature_headers',
    };
  }

  const timestampNumber = Number(timestamp);
  if (!Number.isFinite(timestampNumber)) {
    return {
      ok: false,
      statusCode: 401,
      message: 'invalid_slack_timestamp',
    };
  }

  const ageSeconds = Math.abs(Math.floor(Date.now() / 1000) - timestampNumber);
  if (ageSeconds > maxAgeSeconds) {
    return {
      ok: false,
      statusCode: 401,
      message: 'slack_request_too_old',
    };
  }

  const base = `v0:${timestamp}:${rawBody}`;
  const expected = `v0=${crypto.createHmac('sha256', signingSecret).update(base).digest('hex')}`;

  const actualBuffer = Buffer.from(signature, 'utf8');
  const expectedBuffer = Buffer.from(expected, 'utf8');

  const valid =
    actualBuffer.length === expectedBuffer.length &&
    crypto.timingSafeEqual(actualBuffer, expectedBuffer);

  if (!valid) {
    return {
      ok: false,
      statusCode: 401,
      message: 'invalid_slack_signature',
    };
  }

  return { ok: true };
}

function parseSlackPayload(rawBody, contentType = '') {
  if (contentType.includes('application/json')) {
    return JSON.parse(rawBody);
  }

  if (contentType.includes('application/x-www-form-urlencoded')) {
    const params = new URLSearchParams(rawBody);
    const payloadParam = params.get('payload');
    if (!payloadParam) {
      throw new Error('form payload 에 payload 필드가 없습니다');
    }
    return JSON.parse(payloadParam);
  }

  throw new Error(`지원하지 않는 content-type 입니다: ${contentType}`);
}

function extractActionContext(payload) {
  const action = payload.actions?.[0];
  if (!action) {
    throw new Error('Slack actions[0] 가 없습니다');
  }

  const actionId = String(action.action_id ?? '');
  const parts = actionId.split('|');
  const actionName = normalizeActionName(parts[0]);

  if (!actionName) {
    throw new Error(`지원하지 않는 action_id 입니다: ${actionId}`);
  }

  let value = {};
  if (action.value) {
    value = JSON.parse(action.value);
  }

  const sessionId = value.session_id ?? parts[1];
  const worker = value.worker ?? parts[2];
  const planSha256 = value.plan_sha256 ?? parts[3];
  const idempotencyKey = value.idempotency_key ?? parts[4];

  if (!sessionId || !worker || !planSha256 || !idempotencyKey) {
    throw new Error('session_id / worker / plan_sha256 / idempotency_key 중 일부가 없습니다');
  }

  return {
    action: actionName,
    sessionId,
    worker,
    planSha256,
    idempotencyKey,
    actionId,
  };
}

function normalizeActionName(raw) {
  if (raw === 'approve') return 'approve';
  if (raw === 'reject') return 'reject';
  return null;
}

async function loadCurrentPlan(actionContext) {
  if (planSourceBackend === 'ssh') {
    return loadCurrentPlanOverSsh(actionContext);
  }

  const planPath = path.join(
    runtimeRoot,
    'sessions',
    actionContext.sessionId,
    'workers',
    actionContext.worker,
    'compact-plan.json',
  );

  return fsp.readFile(planPath);
}

async function loadCurrentPlanOverSsh(actionContext) {
  ensureSshConfigured();

  const remotePlanPath = posixJoin(
    sshRuntimeRoot,
    'sessions',
    actionContext.sessionId,
    'workers',
    actionContext.worker,
    'compact-plan.json',
  );

  const command = `cat ${shellQuote(remotePlanPath)}`;
  const { stdout } = await execFileAsync(
    'ssh',
    buildSshArgs(`bash -lc ${shellQuote(command)}`),
    { timeout: sshTimeoutMs, maxBuffer: 2 * 1024 * 1024 },
  );

  return Buffer.from(stdout, 'utf8');
}

async function claimIdempotency({ key, action, sessionId, worker, actorId }) {
  if (idempotencyBackend === 'memory') {
    if (localMemoryIdempotency.has(key)) {
      return { ok: false, reason: 'duplicate' };
    }
    localMemoryIdempotency.set(key, {
      action,
      sessionId,
      worker,
      actorId,
      claimed_at: new Date().toISOString(),
    });
    return { ok: true };
  }

  if (idempotencyBackend === 'ssh-lock') {
    ensureSshConfigured();
    const lockDir = posixJoin(sshRuntimeRoot, 'slack-idempotency');
    const lockPath = posixJoin(lockDir, `${sanitizeKey(key)}.json`);
    const payload = JSON.stringify({
      key,
      action,
      sessionId,
      worker,
      actorId,
      claimed_at: new Date().toISOString(),
    });

    const remoteScript = [
      `mkdir -p ${shellQuote(lockDir)}`,
      `if [ -e ${shellQuote(lockPath)} ]; then`,
      '  echo duplicate',
      '  exit 10',
      'fi',
      `umask 077 && printf '%s' ${shellQuote(payload)} > ${shellQuote(lockPath)}`,
      'echo claimed',
    ].join('; ');

    try {
      await execFileAsync(
        'ssh',
        buildSshArgs(`bash -lc ${shellQuote(remoteScript)}`),
        { timeout: sshTimeoutMs, maxBuffer: 1024 * 1024 },
      );
      return { ok: true };
    } catch (error) {
      if (error.code === 10 || String(error.stderr ?? '').includes('duplicate')) {
        return { ok: false, reason: 'duplicate' };
      }
      return { ok: false, reason: error.message };
    }
  }

  if (idempotencyBackend === 'github-ref') {
    const refName = `refs/tags/company-idempotency-${sanitizeKey(key)}`;
    const headSha = await getGithubDefaultBranchHeadSha();

    const response = await githubRequest(`/repos/${githubRepo}/git/refs`, {
      method: 'POST',
      body: {
        ref: refName,
        sha: headSha,
      },
      allow422: true,
    });

    if (response.status === 422) {
      return { ok: false, reason: 'duplicate' };
    }

    return { ok: true };
  }

  throw new Error(`지원하지 않는 IDEMPOTENCY_BACKEND 입니다: ${idempotencyBackend}`);
}

async function runRemoteAction({ actionContext, payload, currentPlanSha256 }) {
  // R24 (운영본 전용): smoke backend — smoke-slack-callback.mjs 전용 mock. 운영 배포 시 절대 사용 금지.
  if (remoteExecBackend === 'smoke') {
    return { ok: true, stdout: 'smoke-mocked', stderr: '' };
  }

  if (remoteExecBackend === 'ssh') {
    return runRemoteActionOverSsh({ actionContext, payload, currentPlanSha256 });
  }

  if (remoteExecBackend === 'github-dispatch') {
    return runRemoteActionOverGithubDispatch({ actionContext, payload, currentPlanSha256 });
  }

  throw new Error(`지원하지 않는 REMOTE_EXEC_BACKEND 입니다: ${remoteExecBackend}`);
}

async function runRemoteActionOverSsh({ actionContext, payload, currentPlanSha256 }) {
  ensureSshConfigured();

  // 왜: 현재 CLI 계약을 과도하게 가정하지 않기 위해, 상세 메타는 env 로 전달하고
  // 실제 호출 명령은 company approve / company reject 로만 고정한다.
  const envPrefix = buildEnvExports({
    COMPANY_APPROVAL_ACTION: actionContext.action,
    COMPANY_APPROVAL_SESSION_ID: actionContext.sessionId,
    COMPANY_APPROVAL_WORKER: actionContext.worker,
    COMPANY_APPROVAL_PLAN_SHA256: currentPlanSha256,
    COMPANY_APPROVAL_IDEMPOTENCY_KEY: actionContext.idempotencyKey,
    COMPANY_APPROVAL_ACTOR_ID: payload.user?.id ?? '',
    COMPANY_APPROVAL_ACTOR_NAME: payload.user?.username ?? payload.user?.name ?? '',
    COMPANY_APPROVAL_SOURCE: 'slack-interactive',
    COMPANY_APPROVAL_MESSAGE_TS: payload.message?.ts ?? '',
    COMPANY_APPROVAL_CHANNEL_ID: payload.channel?.id ?? '',
  });

  const companyCommand =
    actionContext.action === 'approve'
      ? `company approve ${shellQuote(actionContext.sessionId)}`
      : `company reject ${shellQuote(actionContext.sessionId)}`;

  const script = [
    envPrefix,
    sshProjectRoot ? `cd ${shellQuote(sshProjectRoot)}` : '',
    companyCommand,
  ].filter(Boolean).join(' && ');

  try {
    const result = await execFileAsync(
      'ssh',
      buildSshArgs(`bash -lc ${shellQuote(script)}`),
      { timeout: sshTimeoutMs, maxBuffer: 2 * 1024 * 1024 },
    );

    return {
      ok: true,
      stdout: result.stdout,
      stderr: result.stderr,
    };
  } catch (error) {
    return {
      ok: false,
      error: [
        error.message,
        truncate(String(error.stderr ?? ''), 600),
      ].filter(Boolean).join(' | '),
    };
  }
}

async function runRemoteActionOverGithubDispatch({ actionContext, payload, currentPlanSha256 }) {
  if (!githubRepo || !githubToken) {
    throw new Error('GITHUB_REPO 와 GITHUB_TOKEN 이 필요합니다');
  }

  const eventType =
    actionContext.action === 'approve'
      ? githubDispatchApproveType
      : githubDispatchRejectType;

  const response = await githubRequest(`/repos/${githubRepo}/dispatches`, {
    method: 'POST',
    body: {
      event_type: eventType,
      client_payload: {
        session_id: actionContext.sessionId,
        worker: actionContext.worker,
        plan_sha256: currentPlanSha256,
        idempotency_key: actionContext.idempotencyKey,
        decision: actionContext.action,
        actor: {
          id: payload.user?.id ?? null,
          username: payload.user?.username ?? payload.user?.name ?? null,
        },
        source: {
          type: 'slack-interactive',
          action_id: actionContext.actionId,
          channel_id: payload.channel?.id ?? null,
          message_ts: payload.message?.ts ?? null,
        },
      },
    },
  });

  if (response.status >= 200 && response.status < 300) {
    return { ok: true };
  }

  return {
    ok: false,
    error: `github dispatch failed: status=${response.status} body=${truncate(JSON.stringify(response.body), 500)}`,
  };
}

async function getGithubDefaultBranchHeadSha() {
  const repoInfo = await githubRequest(`/repos/${githubRepo}`, { method: 'GET' });
  const defaultBranch = repoInfo.body.default_branch;
  const refInfo = await githubRequest(`/repos/${githubRepo}/git/ref/heads/${encodeURIComponent(defaultBranch)}`, {
    method: 'GET',
  });
  return refInfo.body.object.sha;
}

async function githubRequest(apiPath, options) {
  if (!githubRepo || !githubToken) {
    throw new Error('GitHub API 호출에는 GITHUB_REPO 와 GITHUB_TOKEN 이 필요합니다');
  }

  const response = await fetch(`${githubApiBase}${apiPath}`, {
    method: options.method,
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${githubToken}`,
      'content-type': 'application/json',
      'user-agent': 'ai-company-slack-callback',
      'x-github-api-version': '2022-11-28',
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  let body = null;
  const rawText = await response.text();
  if (rawText) {
    try {
      body = JSON.parse(rawText);
    } catch {
      body = rawText;
    }
  }

  if (!response.ok && !(options.allow422 && response.status === 422)) {
    throw new Error(`GitHub API ${response.status}: ${truncate(JSON.stringify(body), 500)}`);
  }

  return {
    status: response.status,
    body,
  };
}

function buildSshArgs(remoteCommand) {
  const target = sshUser ? `${sshUser}@${sshHost}` : sshHost;
  return [
    '-p',
    String(sshPort),
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    target,
    remoteCommand,
  ];
}

function ensureSshConfigured() {
  if (!sshHost) {
    throw new Error('SSH backend 를 쓰려면 SSH_HOST 가 필요합니다');
  }
}

function buildEnvExports(entries) {
  return Object.entries(entries)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${shellQuote(String(value))}`)
    .join(' ');
}

function posixJoin(...parts) {
  return parts.filter(Boolean).join('/').replace(/\/+/g, '/');
}

function sanitizeKey(value) {
  const normalized = String(value)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);

  if (normalized) return normalized;

  return crypto.createHash('sha256').update(String(value)).digest('hex').slice(0, 24);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function getHeader(headers, name) {
  const value = headers[name] ?? headers[name.toLowerCase()] ?? headers[name.toUpperCase()];
  return Array.isArray(value) ? value[0] : value;
}

async function readRawBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

function sendSlackEphemeral(res, text) {
  return sendJson(res, 200, {
    response_type: 'ephemeral',
    replace_original: false,
    text,
  });
}

function sendJson(res, statusCode, body) {
  res.statusCode = statusCode;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body));
}

function sendText(res, statusCode, text) {
  res.statusCode = statusCode;
  res.setHeader('content-type', 'text/plain; charset=utf-8');
  res.end(text);
}

function truncate(value, maxLength) {
  const text = String(value ?? '');
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1)}…`;
}

// R25 Phase 4a §6: Slack thread_ts / channel_id 영속화 (append-only 신설)
// 저장 위치: `${runtimeRoot}/sessions/{sessionId}/slack-thread.env`
// 포맷: `KEY=VALUE\n` shell env 호환 (bash `source` 가능). 값은 newline 을 허용하지 않도록 sanitize.
// 멱등: 동일 session_id 에 여러 번 callback 이 오면 최신값으로 덮어씀. 기존 파일 존재 시 덮어쓰기 허용.
// 비밀값 아님 (thread_ts/channel_id 는 Slack 공개 식별자). 파일 권한 0600 으로 보수적으로 설정.
// 실패는 모두 상위에서 warn 으로 흡수 (best-effort).
async function persistSlackThread({ sessionId, threadTs, channelId, messageTs }) {
  if (!sessionId) {
    throw new Error('missing_session_id');
  }
  if (!threadTs && !channelId) {
    // 저장할 값이 아예 없으면 무동작 (경고 없이 정상 종료)
    return;
  }

  const sessionDir = path.join(runtimeRoot, 'sessions', sanitizeSegment(sessionId));
  await fsp.mkdir(sessionDir, { recursive: true });

  const envPath = path.join(sessionDir, 'slack-thread.env');
  const lines = [
    `# R25 Phase 4a — slack callback 수신 시 자동 기록 (append-only 신설)`,
    `# 이 파일은 후속 이벤트(worker_timeout / sentinel_detected 등)가 동일 thread 에 reply 하기 위한 컨텍스트입니다.`,
    `SLACK_SESSION_ID=${sanitizeEnvValue(sessionId)}`,
    `SLACK_THREAD_TS=${sanitizeEnvValue(threadTs)}`,
    `SLACK_CHANNEL_ID=${sanitizeEnvValue(channelId)}`,
    `SLACK_MESSAGE_TS=${sanitizeEnvValue(messageTs)}`,
    `SLACK_PERSISTED_AT=${new Date().toISOString()}`,
    '',
  ];

  await fsp.writeFile(envPath, lines.join('\n'), { mode: 0o600 });
}

function sanitizeSegment(value) {
  // path traversal 방어 — 세션 ID 는 영숫자/하이픈/언더스코어만 허용.
  return String(value ?? '').replace(/[^A-Za-z0-9_\-]/g, '_');
}

function sanitizeEnvValue(value) {
  // env 라인 주입 방어 — 줄바꿈/역슬래시/쌍따옴표 제거.
  return String(value ?? '').replace(/[\r\n"\\]/g, '');
}

# Slack integration — R22 계약 (outbound only scaffold)

> "신호는 많음이 아니라 도달로 증명되며, 수신자 없는 이벤트는 폐기된 판단이다."
> — R22 직인 (codex 5안)

---

## 현재 상태 (R23 기준)

| 항목 | 상태 |
| :--- | :--- |
| opt-in | **OFF** (`config/integrations.yaml: slack.enabled: false`) |
| doctor [10/10] | **SKIPPED** (opt-in OFF 시 정상) / **ACTIVE** (enabled=true + node + sidecar + routes check 시) |
| 실제 webhook dispatch | **실재화** — `event-flush.mjs --once` (one-shot) |
| Slack 코드 파일 | **event-flush.mjs** (R23 이관 완료, 888 LOC) |
| HMAC 서명 검증 | **없음** — R24 이월 (`slack-callback.mjs` HTTP 서버 런타임 비정합) |
| slack-callback.mjs | **없음** — archive 보존만 (`docs/design/archive/R3-R4-original-drafts/`) |

---

## R22 계약 범위

R22 는 **"Slack 을 붙이는 세션이 아니라, 붙여도 harness 가 오염되지 않도록 계약을 닫는 세션"** 입니다.

이 세션에서 완료된 것:
- 11 canonical 이벤트 × severity × lane × 한국어 메시지 템플릿 정본 선언
- `config/integrations.yaml` opt-in 스캐폴드 (enabled: false 기본)
- `scripts/validate-integrations-config.sh` 구조 검증기
- `scripts/doctor.sh` [10/10] Slack integration health 섹션
- `.company-local.env.example` Slack 비밀값 가이드 (주석 처리)
- `.gitignore` secret 파일 차단 규칙

이 세션에서 하지 않은 것 (R23 범위):
- `slack-callback.mjs` (601 LOC) 이관 — archive 에만 보존 중
- `event-flush.mjs` (861 LOC) 이관 — archive 에만 보존 중
- 실제 webhook dispatch 구현
- block-kit 승인/거절 버튼
- HMAC 서명 검증 (SLACK_SIGNING_SECRET)
- DLQ / retry / backoff
- 7 canonical 이벤트 emit call site 추가

---

## 계약 문서 포인터

| 문서 | 경로 | 내용 |
| :--- | :--- | :--- |
| 알림 정책 정본 | `docs/operations/notification-policy.md` | 11 이벤트 × severity × 한국어 템플릿 × payload schema × alias |
| 연동 설정 SSOT | `config/integrations.yaml` | opt-in flag / lanes / routes / event_aliases |
| 비밀값 가이드 | `.company-local.env.example` | SLACK_WEBHOOK_URL 등 env key 목록 (주석 처리) |
| archive 코드 | `docs/design/archive/R3-R4-original-drafts/slack-callback.mjs` | R23 이관 예정 (601 LOC) |
| archive 코드 | `docs/design/archive/R3-R4-original-drafts/event-flush.mjs` | R23 이관 예정 (861 LOC) |

---

## R23 완료 — 이 디렉토리 현재 상태

```
scripts/integrations/slack/
├── README.md          ← 이 파일 (R23 업데이트)
└── event-flush.mjs    ← R23 이관 완료 (888 LOC, --once/--check 패치 포함)
```

`slack-callback.mjs` 이관 보류 사유: Next.js/Vercel HTTP 핸들러 시그니처로 설계됨.
bash harness 에 HTTP 서버 런타임이 없어 구조적 비정합. R24 에서 별도 설계 후 이관.

---

## R23 — outbound 실재화 (축 2 2단계)

> "도달은 경로의 존재로만 증명된다." — R23 직인

### R23 에서 완료된 것

- `scripts/integrations/slack/event-flush.mjs` — archive 에서 이관 (copy). `--once`/`--check` 플래그 추가.
  - `--once`: 1 회 flush 후 `process.exit(0)`. bash harness `company-emit.sh` 직후 호출. daemon/launchd 금지.
  - `--check`: `routes.json` 파싱 dry-run 후 `process.exit(0)`. doctor [10/10] ACTIVE 실재화용.
- `scripts/generate-slack-routes-json.sh` — bash/awk 좁은 파서. `config/integrations.yaml` → `.company-runtime/harness/slack-routes.json` 렌더. Node deps 0.
- `scripts/company-emit.sh` — opt-in one-shot flush hook 추가. `slack.enabled=false` 시 complete silent skip.
- `scripts/prepare-worker.sh` — `spawn_success` / `spawn_failure` emit 추가 (trap 기반).
- `scripts/company-approve.sh` — `plan_validated` emit + `--reject` 플래그 (`rejected` emit).
- `scripts/smoke-slack-dispatch.sh` — python3 mock webhook E2E smoke.
- `scripts/doctor.sh` [10/10] ACTIVE 분기 — node + 사이드카 + `--check` dry-run 실재화.

### R23 에서 하지 않은 것 (R24+ 이월)

- `slack-callback.mjs` 이관 — HTTP 서버 런타임 비정합 (R24 설계 필요)
- 승인 버튼 E2E smoke (Slack → callback → company-approve 원격 실행)
- `approval_required` / `export_promoted` / `sentinel_detected` / `worker_timeout` emit wiring
- Telegram 연동 (R24 범위)

---

## 비밀값 관리

실제 Slack 비밀값은 `.company-local.env.example` 의 Slack 섹션을 참조하십시오.
값은 `.company-local.env` (gitignore 적용) 에만 보관하고, 절대 커밋하지 마십시오.

활성화 절차 (R23 완료 후):
1. `.company-local.env` 에 `SLACK_WEBHOOK_URL` 등 env 설정
2. `config/integrations.yaml` 의 `slack.enabled: false` → `true` 변경
3. `bash scripts/doctor.sh` 실행 → [10/10] = `ACTIVE` (node + 사이드카 + routes check)
4. `bash scripts/company-emit.sh <event> <session_id>` 호출 시 자동 one-shot flush

---

## R24 — Slack callback + approval_required + mock E2E (축 2 3단계)

> "귀환은 경로의 순환으로 증명되며, 순환은 주체의 수용으로 완성된다." — R24 직인

### R24 에서 완료된 것

- `scripts/integrations/slack/slack-callback.mjs` — archive 에서 **무수정 copy** + 한국어 §5 패치 7 개소 + smoke backend 분기.
  - HMAC 서명 검증 / idempotency backend / remote-exec backend (ssh / github-dispatch) 전수 보존
  - 모바일 UX 메시지 3 케이스 (stale plan / 중복 클릭 / replay window 초과) 한국어 교정
  - `backend=smoke` 분기: `smoke-slack-callback.mjs` 전용 mock. 운영 배포 시 ssh/github-dispatch 만 허용.
- `scripts/company-approve.sh` — `approval_required` emit 1 건 추가 (compact-plan 검증 직후, plan_failed=0 엄격 분기).
- `scripts/smoke-slack-callback.mjs` — Node 모듈 import + mock req/res, 4 시나리오 전수 PASS (8/8).
- `scripts/doctor.sh` [10/10] — callback 분기 추가 (존재 + `node --check` + SLACK_SIGNING_SECRET warn).
- `scripts/integrations/slack/slack-callback-notes.md` — HTTP 런타임 경계 선언.

### HTTP 런타임 경계 (R24 핵심 결정)

`slack-callback.mjs` 는 **Next.js-style handler signature** `async function handler(req, res)` 를 사용한다.
harness 는 이 파일을 **실행하지 않는다**. 배포 시나리오:

| 배포 대상 | 방식 |
| :--- | :--- |
| Vercel | `api/slack-callback.mjs` 로 심볼릭 링크 또는 copy |
| Cloudflare Workers | `fetch` 핸들러 래퍼 추가 (사용자 책임) |
| AWS Lambda | API Gateway integration (사용자 책임) |
| 로컬 검증 | `node scripts/smoke-slack-callback.mjs` (mock E2E) |

harness 책임 = 파일 존재 + syntax 무결성 + mock E2E 검증. 실 HTTP listen / port binding **0 건**.

### R24 에서 하지 않은 것 (R25+ 이월)

- `export_promoted` / `sentinel_detected` / `worker_timeout` emit wiring
- `session_prepared` / `session_closed` drift 2 건 해소
- thread_ts 저장 경로 (`.company-runtime/sessions/{id}/slack-thread.env`)
- Telegram 연동
- 실 Slack workspace E2E (배포 후 사용자 환경)

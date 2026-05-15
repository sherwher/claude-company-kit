> 8섹션 참조본 (R20 v2). R19 compact-plan v2 와 역방향 대칭. 실제 생성은 prepare-worker.sh L177 이 템플릿을 복사하고 워커가 close-session 직전 Write 로 갱신합니다. 8 top-level ## 헤더는 close-session.sh L104/L121/L203/L205 파싱 계약이므로 문자열 변형 금지 (한 글자도). 각 섹션 내부 ### H3 는 허용. 워커는 런타임에 frontmatter 에 meta 블록(session_id/worker/role/plan_sha256/created_at) 을 추가해야 합니다.
> 이 파일의 작성 규칙 / Self-Reject Trigger / 8 헤더 문자열 변형 금지 근거는 동일 디렉토리 `compact-result-prompt.md` 를 함께 읽으세요.

---
id: cr-example-pay-retry-v2
title: "(예시) 결제 재시도 정책 v2 실행 결과: idempotency + circuit breaker"
author: "backend-engineer"
status: "template-example"
created_at: "2026-04-09"
tags: [example, template-reference, adr-0085, result-v2]
evidence:
  - id: E1
    type: runtime_log_or_trace
    path: "observability/grafana/payment_latency_p99.json"
    description: "신규 retry 배포 후 24h P99 latency 실측 = 247ms (목표 ≤250ms)"
  - id: E2
    type: repo_text_or_diff
    path: "tests/integration/payment_resiliency_test.go:88"
    description: "동일 idempotency key 100회 요청 → 1건 처리 테스트 녹색"
  - id: E3
    type: external_spec_or_policy
    path: "sentry://trace/pay-cb-open-2026-04-09"
    description: "PG 502 시뮬레이션 시 circuit breaker Open 전이 trace — 3회 Open, 3회 Half-Open 복구"
mcp_footprints:
  - id: mcp-01
    tool: "sentry"
    query: "CircuitOpen events last 24h"
    observed: "3 transitions, auto-close 5s window 모두 정상 복구"
  - id: mcp-02
    tool: "stripe"
    query: "idempotency replay verification"
    observed: "100/100 duplicate keys dedupe 확인, 중복 결제 0건"
export_candidate_paths:
  - "docs/adr/0085-payment-retry-v2.md"
  - "src/services/payment/circuit_breaker.go"
  - "src/services/payment/retry_strategy_v2.go"
  - "tests/integration/payment_resiliency_test.go"
---

# Compact Result

## Summary

- P99 latency 247ms 달성, idempotency 중복결제 0건, circuit breaker Open 전이 3회 모두 auto-close — plan 의 Claim 이 실제로 검증됨 [E1][E2][E3].

### Claim → Outcome

- **P99 ≤ 250ms**: 실측 247ms, 배포 24h 내 목표 달성 [E1 grafana metric].
- **idempotency key 100회 → 1건 처리**: 테스트 100/100 pass, 중복 결제 발생 0건 [E2 test log, mcp-02].
- **circuit breaker Open 전이 확인**: PG 502 시뮬레이션 3회, 5s SleepWindow 후 Half-Open → Closed 자동 복구 [E3 sentry trace, mcp-01].

### Evidence Matching

- [E1] plan Success Metric "P99 ≤ 250ms" 를 실측 247ms 로 확정. v1 대비 개선 달성.
- [E2] plan DoD "100회 동일 key → 1건 처리" 를 통합 테스트 직접 실행으로 확정.
- [E3] plan R2 "circuit breaker false positive 위험" 이 실제 운영에서 발생하지 않았음을 확증.

## Outputs

- docs/adr/0085-payment-retry-v2.md (type: adr, status: shipped) — ADR 시니어 리뷰 승인 완료.

### Delivered Outputs

| Path | Type | Status | Description |
| :--- | :--- | :--- | :--- |
| `docs/adr/0085-payment-retry-v2.md` | adr | shipped | idempotency key 해싱 명세 + lock 범위 + TTL 24h 확정 |
| `src/services/payment/retry_strategy_v2.go` | code | shipped | full-jitter backoff + timeout 1.2s (plan 1.5s → 수정, 사유는 Plan Deviations 참조) |
| `src/services/payment/circuit_breaker.go` | code | shipped | ErrorThreshold 50%, SleepWindow 5s, Redis 분산 state |
| `tests/integration/payment_resiliency_test.go` | test | shipped | idempotency 100회 + Redis down + PG 502 + partition 시나리오 포함 |

### Expected vs Actual Delta

- plan Expected Outputs 4 항목 모두 shipped. 예상 외 추가 산출물: `observability/grafana/payment_latency_p99.json` (E1 측정 대시보드 — plan 미선언, 관측성 강화 중 자연 발생).

## Risks

- R1 (plan 기준 High) 잔여 없음: Redis 장애 시 idempotency 검증 불가 위험 — mitigation shipped, DB audit log fallback 동작 확인 [E3].

### Residual Risks

- **R2 잔여 (Medium)**: Observation Mode 24h 기간이 짧음. 2주 운영 후 circuit breaker 임계값 재튜닝 필요.
- **R4 신규 (Low)**: Grafana alert rule 미설정. SRE 팀 핸드오프 전까지 silent failure 위험.

### Mitigation Status

| Risk | Plan Mitigation | Actual Status | Note |
| :--- | :--- | :--- | :--- |
| R1 (High) | DB audit log fallback (Fail-Open 금지) | shipped | Redis 장애 시뮬레이션에서 fallback 동작 확인 [E3] |
| R2 (Medium) | rolling window 기반 임계값 점진 tuning | partial | 초기 임계값만 적용, 2주 후 재평가 예정 |
| R3 (Low) | SHA-256 collision 감지 + audit log 이벤트 훅 | shipped | collision 0건, 훅 동작 확인 |

## Next Action

- 2주 observation 후 circuit breaker 임계값 재튜닝 세션 진입.

### Immediate Next

- Grafana alert rule 등록 (SRE 팀 handoff 필요 — R4 신규 리스크 대응)
- ADR-0085 후속 운영 메모 작성 (2주 tuning 결과 반영)

### Blockers

- 없음

## Evidence Delivered

- [runtime_log_or_trace] observability/grafana/payment_latency_p99.json — P99 247ms 실측 [E1]
- [repo_text_or_diff] tests/integration/payment_resiliency_test.go:88 — idempotency 100회 테스트 [E2]
- [external_spec_or_policy] sentry://trace/pay-cb-open-2026-04-09 — circuit breaker Open/Close trace [E3]
- [architecture_or_decision_record] docs/adr/0085-payment-retry-v2.md — ADR 확정본 (시니어 리뷰 승인)

### Evidence-Claim Matching

| AC | Verdict | Evidence ID | Kind | Referenced Claim | Locator |
| :--- | :--- | :--- | :--- | :--- | :--- |
| AC1 | pass | E1 | runtime_log_or_trace | plan Success Metric "P99 ≤ 250ms" | grafana/payment_latency_p99.json |
| AC2 | pass | E2 | repo_text_or_diff | plan DoD "100회 → 1건 처리" | payment_resiliency_test.go:88 |
| AC3 | pass | E3 | external_spec_or_policy | plan R2 circuit breaker false positive | sentry trace pay-cb-open-2026-04-09 |

> v1.4 Phase 3 작성 규칙: 각 AC 행은 plan 의 Acceptance Criteria 와 1:1 대응한다.
> Verdict 는 `pass` / `fail` / `partial` 중 하나. evidence 가 없으면 `fail` 로 기록하고
> Plan Deviations 에 사유를 남긴다. AC 가 plan 에 5개를 넘으면 deep 레인 진입을 검토한다.

## Plan Deviations

- **timeout 값 조정**: plan S3 의 per-dependency timeout 1.5s → 실제 구현 1.2s. 사유: [E1] 최초 배포 P50 측정 결과 1.5s 는 상위 API SLA 2s 버짓 기준으로 여유가 350ms 밖에 없었음 — 새로운 측정 증거에 의한 판단의 정교화. retry budget 보호 우선.
- **Observation Mode 기간 연장**: plan 24h → 실제 72h. 사유: CS 티켓 대응 주기 (72h) 와 정합성 맞춤. plan 의 Real-time Decision Question (TTL 24h 충분 여부) 에 대한 실행 중 답변이 "연장 필요" 로 수렴 — 새로운 증거에 의한 판단의 수정 사유 명시.

## Observed Unknown Kinds

- none

## Next Hop

### Follow-up Session Entry Point

- **R21**: worker-role-briefs MCP 매트릭스 작업 진입 (본 세션 ADR-0085 가 backend-engineer MCP 선언의 1차 fixture 로 활용 가능).
- **2주 후**: circuit breaker 임계값 재튜닝 세션 (Observation Mode 72h 데이터 기반).

### Resume Snippet (v1.4 Phase 3)

다음 워커가 본 세션을 이어 받을 때 즉시 실행 가능한 명령. SESSION_ID/WORKER 만 치환하면 그대로 동작.

```bash
# 같은 세션 같은 워커로 재진입 (compact-plan 다시 작성 후 새 approval)
bash .company-kit/scripts/resume-worker.sh <SESSION_ID> <WORKER_NAME>

# 또는 새 토픽으로 후속 세션 시작
bash .company-kit/scripts/run-session.sh "<follow-up topic>" "" "$(pwd)"
```

### Open Questions

- Redis cluster 다운 시 multi-region failover 전략이 본 PR 범위 외 — 별도 ADR 필요한가? (리더 판단)
- Grafana alert rule 등록 담당: 현 팀 내부 vs SRE 팀 handoff 여부 결정 필요.

> 5섹션 참조본 (R19 v2). 실제 생성은 워커의 첫 `Write` 호출로 이루어집니다 (지시문: `templates/compact-plan-prompt.md`). 이 파일은 구조 앵커: `docs/design/archive/R3-R4-original-drafts/compact-plan-v2.md` (ADR-0085). 워커는 런타임에 frontmatter 에 `meta:` 블록(session_id / worker / role / plan_sha256 / created_at) 을 추가해야 합니다.

---
id: cp-example-pay-retry-v2
title: "(예시) 결제 재시도 정책 v2: 멱등성 키 + 분산 서킷 브레이커"
author: "backend-engineer"
status: "template-example"
created_at: "2026-04-09"
tags: [example, template-reference, adr-0085]
evidence:
  - id: E1
    type: repo
    path: "src/services/payment/retry_handler.go:42"
    description: "v1 단순 지수 백오프, jitter 부재 — rate limit 미고려 확인"
  - id: E2
    type: adr
    path: "docs/adr/0042-idempotency-strategy.md"
    description: "전사 공통 멱등성 표준 — TTL 및 충돌 해결 전략 참조"
  - id: E3
    type: mcp
    tool: "stripe"
    description: "Idempotency-Key 헤더 처리 방식 및 429 응답 시멘틱 분석"
mcp_footprints:
  - id: mcp-01
    tool: "sentry"
    query: "MaxRetriesExceeded + CircuitOpen events last 24h"
    confidence: "high"
  - id: mcp-02
    tool: "stripe"
    query: "idempotency-key replay validation simulation"
    confidence: "medium"
export_candidate_paths:
  - "docs/adr/0085-payment-retry-v2.md"
  - "src/services/payment/circuit_breaker.go"
---

# Compact Plan

## Goal

### Goal Summary
- 분산 환경에서 결제 정합성을 원자적 수준으로 보장하기 위해 Request-Hash 기반 **idempotency key** 메커니즘을 구축하고, 외부 PG 장애 시 연쇄 장애를 차단하는 분산 **circuit breaker** 를 도입합니다 [E1][E2].
- 단순 retry 는 upstream 장애를 증폭시키는 Retry Storm 을 유발합니다. full-jitter backoff + idempotency key + circuit breaker 가 하나의 PR 에 함께 들어와야만 안전합니다.

### Success Metrics
- 외부 PG timeout 발생 시 시스템 API P99 latency ≤ 250ms (v1 대비 80% 개선) [E3].
- 결제 중복 발생률 0% — 동일 idempotency key 로 100회 연속 요청 시 1건만 처리.

## Steps

### Implementation Steps

| Step | Action | Tool/Target | Owner |
| :--- | :--- | :--- | :--- |
| **S1** | 기존 `retry_handler.go` [E1] 의 하드코딩 파라미터와 rate limit 미고려 흐름을 `lsp_find_references` 로 전수 확인. 실패 분기·timeout 경로 부재 확인 후 변경 범위 확정. | `lsp` / `src/services/payment` | architect |
| **S2** | ADR-0085 초안 작성: idempotency key 생성 규칙 (UserID + payload SHA-256 hash), Redis TTL 24h, per-user lock 범위 [E2] 준수. lock 충돌 시 명시적 거부 로직 포함. | `Write` / `docs/adr/0085-pay-v2.md` | architect |
| **S3** | Circuit breaker + full-jitter retry 구현: ErrorThreshold 50%, SleepWindow 5s, per-dependency timeout 1.5s. retry 는 동일 idempotency key 재사용으로 멱등성 보장. | `Edit` / `src/services/payment/client.go` | engineer |
| **S4** | 멱등성·retry 통합 테스트: Stripe mock [E3] 으로 동일 idempotency key 100회 요청 → 1건 처리 검증. 실패 분기 (Redis down / PG 502 / network partition) 시나리오 전부 커버. | `Bash` / `tests/payment/idemp_test.go` | engineer |
| **S5** | 관측성 강화: Sentry [mcp-01] `CircuitOpen` 커스텀 이벤트 + PagerDuty 연동. retry 횟수·lock 경합·timeout·idempotency 재시도 지표 대시보드 노출. | `mcp-01` / sentry config | devops |

## Outputs

### Expected Outputs
- `docs/adr/0085-payment-retry-v2.md` — ADR 본문 + idempotency key 해싱 명세 (type: adr)
- `src/services/payment/retry_strategy_v2.go` — full-jitter 지수 backoff 구현체 (type: code)
- `src/services/payment/circuit_breaker.go` — 분산 circuit breaker 래퍼 (type: code)
- `tests/integration/payment_resiliency_test.go` — PG 장애 시나리오 카오스 테스트 (type: test)

(evidence / mcp_footprints / export_candidate_paths 는 frontmatter 에 정의되어 자동 승급 후보로 수집됩니다.)

## Risks

### Trade-offs

| 전략 | 장점 | 단점 | 결정 사유 |
| :--- | :--- | :--- | :--- |
| Simple Exponential Backoff | 구현 단순, 추가 인프라 불필요 | 장애 시 Thundering Herd 발생, upstream 부하 가중, idempotency 보장 없음 | **배제**: 고부하 시 시스템 붕괴 위험 |
| Circuit Breaker + Jittered Retry + Idempotency Key | 자원 보호, 부하 분산, 중복 결제 방지 | 분산 상태(Redis) 관리 복잡성, lock 범위 설계 필요 | **채택**: 결제 도메인 비즈니스 중요도 + 복구 탄력성 우선 |

### Risks & Mitigations
- **R1 (High)**: Redis 장애 시 idempotency 검증 불가 → 중복 결제 위험. *Mitigation*: Fail-Open 금지, DB audit log 를 통한 2차 검증 (fallback). Decision Framework Rule 16 (Redis as coordination cache, not source of truth) 적용.
- **R2 (Medium)**: circuit breaker 임계값 오설정으로 false positive 조기 차단. *Mitigation*: 초기 Observation Mode 운영 후 rolling window 비율 기반 임계값 점진적 tuning.
- **R3 (Low)**: idempotency key SHA-256 hash collision 가능성. *Mitigation*: 충돌 감지 시 명시적 거부 로직 추가, audit log 에 collision 이벤트 기록.

## Questions

### Real-time Decision Questions
- idempotency key TTL 을 24h 로 설정하는 것이 CS 대응 주기 (최대 72h) 를 고려할 때 충분한가, 아니면 72h 로 확장할 것인가?
- circuit breaker 상태를 Redis 공유 상태로 둘 것인가, 아니면 인스턴스 로컬로 둘 것인가? — split-brain 비용 vs consistency 비용 트레이드오프 명시 필요.
- S3 의 per-dependency timeout 1.5s 가 상위 API SLA (2s 기준) 와 충돌하지 않는가? — timeout budget 분배 전략 사전 합의 필요.

### Definition of Done
- [ ] ADR-0085 시니어 리뷰 승인 완료
- [ ] idempotency key 기반 중복 결제 방지 테스트 통과 (100회 동일 key → 1건 처리)
- [ ] 외부 PG 장애 시뮬레이션 시 circuit breaker `Open` 상태 전이 확인
- [ ] Sentry 대시보드에 retry 횟수 / circuit 상태 / lock 경합 / idempotency 재시도 지표 노출
- [ ] P99 latency ≤ 250ms 카오스 테스트 통과 (Steady State 정량 측정 포함)

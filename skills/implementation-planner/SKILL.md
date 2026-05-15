---
name: implementation-planner
description: Use this skill when a request needs a concrete implementation plan with scope, dependencies, milestones, validation steps, and handoff points before execution starts.
triggers:
  - "구현 계획"
  - "implementation plan"
  - "plan mode"
  - "단계 나눠줘"
  - "어떻게 구현할지"
  - "실행 계획"
---

# Implementation Planner

## 목적

- 요구사항을 바로 실행 가능한 구현 계획으로 압축한다.
- scope, dependency, validation을 먼저 닫아 leader 승인 판단을 쉽게 만든다.

## 언제 사용하나

- 코드 변경 전 plan mode가 필요할 때
- 여러 팀 handoff가 예상될 때
- 설계 문서와 실제 구현 사이 간극을 줄여야 할 때

## 기본 절차

1. `project-work/`와 현재 저장소에서 요구사항 근거를 모은다.
2. 해야 할 일과 하지 않을 일을 분리한다.
3. dependency와 선행 조건을 묶는다.
4. 구현 단계를 작게 나누고 각 단계의 검증 기준을 적는다.
5. leader 승인에 필요한 risk와 open question만 남긴다.

## Quick Template

```markdown
## 구현 계획: <기능 또는 작업 이름>

작성자: <worker-name>
날짜: <날짜>

### 범위 (Scope)
**할 것:**
- ...

**안 할 것 (이번 범위 밖):**
- ...

### 선행 조건
- [ ] <선행 작업 또는 확인 사항>

### 단계별 실행 계획

| 단계 | 작업 | 검증 기준 | 담당 | 예상 시간 |
|------|------|----------|------|---------|
| 1    | ...  | ...      | ...  | ...     |
| 2    | ...  | ...      | ...  | ...     |

### 리스크
| 리스크 | 가능성 | 영향 | 완화 방안 |
|--------|--------|------|---------|
| ...    | 높/중/낮 | 높/중/낮 | ... |

### Open Questions (leader 확인 필요)
- ...

### Handoff 지점
- 단계 X 완료 후 → <다음 워커>에게 인수
```

## Anti-Patterns

❌ 작업 목록만 나열 — "API 만들기, DB 설계, 테스트 작성" → 검증 기준 없음
❌ 가정을 확정처럼 쓰기 — "Redis 사용" (아직 결정 안 됨)
❌ Validation 없는 계획 — 각 단계가 "됐다"는 걸 어떻게 아는가?
❌ 리스크를 안 적기 — 나중에 leader가 발견하면 신뢰 감소

## Golden Standard

```markdown
## 구현 계획: 결제 실패 시 자동 재시도 기능

작성자: backend-engineer
날짜: 2026-03-31

### 범위
**할 것:**
- 결제 실패 시 최대 3회 재시도 (지수 백오프)
- 재시도 결과 로깅

**안 할 것:**
- 결제 UI 변경 (frontend-engineer 별도 작업)
- 환불 플로우 (다음 sprint)

### 선행 조건
- [x] Stripe SDK 버전 확인 완료 (v14.x)
- [ ] 재시도 정책 PM 확인 필요 (3회? 5회?)

### 단계별 실행 계획

| 단계 | 작업 | 검증 기준 | 담당 | 예상 |
|------|------|----------|------|------|
| 1 | retry 로직 구현 | unit test 통과 | backend-engineer | 2h |
| 2 | 로깅 추가 | 실패/성공 로그 확인 | backend-engineer | 1h |
| 3 | staging 검증 | 실제 실패 카드로 재시도 3회 확인 | qa-reviewer | 1h |

### 리스크
| 리스크 | 가능성 | 영향 | 완화 |
|--------|--------|------|------|
| 동시 재시도 중복 결제 | 중 | 높 | idempotency key 사용 |

### Open Questions
- 재시도 횟수: 3회 vs 5회 → PM 확인
```

## 기대 산출물

- 단계별 실행 계획 (검증 기준 포함)
- 리스크 목록
- 보류 항목 (Open Questions)
- handoff 필요 지점

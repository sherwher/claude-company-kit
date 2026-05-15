---
name: decision-log
description: Use this skill when making a non-trivial architectural, technical, or design choice that others will later ask "why did we do it this way?". Captures the ADR-lite record before moving on.
triggers:
  - "왜 이걸 선택했나"
  - "결정 기록"
  - "ADR"
  - "decision record"
  - "이 방향을 선택한 이유"
  - "대안 비교"
---

# Decision Log

## 목적

- "왜 이렇게 했는가?"에 대한 근거를 실행 직전/직후에 남긴다.
- 나중에 leader나 팀원이 물을 때 즉시 답변 가능하게 만든다.
- 결정을 번복할 때 기존 근거와 비교할 수 있게 한다.

## 언제 사용하나

- 라이브러리/프레임워크를 선택할 때
- 구조적 tradeoff가 있는 선택을 할 때
- "이건 나중에 왜 이렇게 했냐고 물어볼 것 같다"는 느낌이 들 때
- architecture-review 또는 implementation-planner와 함께 쓸 때

## 기본 절차

1. 결정 제목을 한 줄로 쓴다.
2. 선택한 옵션과 고려했던 대안 2개를 나열한다.
3. 각 옵션의 장단점을 한 줄씩만 쓴다.
4. 최종 선택 이유를 2-3줄로 쓴다.
5. 이 결정을 번복할 조건을 한 줄 쓴다.
6. `project-work/09-decisions/` 또는 `handoff-summary.md`에 추가한다.

## Quick Template

```markdown
## 결정: <제목>

- 날짜: <YYYY-MM-DD>
- 결정자: <worker-name>
- 상태: 확정 / 검토 중 / 번복됨

### 선택한 옵션
**<선택>** — <한 줄 이유>

### 고려한 대안
| 옵션 | 장점 | 단점 |
|------|------|------|
| A    | ...  | ...  |
| B    | ...  | ...  |

### 최종 근거
> ...

### 번복 조건
> <이럴 경우에만 다시 검토>
```

## Anti-Patterns

❌ "팀 논의 후 결정" — 누가, 왜, 어떤 근거로 결정했는지 사라짐
❌ 대안 없이 선택만 기록 — 나중에 "왜 다른 것 안 썼냐"에 답 못함
❌ 한 문서에 10개 결정 몰아넣기 — 검색 불가, 업데이트 불편

## Golden Standard

```markdown
## 결정: 세션 저장소로 Redis 대신 PostgreSQL 사용

- 날짜: 2026-03-31
- 결정자: backend-engineer
- 상태: 확정

### 선택한 옵션
**PostgreSQL** — 이미 사용 중인 DB를 추가 인프라 없이 활용

### 고려한 대안
| 옵션 | 장점 | 단점 |
|------|------|------|
| Redis | 빠른 TTL 관리 | 추가 인프라, 비용 증가 |
| In-memory | 구현 간단 | 서버 재시작 시 세션 유실 |

### 최종 근거
> 세션 수가 하루 1,000건 미만으로 PostgreSQL 성능이 충분함.
> 인프라 단순성이 현 단계에서 더 중요. Redis는 트래픽 10배 증가 시 재검토.

### 번복 조건
> 세션 조회 p99 latency > 200ms 지속 시
```

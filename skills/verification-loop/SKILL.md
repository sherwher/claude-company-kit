---
name: verification-loop
description: Use this skill after implementation to verify that changes work as expected before handing off or closing a task. Captures evidence, not just assertions.
triggers:
  - "검증"
  - "verification"
  - "테스트 결과 확인"
  - "동작 확인"
  - "완료 확인"
  - "done 기준"
---

# Verification Loop

## 목적

- "됐다"가 아니라 증거(Evidence)를 제출한다.
- 검증 결과를 재현 가능한 형태로 남긴다.
- 회귀(regression)를 방지하는 최소 체크리스트를 만든다.

## 언제 사용하나

- 구현 완료 후 QA 전
- PR 제출 전 셀프 체크
- 다음 워커에게 넘기기 전 상태 확인
- leader 승인 요청 전 증거 수집

## 기본 절차

1. 완료 기준(DoD)을 먼저 확인한다.
2. 각 기준을 "실행 명령 → 기대 결과 → 실제 결과" 형식으로 검증한다.
3. 실패한 항목은 즉시 기록 (숨기지 않는다).
4. 증거를 artifact에 첨부한다 (로그, 스크린샷, 명령 출력).
5. 재시도 필요 여부를 결정한다.

## Quick Template

```markdown
## 검증 결과 — <task 이름>

검증일: <날짜>
검증자: <worker-name>
전체 결과: ✓ 통과 / ✗ 실패 / △ 부분 통과

### 체크리스트

| 항목 | 실행 명령 또는 확인 방법 | 기대 결과 | 실제 결과 | 통과 |
|------|------------------------|----------|----------|------|
| ...  | `<command>`            | ...      | ...      | ✓/✗ |

### 실패 항목
- **항목:** ...
- **원인 추정:** ...
- **재시도 필요:** Y / N

### 첨부 증거
- 로그: `<경로 또는 붙여넣기>`
```

## Anti-Patterns

❌ "테스트 완료"만 적기 — 어떤 테스트를, 어떻게, 결과가 무엇인지 없음
❌ 실패 항목 숨기기 — 나중에 더 큰 문제로 돌아옴
❌ 로컬만 테스트하고 "됨" 선언 — CI/staging 환경 차이 무시

## Golden Standard

```markdown
## 검증 결과 — Stripe webhook 검증 로직

검증일: 2026-03-31
검증자: backend-engineer
전체 결과: △ 부분 통과

| 항목 | 실행 명령 | 기대 결과 | 실제 결과 | 통과 |
|------|---------|---------|---------|------|
| webhook 서명 검증 | `curl -X POST /webhook -H "Stripe-Signature: ..."` | 200 OK | 200 OK | ✓ |
| 잘못된 서명 거부 | `curl -X POST /webhook -H "Stripe-Signature: bad"` | 400 | 400 | ✓ |
| idempotency 중복 처리 | 같은 event_id 2회 전송 | 2번째 무시 | 500 Error | ✗ |

### 실패
- **항목:** idempotency key 중복 처리
- **원인:** DB unique constraint 없음
- **재시도:** Y — migration 추가 후 재검증
```

## 증거 캡처 패턴

```bash
# 로그 캡처
<command> 2>&1 | tee .company-artifacts/<session>/<worker>/verify-<name>.log

# DB 상태 스냅샷
psql $DATABASE_URL -c "SELECT count(*), status FROM payments GROUP BY status;"

# API 응답 비교 (변경 전/후)
curl -s <endpoint> | jq '.' > before.json && <변경> && curl -s <endpoint> | jq '.' > after.json && diff before.json after.json
```

## 기대 산출물

- 검증 명령 목록 + 실행 결과
- 통과/실패/부분통과 요약
- 실패 원인 추정
- 재실행 필요 조건
- 남은 리스크

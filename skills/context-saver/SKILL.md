---
name: context-saver
description: Use this skill when pausing work mid-session, handing off to the next worker, or resuming after a break. Compresses current working state into a minimal handoff document.
triggers:
  - "잠깐 멈추고"
  - "다음에 이어서"
  - "인수인계"
  - "handoff"
  - "context 저장"
  - "다음 워커에게"
---

# Context Saver

## 목적

- 지금 머릿속에 있는 "진행 중인 가설"과 "왜 이 방향인가"를 압축해 저장한다.
- 다음 턴에서 중복 리서치 없이 즉시 재개할 수 있게 만든다.
- `handoff-summary.md`의 품질을 높인다.

## 언제 사용하나

- 작업 도중 멈추거나 다른 일이 생겼을 때
- 다음 워커나 내일의 나에게 넘길 때
- session-report 작성 전 요점 정리가 필요할 때

## 기본 절차

1. 지금 어디까지 했는지 `완료 / 진행 중 / 막힌 것`으로 나눈다.
2. 현재 가장 중요한 열린 질문 1-3개를 적는다.
3. 다음 워커가 이어받으려면 먼저 읽어야 할 파일 경로를 적는다.
4. 현재 방향을 선택한 이유(근거 한 줄)를 적는다.
5. `.company-runtime/sessions/<id>/workers/<worker>/handoff-summary.md`에 저장한다.

## Quick Template

```markdown
# Handoff — <worker-name> @ <session-id>

## 완료
- [ ] ...

## 진행 중
- [ ] ... (현재 위치: <파일 또는 단계>)

## 막힌 것 / 열린 질문
1. ...
2. ...

## 다음 워커가 먼저 읽을 파일
- `<경로>`
- `<경로>`

## 현재 방향의 근거
> <한 줄 이유>

## 예상 다음 액션
- ...
```

## Anti-Patterns

❌ "작업 완료" 한 줄만 남기기 — 다음 워커가 처음부터 다시 파악해야 함
❌ 코드 diff를 전부 복사 — 핵심 의사결정이 묻힘
❌ 열린 질문을 안 적기 — 같은 질문을 다음 세션에서 또 만남

## Golden Standard

```markdown
# Handoff — backend-engineer @ ws-0331

## 완료
- [x] /api/payment POST 라우터 구조 설계

## 진행 중
- [ ] Stripe webhook 검증 로직 (현재 위치: src/payment/webhook.ts:47)

## 막힌 것
1. idempotency key 저장 위치: Redis vs DB 결정 안 됨
2. 실패 시 재시도 횟수 정책 없음

## 다음 워커가 먼저 읽을 파일
- `project-work/04-backend/payment-api.md`
- `.company-artifacts/ws-0331/backend-engineer/webhook-draft.md`

## 현재 방향의 근거
> Stripe 공식 예제 기반, Node.js SDK 최신 버전 사용

## 예상 다음 액션
- idempotency key 결정 후 DB 스키마 변경
- qa-reviewer에게 webhook 시나리오 리뷰 요청
```

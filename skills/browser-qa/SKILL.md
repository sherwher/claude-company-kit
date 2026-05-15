---
name: browser-qa
description: Use this skill when a project needs browser verification, UI capture, smoke tests, regression checks, or Playwright-based review flows.
---

# Browser QA

## 목적

- Playwright 기반 브라우저 검증을 일관되게 수행한다.
- 화면 캡처, smoke test, 회귀 확인을 같은 흐름으로 다룬다.

## 언제 사용하나

- UI 변경 후 실제 동작 확인이 필요할 때
- 제출 전 화면 검수가 필요할 때
- 브라우저 상 재현 경로를 남겨야 할 때

## 기본 절차

1. 프로젝트에 Playwright 설정이 있는지 확인한다.
2. 검증 목표를 `smoke`, `capture`, `regression` 중 하나로 정한다.
3. 대상 페이지와 기대 결과를 짧게 정의한다.
4. 가능한 경우 기존 Playwright 테스트를 먼저 실행한다.
5. 새 검증이 필요하면 최소 경로만 추가한다.
6. 결과는 `.company-artifacts/<session-id>/reviews/` 또는 `docs/` 아래에 정리한다.

## 기대 산출물

- 실행한 경로
- 통과 또는 실패 결과
- 캡처 이미지 또는 로그 경로
- 후속 수정 필요 항목

## 주의사항

- E2E 전체 스위트를 기본값으로 돌리지 않는다.
- 재현에 필요한 최소 시나리오만 실행한다.
- 제출용 스크린샷은 파일명을 명확하게 남긴다.

# 작업 합의사항

## 현재 기준 입력 문서

- project summary: `project-work/00-project/project-summary.md`
- requirements: `project-work/01-planning/requirements.md`
- design direction: `project-work/02-design/design-direction.md`
- frontend architecture: `project-work/03-frontend/frontend-architecture.md`
- backend architecture: `project-work/04-backend/backend-architecture.md`
- ERD: `project-work/06-erd/erd.md`

## 팀 작업 규칙

- 먼저 plan을 제출하고 승인 후 execution으로 이동
- tracked code 변경은 session worktree branch에서만 진행
- 공통 기준 문서 변경은 `project-work/`에 반영
- 중간 초안은 `.company-artifacts/<session-id>/`에 유지
- Java, React, React Native 기본 기준은 `code-conventions.md`와 `project-standards.md`를 따른다
- API, schema, screen 흐름이 바뀌면 관련 문서를 같은 session 안에서 같이 갱신한다
- 커밋 메시지는 기본적으로 한글로 작성하고, 유형과 범위가 드러나게 짧게 쓴다

## 커뮤니케이션 규칙

- handoff는 `summary + risks + next action`
- blocked면 막힌 이유와 필요한 input을 같이 기록
- decision이 바뀌면 같은 날 `decision-log.md` 갱신
- review가 필요하면 `08-reviews/review-checklist.md` 기준으로 정리

## 완료 기준

- 코드:
  - 관련 lint와 테스트 통과
  - scope 밖 변경 없음
- 문서:
  - 관련 `project-work/` 문서 갱신
  - 필요한 decision 기록 반영
- review:
  - blocked 이슈 없음
  - reviewer 코멘트 처리 또는 후속 액션 기록
- release or export:
  - external export가 있으면 leader 승인 후 진행

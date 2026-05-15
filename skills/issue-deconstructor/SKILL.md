---
name: issue-deconstructor
description: Use this skill when receiving vague user feedback, abstract feature requests, or large epics that need to be broken into actionable atomic tasks before implementation begins.
triggers:
  - "요구사항 분해"
  - "태스크 쪼개기"
  - "scope 정리"
  - "epic 분해"
  - "뭘 해야 할지 모르겠다"
  - "범위가 너무 크다"
  - "issue breakdown"
---

# Issue Deconstructor

## 목적

- 모호한 피드백이나 추상적 기능을 실행 가능한 최소 단위(Atomic Tasks)로 분해한다.
- `implementation-planner`로 넘어가기 전 scope를 확정하고 누락을 방지한다.
- "이게 다 된 거냐"를 판단할 수 있는 완료 기준을 각 태스크에 붙인다.

## 언제 사용하나

- 유저 피드백이 모호할 때 ("결제가 느려요")
- 기능 요청이 너무 클 때 ("소셜 로그인 추가해주세요")
- implementation-planner 전에 scope가 불명확할 때
- 여러 워커가 나눠야 할 때 분배 기준이 필요할 때

## 기본 절차

1. 원문 요청/피드백을 한 줄로 요약한다.
2. 암묵적 가정을 3개 이내로 명시한다.
3. "반드시 해야 함 / 하면 좋음 / 이번엔 안 함"으로 분류한다.
4. 각 "반드시" 항목을 1-3시간 단위의 atomic task로 쪼갠다.
5. 각 task에 완료 기준(Definition of Done) 한 줄을 붙인다.
6. 담당 워커 후보를 옆에 표기한다.

## Quick Template

```markdown
## 이슈 분해: <원문 요청 한 줄 요약>

### 가정 (확인 필요)
1. ...
2. ...

### 분류
**반드시 (Must Have)**
- [ ] <task> — DoD: <완료 기준> — 담당: <worker>

**하면 좋음 (Nice to Have)**
- [ ] <task>

**이번엔 안 함 (Out of Scope)**
- ...

### 질문 (leader 확인 필요)
- ...
```

## Anti-Patterns

❌ "결제 개선" 그대로 task로 넣기 — 완료 기준 없음, 어디서 멈출지 모름
❌ Out of Scope를 안 적기 — 나중에 scope creep 발생
❌ task 하나가 "하루 이상" — 더 쪼개야 함

## Golden Standard

```markdown
## 이슈 분해: 결제 페이지 로딩이 느리다는 유저 피드백 대응

### 가정
1. "느리다" = 3초 이상 (실제 측정값 없음, 확인 필요)
2. 현재 결제 API는 동기 호출 방식
3. CDN 설정 변경은 이번 범위 밖

### 분류
**반드시**
- [ ] 결제 페이지 로딩 시간 현황 측정 — DoD: Lighthouse 리포트 첨부 — 담당: data-analyst
- [ ] API 응답 병목 지점 식별 — DoD: slow query 또는 N+1 위치 특정 — 담당: backend-engineer
- [ ] 최우선 1개 병목 수정 — DoD: 로컬 측정 50% 개선 — 담당: backend-engineer

**하면 좋음**
- [ ] 결제 버튼 스켈레톤 로딩 추가 (UX 체감 개선)

**이번엔 안 함**
- CDN 설정 변경
- 전체 결제 플로우 리팩터링

### 질문
- "3초 이상"이 맞는 기준인지 PM 확인 필요
```

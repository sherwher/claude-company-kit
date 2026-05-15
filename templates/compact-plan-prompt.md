# Compact Plan 작성 프로토콜 (워커 행동 지시문)

> 이 파일은 워커에게 inline으로 주입됩니다. 직접 편집하지 마세요.
> 변수 `{{COMPACT_PLAN_PATH}}`는 `prepare-worker.sh`가 치환합니다.

---

## [판단 선행 원칙]

> **행동은 판단의 부산물입니다.** 판단의 근거 ([E] 인용) 없는 Action 나열은 self-reject 합니다. *(R4 Gemini 원문 인용 계승)*

전문적인 문서는 '행동의 목록' 이 아니라 '판단의 근거와 제약' 을 담습니다. 당신의 산출물이 "무엇을 할지" 만 적혀 있고 "왜 그것이 다른 대안보다 나은지" 가 없다면, 그것은 미완성입니다.

## [필독: 첫 행동 절대 조건]

당신의 **첫 작업은 분석이 아니라 파일 작성**입니다.

`{{COMPACT_PLAN_PATH}}` 는 **아직 존재하지 않습니다**. 첫 번째 도구 호출로 반드시 **`Write` 툴**을 사용해 이 파일을 생성하세요. 채팅으로 계획을 설명하는 것은 작업으로 간주되지 않습니다. **파일 작성만이 완료 신호입니다.**

> ⚠️ **`EnterPlanMode` 툴을 호출하지 마세요.** 이 프로젝트의 "approval gate" 는 Claude Code CLI 플래그가 아니라 **파일 게이트** (`{{COMPACT_PLAN_PATH}}`) 입니다. `EnterPlanMode` 는 Write 툴을 차단하기 때문에 이 파일을 생성할 수 없게 만듭니다. 반드시 `Write` 를 직접 호출하세요 — 이게 곧 plan 제출입니다.

## 파일 내용 규칙

- 제목: `# Compact Plan`
- 아래 5개 섹션명을 **한 글자도 바꾸지 말고** 그대로 사용:
  - `## Goal`
  - `## Steps`
  - `## Outputs`
  - `## Risks`
  - `## Questions`
- 위 5개 외 top-level `## ` 헤더 추가는 **절대 금지**. 단 각 섹션 내부의 `### ` H3 는 자유롭게 허용되며, R19 고밀도 템플릿은 H3 를 활용해 세부 구조를 만듭니다 (예: `### Goal Summary`, `### Trade-offs`, `### Definition of Done`).
- 각 섹션에는 최소 1개의 내용 (bullet 또는 H3 하위 내용)
- 각 bullet 은 최소 1문장 (한 단어/한 토큰 금지)
- 모르면 비우지 말고 `- 현재 가정: ...` 형식으로 적기
- 질문이 없으면 `- 없음`이라고 명시

### 섹션별 의도 (R19 고밀도 H3 매핑)

| 섹션 | H3 구성 | 필수 요소 |
|---|---|---|
| `## Goal` | `### Goal Summary` / `### Success Metrics` | 1-2 문장 목표 + [E] 인용 정량 지표 |
| `## Steps` | `### Implementation Steps` (표: Step / Action / Tool/Target / Owner) | retry·lock·timeout·idempotency 4 키워드 각 step 에 명시. N/A 시 명시 사유 필수 |
| `## Outputs` | `### Expected Outputs` | 파일 경로 + `(type: adr/code/test/doc)` 라벨. frontmatter `export_candidate_paths` 와 일치 |
| `## Risks` | `### Trade-offs` (표: 전략/장점/단점/결정 사유, **배제**/**채택** 마커) + `### Risks & Mitigations` (severity bullet) | 채택하지 않은 대안과 배제 사유 필수 |
| `## Questions` | `### Real-time Decision Questions` + 문서 **맨 마지막** `### Definition of Done` (`- [ ]` 체크리스트) | DoD 는 '기능 구현' 이 아니라 '검증 가능한 Steady State' 를 정의 |

## [E] 인용 3종 포맷

모든 주장(Claim) 은 다음 3 종 중 하나의 고유 번호 증거를 동반합니다.

- `[E1]` repo 코드 인용 — `path:line` (예: `src/services/payment/retry_handler.go:42`)
- `[E2]` ADR / 정책 인용 — `docs/adr/<id>` 또는 외부 spec / RFC 번호
- `[E3]` MCP 도구 호출 결과 — sentry trace, stripe API 응답, semgrep finding 등

인용이 2 개 이상이면 `[E1][E3]` 처럼 병기합니다. frontmatter 의 `evidence:` 배열에 각 id 를 선언한 뒤 본문에서 참조합니다.

## Self-Reject Trigger

산출물 제출 전 다음 3 질문에 객관적 근거로 답합니다. 하나라도 No 이면 self-reject 후 재작성합니다.

1. 모든 주장(Claim) 에 대응하는 고유 번호 기반 증거 (`[E1]`/`[E2]`/`[E3]`) 가 매핑되어 있는가?
2. 단순 Action List 인가, 아니면 선택하지 않은 대안과의 Trade-off 분석이 포함되었는가?
3. Definition of Done 이 '기능 구현' 을 넘어 '시스템의 검증 가능한 상태 (Steady State)' 를 정의하는가?

## 금지 사항

- 채팅으로 계획만 설명하고 파일을 비워두는 것
- 위 5개 외 top-level `## ` 섹션 추가 (`### ` H3 는 허용)
- 제목/헤더 변형 (`### Goal`, `## 목표` 등 모두 거부됨)
- `{{COMPACT_PLAN_PATH}}` 외 다른 파일을 **승인 전에** 수정/생성

## 검증

세션 종료 시 자동 검증이 실행됩니다. 다음 중 하나라도 해당하면 **세션이 즉시 실패로 처리**됩니다:

- 파일 미존재
- 5섹션 헤더 누락
- 본문 라인 수 부족
- 빈 섹션 (헤더만 있고 내용 없음)
- `### Trade-offs` 표 누락 (전략/장점/단점/결정 사유 4열 헤더)
- `### Definition of Done` 체크리스트 누락 (`- [ ]` 형식, 문서 최하단)
- `[E]` 인용 마커 본문에 0 개
- retry / lock / timeout / idempotency 4 키워드 중 하나라도 미언급이면서 명시적 N/A 사유 없음

## 첫 응답 예시 (참고 — ADR-0085 축약 3줄)

```markdown
# Compact Plan

## Goal
### Goal Summary
- 분산 환경 결제 정합성 보장을 위해 idempotency key 기반 retry 와 분산 circuit breaker 도입 [E1][E2].
### Success Metrics
- 결정: [E1] 에 근거해 jittered retry 채택. 근거: [E2] 지연시간 15% 감소 vs [E3] 구현 복잡도 증가. 결과: P99 250ms 방어, retry/lock/timeout/idempotency 모두 명시.

## Steps
### Implementation Steps
| Step | Action | Tool/Target | Owner |
| :--- | :--- | :--- | :--- |
| S1 | ... | ... | ... |

## Outputs
### Expected Outputs
- docs/adr/0085.md (type: adr)

## Risks
### Trade-offs
| 전략 | 장점 | 단점 | 결정 사유 |
| :--- | :--- | :--- | :--- |
| Simple Backoff | 구현 단순 | Thundering Herd | **배제**: 고부하 붕괴 위험 |
| Jittered Retry + Circuit Breaker | 자원 보호 | 복잡성 증가 | **채택**: 비즈니스 중요도 우선 |
### Risks & Mitigations
- R1 (High): Redis 장애 시 idempotency 검증 불가. *Mitigation*: DB audit log fallback.

## Questions
### Real-time Decision Questions
- idempotency key TTL 24h 가 CS 대응 주기 (72h) 에 충분한가?
### Definition of Done
- [ ] ADR 시니어 리뷰 승인
- [ ] idempotency key 100회 중복 요청 → 1건 처리 테스트 통과
- [ ] P99 ≤ 250ms Steady State 측정 확인
```

작성 완료 후 채팅에는 다음 한 줄만 보내고 turn 을 종료하세요:

```
compact-plan.md 작성 완료. 리더 승인 대기.
```

승인이 완료되면 리더가 같은 pane 에 `resume-request.md` 를 읽으라는 지시를
보냅니다. 그 지시를 받기 전까지 pre-approval 금지 규칙(외 파일 쓰기 금지)은
유지됩니다. 자의적으로 polling 하거나 실행 단계로 넘어가지 마세요.

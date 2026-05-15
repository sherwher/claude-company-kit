# Compact Result 작성 프로토콜 (워커 행동 지시문)

> 이 파일은 워커에게 inline 으로 주입됩니다. 직접 편집하지 마세요.
> 변수 `{{COMPACT_RESULT_PATH}}` 는 `prepare-worker.sh` 가 치환합니다.

---

## [결과는 설계의 증명 원칙]

> **결과는 설계의 증명입니다.** plan 에서 세운 판단이 실제 실행에서 어떻게 검증되었는지를 [E] 인용으로 확언합니다. 단순 체크박스 채우기는 self-reject 합니다. *(R20 Gemini 톤 계승)*

전문적인 결과 문서는 '완료된 작업 목록' 이 아니라 '판단의 근거와 실제 검증 증거' 를 담습니다. plan 단계에서 세운 Claim 이 실행 후에도 타당했는지, 아니면 새로운 증거로 인해 판단을 수정했는지를 명시적으로 기록합니다. Plan Deviations 는 '일탈' 이 아니라 '새로운 증거에 의한 판단의 정교화' 로 해석됩니다.

## [필독: 실행 종료 직전 절대 조건]

close-session 직전 당신은 반드시 `{{COMPACT_RESULT_PATH}}` 를 **`Write` 툴**로 갱신합니다.

이 파일은 `prepare-worker.sh` 단계에 템플릿 seed 로 복사되어 있지만, 실제 내용은 워커가 실행 결과를 바탕으로 덮어써야 합니다. 채팅으로 결과를 설명하는 것은 완료 신호가 아닙니다. **파일 갱신만이 완료 신호입니다.**

## 파일 내용 규칙

- 제목: `# Compact Result`
- 아래 **8 개 섹션명**을 **한 글자도 바꾸지 말고** 그대로 사용:
  - `## Summary`
  - `## Outputs`
  - `## Risks`
  - `## Next Action`
  - `## Evidence Delivered`
  - `## Plan Deviations`
  - `## Observed Unknown Kinds`
  - `## Next Hop`
- 위 8 개는 `close-session.sh` L104/L121/L203/L205 **파싱 계약**입니다. 변형 시 `session-report.md` 의 `Compact Results:`, `Worker Outputs:`, `Open Risks:` 생성이 깨집니다.
- 각 섹션 내부 `### ` H3 는 허용. R20 고밀도 구조는 H3 로 흡수합니다.
- `## Summary` / `## Outputs` / `## Risks` 각 섹션의 **첫 `- ` bullet 은 반드시 작성**합니다. `close-session.sh` awk 파서가 이 첫 bullet 을 뽑아 session-report 에 기록합니다.
- 각 bullet 은 최소 1 문장 (한 단어/한 토큰 금지)
- 모르면 비우지 말고 `- 현재 측정값 없음: <이유>` 형식으로 적기

### 섹션별 의도 (R20 대칭 H3 매핑)

| 섹션 | plan 역상 | H3 구성 | 필수 요소 |
| :--- | :--- | :--- | :--- |
| `## Summary` | `## Goal` | `### Claim → Outcome` / `### Evidence Matching` | plan Claim 실제 검증 + [E] 대응. 첫 bullet: 한 줄 요약 |
| `## Outputs` | `## Outputs` | `### Delivered Outputs` (표: Path/Type/Status/Description) / `### Expected vs Actual Delta` | shipped/partial/missed 상태. 첫 bullet: `path (type, status)` |
| `## Risks` | `## Risks` | `### Residual Risks` / `### Mitigation Status` (표: Risk/Plan Mitigation/Actual Status/Note) | plan Trade-offs 대비 실제 outcome. 첫 bullet: 잔여 리스크 요약 |
| `## Next Action` | `## Questions` 일부 | `### Immediate Next` / `### Blockers` | 다음 세션 진입점. 없으면 "없음" |
| `## Evidence Delivered` | frontmatter `evidence:` | `### Evidence-Claim Matching` (표: Evidence ID/Kind/Referenced Claim/Locator) | `- [<kind>] <locator>` 형식 필수 |
| `## Plan Deviations` | `## Steps` delta | — | '판단의 정교화' 로 재해석. 없으면 `- none`. 사유에 "판단의 수정 사유" 또는 "새로운 증거" 명시 |
| `## Observed Unknown Kinds` | — | — | evidence_kind 10종 enum 외 관찰치. 없으면 `- none`. 섹션 생략 금지 (awk 경계 보호) |
| `## Next Hop` | `## Questions` | `### Follow-up Session Entry Point` / `### Open Questions` | 다음 세션 진입점 + 리더 판단 필요 항목 |

## [E] 인용 3종 포맷

모든 Outcome 주장(Claim) 은 다음 3 종 중 하나의 고유 번호 증거를 동반합니다.

- `[E1]` 실측값/repo — 실제 측정 수치, 테스트 로그 경로 (예: `grafana/p99_metric.json`, `tests/foo_test.go:88`)
- `[E2]` ADR/정책 인용 — 확정된 ADR, 외부 spec, 승인 기록
- `[E3]` MCP 도구 호출 결과 — sentry trace, stripe API 응답, semgrep finding, metric dashboard 스냅샷

인용이 2 개 이상이면 `[E1][E3]` 처럼 병기합니다. frontmatter 의 `evidence:` 배열에 각 id 를 선언한 뒤 본문에서 참조합니다.

## Self-Reject Trigger

산출물 제출 전 다음 3 질문에 객관적 근거로 답합니다. 하나라도 **No** 이면 self-reject 후 재작성합니다.

1. **[증거의 입증력]**: 인용된 [E] 증거가 Plan 의 Claim 을 단순히 나열하는 수준인가, 아니면 Claim 의 타당성을 확정하는 수준인가?
2. **[판단의 고도화]**: Plan Deviations 가 발생했을 때, 이것이 단순 작업 누락이 아니라 실행 중 발견된 '새로운 증거에 의한 판단의 수정 사유' 임을 입증했는가?
3. **[DoD 의 실질적 해소]**: 최종 결과물이 Plan 에서 식별한 리스크와 Root Cause 를 실제로 제거했음을 [E] 로 확언할 수 있는가?

## 금지 사항

- 8 개 외 top-level `## ` 섹션 추가 금지 (`### ` H3 는 허용)
- 8 개 헤더 문자열 변형 금지 (`### Summary`, `## 요약`, `## 결과` 등 모두 거부)
- Plan Deviations 에 이탈이 있음에도 `- none` 기재
- `## Summary` / `## Outputs` / `## Risks` 첫 bullet 누락 (close-session awk 파싱 실패)
- `## Observed Unknown Kinds` 섹션 통째 생략 (awk 경계 패턴에 영향)
- 채팅으로 결과만 설명하고 파일을 갱신하지 않는 것
- [E] 인용 마커 없이 Claim 을 단정적으로 기술

## 검증 실패 조건

세션 종료 시 자동 검증이 실행됩니다. 다음 중 하나라도 해당하면 **세션이 즉시 실패로 처리**됩니다:

- 파일 미갱신 (내용이 템플릿 seed 와 동일)
- 8 섹션 헤더 중 하나라도 누락 또는 변형
- `## Summary` / `## Outputs` / `## Risks` 첫 `- ` bullet 미작성
- `## Evidence Delivered` 섹션에서 `- [<kind>]` 포맷 위반
- `## Plan Deviations` 에 이탈이 있음에도 `- none` 기재
- 본문에 `[E1]` / `[E2]` / `[E3]` 인용 마커 0 개
- `## Delivered Outputs` 표의 Status 컬럼 누락

## 첫 응답 예시 (참고 — ADR-0085 결제 retry v2 가상 결과 3줄)

```markdown
# Compact Result

## Summary
- [E1][E2] 실행 데이터 대조 결과, Plan 가설과 달리 런타임 병목 증거가 확보되어
  판단을 수정했습니다. [E3] 는 수정된 설계가 DoD 를 충족함을 입증하며,
  본 결과물은 Plan 의 판단이 실제 환경에서 어떻게 검증되었는지 확언합니다.

### Claim → Outcome
- Plan Claim "P99 ≤ 250ms" → 실측 247ms 달성 [E1]
- Plan DoD "100회 → 1건 처리" → 통합 테스트 100/100 pass [E2]

### Evidence Matching
- [E1] grafana P99 metric 이 Success Metric 을 확정
- [E3] sentry circuit breaker trace 가 R2 mitigation 동작을 확증
```

작성 완료 후 채팅에는 다음 한 줄만 보내세요:

```
compact-result.md 갱신 완료. 세션 종료 가능.
```

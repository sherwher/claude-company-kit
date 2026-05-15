# UI Behavior Spec

> **owner**: `ux-designer` (Sage)
> **format**: 컴포넌트 레벨 interaction 명세 — 이벤트 / 전이 / timing / edge case

## 1. 대상 컴포넌트

-

## 2. 이벤트 시트

| event | trigger | result | fallback |
|---|---|---|---|
| onClick |  |  |  |
| onHover |  |  |  |
| onFocus |  |  |  |
| onKeyDown(Escape) |  |  |  |
| onKeyDown(Enter) |  |  |  |

## 3. Timing / Easing

- debounce:
- throttle:
- transition:
- animation reduce-motion fallback:

## 4. Edge Case

- 긴 텍스트 (20+ 자) 잘림 / wrap / ellipsis
- 빈 값 / null / undefined
- 오류 / timeout
- 권한 거부
- 네트워크 끊김
- 다국어 / RTL

## 5. Component Reuse

- 기존 디자인 시스템 컴포넌트 사용:
- 신규 컴포넌트 필요 시 rationale:
- brand token 참조:

## 6. Verification

- [ ] 6 상태 × 이벤트 매트릭스 전수 verified
- [ ] 키보드 only 테스트 통과
- [ ] Screen reader 라벨 읽힘 확인
- [ ] 모바일 터치 타겟 ≥ 44×44 px

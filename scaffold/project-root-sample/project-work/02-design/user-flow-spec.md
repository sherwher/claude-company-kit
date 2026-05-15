# User Flow Spec

> **owner**: `ux-designer` (Sage)
> **format**: State machine — 화면당 6 상태 (loading / empty / partial / success / error / disabled) × 전이 + reversibility

## 1. User Task

이 flow 에서 사용자가 달성하려는 **단일** task. task 없는 flow 는 장식이다.

-

## 2. Flow Overview

```
entry → [screen-A] → [screen-B] → exit
          ↓ error      ↓ error
       [recovery-A]  [recovery-B]
```

## 3. Screen 별 State Matrix

### Screen A

| 상태 | 설명 | UI 변화 | CTA |
|---|---|---|---|
| loading |  |  |  |
| empty |  |  |  |
| partial |  |  |  |
| success |  |  |  |
| error |  |  |  |
| disabled |  |  |  |

## 4. Reversibility Table

| action | reversible? | undo mechanism |
|---|---|---|
|  |  |  |

## 5. Accessibility Checklist

- [ ] Contrast WCAG AA (≥ 4.5:1 본문, ≥ 3:1 큰 텍스트 / UI 요소)
- [ ] Keyboard nav: Tab order 명시, focus ring 가시
- [ ] ARIA: `role` / `aria-labelledby` / `aria-describedby`
- [ ] Focus trap (모달 / 오버레이)
- [ ] Screen reader 알림 (error / success)

## 6. Handoff Annotation

- spacing tokens 사용:
- timing / easing:
- breakpoint: mobile / tablet / desktop

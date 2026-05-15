---
name: spawn-worker
description: 기존 세션에 추가 워커 spawn (supporting workers)
---

# /claude-company-kit:spawn-worker

이미 `/rw` 로 세션이 시작된 후, supporting 워커를 추가 spawn 할 때 사용.

## 사용법

```
/claude-company-kit:spawn-worker <worker-type> <topic>
```

## 자동 진행 규칙

- 토픽 승인 시점에 일괄 승인됨 (재승인 없음)
- 다수 워커 동시 spawn 은 `spawn-and-submit-batch.sh` 한 호출로 묶기
- 정지 지점: plan 도착 / 외부 write / 파괴적 작업

자세한 정책은 프로젝트 CLAUDE.md 참조.

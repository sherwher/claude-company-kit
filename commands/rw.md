---
name: rw
description: 회사 워커 라우팅 + 세션 시작 — 한 명령으로 전체 준비
---

# /claude-company-kit:rw

세션 시작 명령. 다음을 한 번에 수행:

1. **토픽 분석 + 워커 라우팅** — `<topic>` 입력을 받아 적절한 워커 선택 (engineer / researcher / 기타)
2. **세션 준비** — `prepare-session.sh` 실행, runner 자동 해상도 (sequential / tmux / cmux)
3. **워커 spawn** — `prepare-worker.sh` + 러너별 spawn 실행
4. **첫 메시지 전송** — `worker-request.md` 를 워커에 전달

## 사용법

```
/claude-company-kit:rw "원하는 주제"
```

## 자동 진행

토픽 승인 후 다음 단계까지 사용자 재승인 없이 진행. 정지 지점: 워커 plan 도착 시 / 외부 서비스 write 시 / 파괴적 작업 시.

자세한 정책은 프로젝트 CLAUDE.md 참조.

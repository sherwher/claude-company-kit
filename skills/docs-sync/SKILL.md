---
name: docs-sync
description: Use this skill when project-work files, README content, architecture notes, or delivery docs need to stay aligned after a decision or implementation change.
---

# Docs Sync

## 목적

- 결정 사항과 실제 문서를 어긋나지 않게 유지한다.
- 구현 후 `project-work/`, README, handoff 문서 갱신 포인트를 빠르게 찾는다.

## 언제 사용하나

- 구현 또는 설계 변경 후 문서 반영이 필요할 때
- handoff 전에 문서 최신화를 해야 할 때
- 여러 팀이 같은 기준 문서를 공유할 때

## 기본 절차

1. 바뀐 사실과 아직 안 바뀐 문서를 분리한다.
2. `project-work/` 우선 경로를 확인한다.
3. 영향 받는 README, architecture note, export 문서를 갱신한다.
4. 어떤 문서를 고쳤고 무엇을 아직 안 고쳤는지 남긴다.

## 기대 산출물

- 갱신 대상 문서 목록
- 실제 수정된 문서 경로
- 후속 문서 작업 항목

## 주의사항

- 구현되지 않은 내용을 문서에 미리 확정하지 않는다.
- 모든 문서를 한 번에 갱신하려 하지 않는다.
- source of truth를 `project-work/`와 실제 코드에서 먼저 찾는다.

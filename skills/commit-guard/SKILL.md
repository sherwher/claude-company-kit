---
name: commit-guard
description: Use this skill when a repo needs consistent pre-commit checks, formatting, linting, or policy gates before changes are committed or shared.
---

# Commit Guard

## 목적

- 커밋 전에 최소 품질 기준을 자동으로 확인한다.
- 포맷, 린트, 금지 파일, 정책 위반을 빠르게 잡는다.

## 언제 사용하나

- 여러 팀이 같은 저장소를 건드릴 때
- 커밋 전 기본 검증을 강제하고 싶을 때
- `pre-commit` 또는 유사 hook 구성이 필요할 때

## 기본 절차

1. 현재 저장소의 포맷터, 린터, 테스트 entrypoint를 확인한다.
2. 커밋 전 반드시 돌려야 할 최소 검사만 정한다.
3. `pre-commit` 또는 동등한 훅 구성을 만든다.
4. 실패 메시지가 무엇을 고쳐야 하는지 바로 보이게 한다.
5. 운영 문서에는 “커밋 전 실행 기준”만 짧게 남긴다.

## 기대 산출물

- hook 설정 파일
- 실행 대상 검사 목록
- 실패 시 수정 가이드

## 주의사항

- 느린 전체 테스트를 기본 hook에 넣지 않는다.
- 로컬에서 자주 깨지는 flaky 검사는 기본 guard에서 제외한다.
- 팀 합의 없는 과한 정책은 도입하지 않는다.

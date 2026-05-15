---
name: task-orchestrator
description: Use this skill when a repo uses Taskfile.yml or needs repeatable worker commands for build, test, lint, export, bootstrap, or multi-step project routines.
---

# Task Orchestrator

## 목적

- 반복되는 명령을 `Taskfile` 중심으로 정리해 워커 간 실행 차이를 줄인다.
- 빌드, 테스트, export, bootstrap 작업을 짧은 명령으로 표준화한다.

## 언제 사용하나

- 같은 명령을 워커마다 반복할 때
- 문서화된 실행 순서를 실제 명령으로 고정하고 싶을 때
- `tmux` 세션에서 워커별 공통 작업을 맞출 때

## 기본 절차

1. 저장소에 `Taskfile.yml` 또는 `Taskfile.yaml`이 있는지 확인한다.
2. 기존 task 이름과 역할을 파악한다.
3. 중복되는 쉘 명령을 task로 묶을 후보를 찾는다.
4. 워커별 실행 entrypoint를 간단한 task로 정의한다.
5. README 또는 운영 문서에서 task 이름만 노출되게 정리한다.

## 기대 산출물

- 새 task 또는 정리된 task 목록
- 워커별 실행 entrypoint
- 문서와 실제 명령의 정렬

## 주의사항

- task 안에 과도한 비즈니스 로직을 넣지 않는다.
- 워커 전용 task는 이름에 목적이 드러나게 쓴다.
- 이미 package script, make, shell script가 표준이면 불필요하게 중복 만들지 않는다.

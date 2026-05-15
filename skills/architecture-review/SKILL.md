---
name: architecture-review
description: Use this skill when a team needs to review module boundaries, API/data contracts, service responsibilities, or architecture risks before execution or approval.
---

# Architecture Review

## 목적

- 구조 변경이 필요한지, 어디가 깨지기 쉬운지 빠르게 드러낸다.
- 프론트엔드, 백엔드, 데이터 경계를 leader 승인 전에 확인한다.

## 언제 사용하나

- 기능 추가가 기존 구조를 건드릴 때
- API, schema, component boundary를 다시 봐야 할 때
- 리뷰에서 구조 리스크가 중요할 때

## 기본 절차

1. 관련 `project-work/03-frontend`, `04-backend`, `06-erd`를 먼저 읽는다.
2. 코드에서 실제 boundary와 문서 boundary가 맞는지 본다.
3. coupling, ownership, contract risk를 분리한다.
4. 큰 변경 없이 해결 가능한지 먼저 판단한다.
5. 리팩터링이 필요하면 최소 경로를 제안한다.

## 기대 산출물

- 구조 리스크 목록
- 영향 받는 모듈 또는 계약
- 최소 변경안 또는 대안

## 주의사항

- 이상적인 구조 제안만 하지 않는다.
- scope 밖 대공사를 기본 선택지로 두지 않는다.
- 문서 구조와 실제 코드 구조가 다르면 둘 다 명시한다.

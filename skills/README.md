# Skills Index

이 디렉터리는 템플릿에서 공통으로 제공하는 skill과 예시를 둡니다.

## 운영 원칙

- `.company-kit/skills/`는 공통 skill 인덱스입니다.
- 프로젝트 전용 skill은 `.company-project/skills/`에 둡니다.
- 각 skill은 `triggers` 키워드를 통해 Claude가 자동으로 적용합니다.

## Skill 목록

### 계획/분석

| Skill | 용도 | 핵심 트리거 |
|-------|------|------------|
| [issue-deconstructor](issue-deconstructor/SKILL.md) | 모호한 요청 → 실행 가능한 태스크로 분해 | "요구사항 분해", "scope 정리" |
| [implementation-planner](implementation-planner/SKILL.md) | 구현 계획 수립 (단계/검증/리스크) | "구현 계획", "plan mode" |
| [research-brief](research-brief/SKILL.md) | 자료 압축 요약 | "리서치", "자료 정리" |
| [architecture-review](architecture-review/SKILL.md) | 구조/경계/리스크 리뷰 | "아키텍처 리뷰", "구조 확인" |

### 실행/검증

| Skill | 용도 | 핵심 트리거 |
|-------|------|------------|
| [verification-loop](verification-loop/SKILL.md) | 증거 기반 완료 검증 | "검증", "완료 확인" |
| [browser-qa](browser-qa/SKILL.md) | 브라우저 QA 체크리스트 | "브라우저 테스트", "UI 확인" |
| [commit-guard](commit-guard/SKILL.md) | 커밋 전 품질 게이트 | "커밋 전 확인", "PR 준비" |
| [task-orchestrator](task-orchestrator/SKILL.md) | 다중 태스크 조율 | "태스크 조율", "병렬 작업" |

### 문서/기록

| Skill | 용도 | 핵심 트리거 |
|-------|------|------------|
| [context-saver](context-saver/SKILL.md) | 작업 맥락 압축 저장/인수인계 | "인수인계", "handoff", "context 저장" |
| [decision-log](decision-log/SKILL.md) | 의사결정 근거 기록 (ADR-lite) | "결정 기록", "왜 이걸 선택" |
| [docs-sync](docs-sync/SKILL.md) | 문서-코드 동기화 | "문서 업데이트", "docs sync" |
| [doc-export](doc-export/SKILL.md) | 문서 내보내기 | "문서 내보내기", "export" |
| [prompt-eval](prompt-eval/SKILL.md) | 프롬프트 품질 평가 | "프롬프트 평가", "prompt eval" |

## Skill 파일 구조

각 skill의 `SKILL.md`는 아래 섹션을 포함합니다:

```
---
name: skill-name
description: Claude가 이 skill을 언제 적용할지 판단하는 설명
triggers: [트리거 키워드 목록]
---

# Skill Name
## 목적
## 언제 사용하나
## 기본 절차
## Quick Template    ← 바로 복붙 가능한 템플릿
## Anti-Patterns     ← 하지 말아야 할 것
## Golden Standard   ← 이상적인 결과물 예시
## 기대 산출물
```

## Skill Packs

워커별 기본 skill 묶음: [packs/README.md](packs/README.md)

## 새 Skill 추가 방법

1. `skills/<skill-name>/SKILL.md` 생성
2. frontmatter에 `name`, `description`, `triggers` 작성
3. 이 README의 목록에 추가
4. 해당 워커의 pack에 추가 (선택)

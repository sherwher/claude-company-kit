---
name: doc-export
description: Use this skill when markdown, notes, or proposal drafts need conversion into shareable deliverables such as docx, pdf, or html using Pandoc-style export flows.
---

# Doc Export

## 목적

- 내부 초안을 외부 공유 가능한 문서 형식으로 변환한다.
- 제안서, 보고서, 제출본 export를 반복 가능하게 만든다.

## 언제 사용하나

- Markdown 초안을 docx 또는 pdf로 바꿔야 할 때
- 제출용 문서를 일관된 형식으로 내보내야 할 때
- 외부 공유본을 `.company-exports/`로 승격할 때

## 기본 절차

1. source 문서와 target format을 정한다.
2. 기본 템플릿 또는 스타일 요구사항이 있는지 확인한다.
3. Pandoc 또는 동등한 export 명령을 준비한다.
4. 출력 파일명과 저장 위치를 명확히 정한다.
5. 최종 공유본만 `.company-exports/`로 올린다.

## 기대 산출물

- source 파일 경로
- export 명령 또는 변환 방식
- output 파일 경로
- 제출 전 확인 포인트

## 주의사항

- 중간 초안까지 모두 export하지 않는다.
- 공유본과 내부 초안 경로를 섞지 않는다.
- 표, 이미지, 폰트 등 깨질 수 있는 요소는 export 후 확인한다.

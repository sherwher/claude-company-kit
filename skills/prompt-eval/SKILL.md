---
name: prompt-eval
description: Use this skill when prompts, model outputs, or evaluation rubrics need repeatable comparison using promptfoo or a similar prompt evaluation workflow.
---

# Prompt Eval

## 목적

- 프롬프트 변경 전후 결과를 비교한다.
- 팀이 감으로 판단하지 않고 기준 있는 eval을 남기게 한다.

## 언제 사용하나

- 프롬프트 품질 비교가 필요할 때
- 여러 모델 또는 여러 프롬프트 버전을 비교할 때
- red-team 또는 회귀 체크가 필요할 때

## 기본 절차

1. 평가 대상 prompt와 비교 대상 버전을 정한다.
2. 평가 기준을 3개 이하 핵심 항목으로 압축한다.
3. 대표 input set을 만든다.
4. promptfoo 설정 또는 동등한 eval 구성을 만든다.
5. 결과를 표나 bullet로 요약한다.

## 기대 산출물

- 평가 대상 목록
- 테스트 input 세트
- pass/fail 또는 점수 기준
- 비교 결과 요약

## 주의사항

- 평가 기준이 없으면 숫자만 남기지 않는다.
- 데이터 샘플은 대표성 있는 최소 세트만 쓴다.
- 모델 비용이 큰 전체 배치를 기본 실행으로 두지 않는다.

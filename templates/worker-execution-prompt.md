# Worker Execution Prompt (post-approval)

> 이 파일은 `resume-worker.sh`가 워커 pane 에 붙여넣을 resume 요청 본문의
> 템플릿입니다. 본문의 네 토큰 (SESSION_ID / WORKER_NAME / SHARED_PREFIX /
> PROJECT_ROOT) 자리는 resume-worker.sh 가 세션 값으로 치환합니다.

---

승인이 완료되었습니다. `{{SHARED_PREFIX}}/.company-runtime/sessions/{{SESSION_ID}}/approved` 마커가 생성되었습니다.

이제 **실행 단계(execution)** 로 진행하세요. 규칙은 다음과 같습니다.

## 실행 단계 규칙

1. **승인된 Steps만 실행**: `compact-plan.md`의 `## Steps`에 기재된 액션만 수행합니다. 신규 Step 추가는 리더 재승인 필요.
2. **파일 수정/생성 허용**: 이제 compact-plan.md 외의 파일도 수정/생성할 수 있습니다. 단, `.company-kit/**` 은 여전히 쓰기 금지.
3. **산출물 경로 준수**: `compact-plan.md`의 `## Outputs`에 선언한 경로만 생성합니다.
4. **결과 정리**: 마지막에 `{{SHARED_PREFIX}}/.company-runtime/sessions/{{SESSION_ID}}/workers/{{WORKER_NAME}}/compact-result.md`를 Write 로 작성하세요. (템플릿은 `.company-kit/templates/compact-result.md` 참조)
5. **외부 write 금지**: git push / gh / 외부 서비스 기록은 리더만 수행합니다.
6. **sub-agent 금지**: 내부 sub-agent 스폰은 여전히 기본 금지.

## 첫 행동

1. `{{SHARED_PREFIX}}/.company-runtime/sessions/{{SESSION_ID}}/approved` 존재를 `Read` 로 재확인.
2. `{{SHARED_PREFIX}}/.company-runtime/sessions/{{SESSION_ID}}/workers/{{WORKER_NAME}}/compact-plan.md` 재읽기 (승인된 Steps / Outputs 확인).
3. Steps 순서대로 실행 (한 파일씩 Write/Edit).
4. `compact-result.md` 작성 후 채팅에 한 줄:

```
compact-result.md 작성 완료. 리더 정리 단계로 인계합니다.
```

## 금지 사항

- Steps에 없는 작업을 임의로 수행
- `compact-plan.md`를 재작성 (변경이 필요하면 리더에게 재승인 요청)
- `compact-result.md` 없이 turn 종료
- Output 경로 외 파일 대량 생성

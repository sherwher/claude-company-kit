# Start Here

이 프로젝트는 `team-profile-company` 템플릿을 사용합니다.
이 문서만 보고 시작합니다. 나머지는 막힐 때만 읽습니다.

## 시작 방법

Claude 를 실행한 뒤:

```
/rw "원하는 주제"
```

터미널에서 바로 실행하려면 `company run "원하는 주제"`를 사용합니다. tmux 안에서는 병렬 워커 pane을 쓸 수 있고, tmux 밖에서는 sequential 로 자동 폴백됩니다. cmux 는 experimental 단계라 `--runner=cmux --allow-experimental` 명시 opt-in 이 필요합니다.

이것만 기억하면 됩니다. Claude가 적합한 워커를 추천하고, 승인하면 실행합니다.

## 기본 흐름

| 단계 | 동작 |
|------|------|
| **Run** | `/rw "주제"` 입력 |
| **Approve** | 워커 plan 검토 후 승인 |
| **Close** | `company close <id>` |

## 처음 확인할 설정 파일

1. `.company-project/project-standards.md` — 프로젝트 규칙
2. `.company-project/model-policy.md` — 모델 정책
3. `project-work/00-project/working-agreements.md` — 워킹 어그리먼트

## 핵심 명령

| 명령 | 용도 |
|------|------|
| `/rw <topic>` | 세션 시작 |
| `company run "<topic>"` | 터미널에서 세션 시작 |
| `company status` | 현재 상태 확인 |
| `company doctor` | 환경/설정 진단 |
| `company close <id>` | 세션 종료 |

## 핵심 규칙

- 리더는 판단과 승인만 한다 — 직접 코드/문서 작성 금지
- 워커는 plan을 먼저 제출하고, 승인 후에만 실행
- 확정 산출물은 `project-work/`, 임시 산출물은 `.company-artifacts/`
- 동시 활성 워커 최대 5개

## 막히면

1. `.company-kit/docs/guides/LEADER_MINIMAL_PATH.md`
2. `.company-kit/docs/guides/PRACTICAL_USAGE_GUIDE.md`
3. `.company-kit/docs/reference/REFERENCE.md` — 워커 목록, CLI 전체 명령

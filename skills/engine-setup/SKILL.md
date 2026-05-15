---
name: engine-setup
description: 게임 엔진 프로젝트 초기 설정을 구조화할 때 사용. 렌더 파이프라인, 폴더 구조, 빌드 설정.
triggers:
  - "엔진 설정"
  - "engine setup"
  - "Unity 프로젝트"
  - "Unreal 프로젝트"
  - "프로젝트 구조"
---

# Engine Setup

## 목적

- Unity 또는 UE5 프로젝트의 초기 설정을 표준화해 팀 환경 불일치를 방지한다.
- 렌더 파이프라인, 빌드 타겟, 에셋 관리 정책을 문서화해 온보딩 비용을 줄인다.
- 버전 관리(.gitignore, LFS) 설정을 초기에 확립해 리포지터리 오염을 막는다.

## 언제 사용하나

- 새 게임 엔진 프로젝트를 생성할 때
- unity-engineer 또는 unreal-engineer가 팀 표준 환경을 문서화할 때
- 엔진 버전 업그레이드 또는 렌더 파이프라인 전환 시
- 신규 팀원이 개발 환경을 셋업할 때

## 기본 절차

1. 엔진과 버전을 확정한다 (Unity 6 / UE5.x).
2. 표준 폴더 구조를 정의한다.
3. 렌더 파이프라인을 선택한다 (URP/HDRP/Built-in 또는 Lumen/Nanite).
4. 빌드 타겟(플랫폼, 최적화 설정)을 명시한다.
5. 에셋 관리 정책(Git LFS 대상, 네이밍, 폴더 규칙)을 작성한다.
6. 버전 관리 설정(.gitignore, .gitattributes)을 확인한다.
7. `project-work/12-game-production/engine-config.md`에 저장한다.

## Quick Template

```markdown
# 엔진 설정: <프로젝트명>

- 날짜: <YYYY-MM-DD>
- 작성자: <unity-engineer | unreal-engineer>
- 엔진: <Unity 6.0.x | Unreal Engine 5.x>

## 프로젝트 구조
```
Assets/
├── _Project/           # 프로젝트 전용 에셋
│   ├── Art/
│   ├── Audio/
│   ├── Prefabs/
│   ├── Scenes/
│   └── Scripts/
├── ThirdParty/         # 외부 플러그인
└── StreamingAssets/    # 런타임 로드 에셋
```

## 렌더 파이프라인
- 파이프라인: <URP / HDRP / Built-in>
- 선택 이유: <예: 모바일 타겟으로 URP 선택>
- 주요 설정: <예: Shadow Distance 50m, Max Lights Per Object 4>

## 빌드 설정
| 플랫폼 | IL2CPP | 최적화 레벨 | 최소 사양 |
|--------|--------|-------------|-----------|
| <PC (Windows)> | <On> | <Release> | <GTX 1060, 8GB RAM> |
| <Android> | <On> | <Release> | <Android 10, 3GB RAM> |

## 에셋 관리 정책
- Git LFS 대상: `*.psd, *.fbx, *.wav, *.mp4, *.unitypackage`
- 네이밍: `T_<이름>` (텍스처), `M_<이름>` (머티리얼), `SM_<이름>` (스태틱 메시)
- 씬 네이밍: `<레벨번호>_<레벨명>` (예: `01_Tutorial`)

## 버전 관리
- .gitignore: Unity/UE5 공식 템플릿 사용
- LFS tracked: 위 에셋 관리 정책 참조
- 브랜치 전략: `main` (릴리즈) / `develop` (통합) / `feature/*`
```

## Anti-Patterns

❌ 렌더 파이프라인 선택 이유 없이 설정만 기록 — 나중에 전환 시 근거 없음
❌ Git LFS 없이 바이너리 에셋 커밋 — 리포지터리 용량 폭발
❌ 폴더 구조 없이 개발 시작 — 에셋이 루트에 흩어져 검색 불가

## Golden Standard

```markdown
# 엔진 설정: Echoes of the Void

- 날짜: 2026-04-10
- 작성자: unity-engineer
- 엔진: Unity 6.0.28 (LTS)

## 렌더 파이프라인
- 파이프라인: URP (Universal Render Pipeline)
- 선택 이유: PC + 모바일 동시 타겟, 퍼포먼스 우선
- 주요 설정: Shadow Distance 30m, MSAA 4x, HDR On

## 빌드 설정
| 플랫폼 | IL2CPP | 최적화 | 최소 사양 |
|--------|--------|--------|-----------|
| Windows | On | Release | GTX 960, 8GB |
| Android | On | Release | Snapdragon 730, 4GB |

## 에셋 관리
- LFS: `*.psd *.fbx *.wav *.mp3 *.png(>1MB)`
- 네이밍: `T_`, `M_`, `SM_`, `SFX_`, `BGM_` 접두사 필수
- 씬: `01_MainMenu`, `02_Tutorial`, `03_Chapter1`
```

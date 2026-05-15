# Engine Config

> **owner**: `unity-engineer` / `unreal-engineer`
> **format**: 엔진 프로젝트 초기 설정 기준 — 렌더링, 물리, 입력, 빌드 설정의 SSOT

## 1. 프로젝트 기본 정보

| 항목 | 값 |
|---|---|
| 엔진 |  |
| 엔진 버전 |  |
| 렌더 파이프라인 |  |
| 스크립팅 백엔드 |  |
| 타겟 플랫폼 |  |

## 2. 렌더링 설정

### 공통

| 파라미터 | 값 | 사유 |
|---|---|---|
| 렌더링 해상도 |  |  |
| Anti-Aliasing |  |  |
| Shadow Quality |  |  |
| Post Processing |  |  |

### Unity 전용

| 파라미터 | 값 |
|---|---|
| Render Pipeline | URP / HDRP |
| Color Space | Linear |
| Graphics API |  |
| SRP Batcher |  |

### Unreal Engine 5 전용

| 파라미터 | 값 |
|---|---|
| Nanite | enabled / disabled |
| Lumen | enabled / disabled |
| Virtual Shadow Maps | enabled / disabled |
| World Partition | enabled / disabled |

## 3. 물리 설정

| 파라미터 | 값 | 사유 |
|---|---|---|
| Fixed Timestep |  |  |
| Gravity |  |  |
| Collision Layer 구조 |  |  |

## 4. 입력 설정

| 입력 방식 | 시스템 | 비고 |
|---|---|---|
| Keyboard/Mouse |  |  |
| Gamepad |  |  |
| Touch |  |  |

## 5. 빌드 설정

| 플랫폼 | 빌드 타겟 | 압축 | 서명 |
|---|---|---|---|
| PC |  |  |  |
| Console |  |  |  |
| Mobile |  |  |  |

## 6. 플러그인 / 패키지

| 이름 | 버전 | 용도 | 필수 여부 |
|---|---|---|---|
|  |  |  | required / optional |

## 7. 코딩 규칙

- **네이밍 컨벤션**:
- **폴더 구조**:
- **금지 패턴**:

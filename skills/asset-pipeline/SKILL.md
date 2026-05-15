---
name: asset-pipeline
description: 게임 에셋 파이프라인을 설계할 때 사용. 에셋 스펙, 임포트 설정, 네이밍, 최적화 기준.
triggers:
  - "에셋 파이프라인"
  - "asset pipeline"
  - "에셋 스펙"
  - "아트 파이프라인"
  - "에셋 관리"
---

# Asset Pipeline

## 목적

- 에셋 유형별 스펙과 임포트 설정을 표준화해 아티스트-엔지니어 간 전달 오류를 없앤다.
- 네이밍 규칙과 폴더 구조를 명문화해 에셋 검색 및 참조 오류를 방지한다.
- LOD 정책과 최적화 기준을 정의해 런타임 퍼포먼스 목표를 달성한다.

## 언제 사용하나

- game-artist 또는 technical-artist가 에셋 제작 표준을 수립할 때
- 에셋 임포트 오류나 최적화 문제가 반복될 때
- 신규 아티스트 온보딩 시 제작 가이드라인이 필요할 때
- engine-setup과 함께 프로젝트 초기 아트 파이프라인을 설계할 때

## 기본 절차

1. 에셋 유형을 분류한다 (3D 메시, 텍스처, 애니메이션, 오디오, UI).
2. 유형별 스펙을 정의한다 (폴리곤 수, 텍스처 해상도, 메모리 예산).
3. 네이밍 규칙을 정의한다 (접두사 + 이름 + 접미사 체계).
4. 임포트 설정을 유형별로 명시한다 (압축 방식, Mip Map, 콜라이더 등).
5. LOD 정책을 정의한다 (거리별 LOD 레벨과 폴리곤 감소율).
6. 검수 체크리스트를 작성한다 (임포트 전/후 확인 항목).
7. `project-work/12-game-production/asset-pipeline.md`에 저장한다.

## Quick Template

```markdown
# 에셋 파이프라인: <프로젝트명>

- 날짜: <YYYY-MM-DD>
- 작성자: <technical-artist | game-artist>
- 엔진: <Unity / Unreal>

## 1. 에셋 분류
| 유형 | 포맷 | 담당 |
|------|------|------|
| 3D 메시 | .fbx | game-artist |
| 텍스처 | .png / .tga | game-artist |
| 애니메이션 | .fbx | game-artist |
| 오디오 | .wav (원본) | sound-designer |
| UI | .png / .svg | ux-designer |

## 2. 스펙 테이블
| 유형 | 항목 | 주요 캐릭터 | 배경 오브젝트 | 소품 |
|------|------|-------------|---------------|------|
| 3D 메시 | 최대 폴리곤 | <8,000 tri> | <3,000 tri> | <500 tri> |
| 텍스처 | 최대 해상도 | <2048x2048> | <1024x1024> | <512x512> |
| 텍스처 | 포맷 (모바일) | <ETC2> | <ETC2> | <ETC2> |
| 텍스처 | 포맷 (PC) | <BC7> | <BC7> | <BC3> |

## 3. 네이밍 규칙
| 유형 | 접두사 | 예시 |
|------|--------|------|
| 텍스처 (Albedo) | `T_` | `T_PlayerArmor_D` |
| 텍스처 (Normal) | `T_` + `_N` 접미사 | `T_PlayerArmor_N` |
| 머티리얼 | `M_` | `M_PlayerArmor` |
| 스태틱 메시 | `SM_` | `SM_Barrel_01` |
| 스켈레탈 메시 | `SK_` | `SK_Player` |
| 애니메이션 | `A_` | `A_Player_Run` |
| 오디오 (SFX) | `SFX_` | `SFX_Sword_Hit` |
| 오디오 (BGM) | `BGM_` | `BGM_Chapter1` |

## 4. 임포트 설정
### 텍스처
- Mip Map: On (UI 제외)
- sRGB: On (Albedo) / Off (Normal, Roughness, Metallic)
- 압축: 플랫폼별 스펙 테이블 참조

### 3D 메시
- Scale Factor: 1.0
- Import Normals: Calculate (캐릭터) / Import (환경)
- 콜라이더: 소품만 Mesh Collider 허용, 나머지 Primitive

### 오디오
- 원본: 44100Hz / 16-bit WAV
- 임포트: 모바일 Vorbis / PC PCM
- 3D 오디오: SFX On, BGM Off

## 5. LOD 정책
| LOD 레벨 | 거리 | 폴리곤 비율 |
|----------|------|-------------|
| LOD 0 | 0-10m | 100% |
| LOD 1 | 10-30m | 50% |
| LOD 2 | 30-60m | 25% |
| Cull | 60m+ | 렌더링 제외 |

## 6. 검수 체크리스트
### 임포트 전
- [ ] 네이밍 규칙 준수 확인
- [ ] 폴리곤 수 기준 이하 확인
- [ ] UV 언래핑 완료 (lightmap UV 포함)
- [ ] 원점(Pivot) 정렬 확인

### 임포트 후
- [ ] 엔진 내 스케일 정상 확인
- [ ] 텍스처 압축 설정 적용 확인
- [ ] 모바일 프리뷰 모드 시각 확인
- [ ] 메모리 프로파일러 예산 초과 없음
```

## Anti-Patterns

❌ 네이밍 규칙 없이 "자유롭게" — 3개월 후 에셋 검색 불가
❌ LOD 없이 고해상도 메시를 원거리에서 렌더링 — 퍼포먼스 드롭
❌ 원본 PSD를 리포지터리에 직접 커밋 — Git LFS 없으면 용량 폭발

## Golden Standard

```markdown
# 에셋 파이프라인: Echoes of the Void

- 날짜: 2026-04-10
- 작성자: technical-artist
- 엔진: Unity 6.0 / URP

## 스펙 테이블 (핵심 항목)
| 유형 | 주인공 | 적 | 환경 |
|------|--------|-----|------|
| 최대 폴리곤 | 8,000 | 4,000 | 2,000 |
| 텍스처 해상도 | 2048 | 1024 | 1024 |
| Draw Call 예산 | 50 | 20/유닛 | 30/씬 |

## 네이밍 예시
- `SK_Player` — 플레이어 스켈레탈 메시
- `T_Player_Armor_D` — 플레이어 갑옷 Albedo
- `A_Player_Attack_01` — 플레이어 공격 애니메이션 1번
- `SFX_CardPlay_Whoosh` — 카드 사용 효과음

## 검수 기준
- 모바일 프리뷰 기준 FPS ≥ 30 유지
- 씬 총 Draw Call ≤ 200
- 텍스처 메모리 예산: 씬당 ≤ 128MB
```

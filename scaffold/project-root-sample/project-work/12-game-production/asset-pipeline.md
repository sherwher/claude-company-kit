# Asset Pipeline

> **owner**: `technical-artist`
> **format**: 에셋 제작 → 엔진 임포트까지의 파이프라인 명세 — 명명 규칙, 포맷, 검수 기준

## 1. 에셋 분류

| 분류 | 포맷 | 해상도/폴리 기준 | 네이밍 규칙 |
|---|---|---|---|
| Character |  |  | `CH_[Name]_[LOD]` |
| Environment |  |  | `ENV_[Zone]_[Name]` |
| Prop |  |  | `PR_[Name]` |
| UI |  |  | `UI_[Screen]_[Element]` |
| VFX |  |  | `VFX_[Name]` |
| Audio |  |  | `SFX_[Name]` / `MUS_[Name]` |

## 2. 파이프라인 단계

```
[Concept] → [Blockout] → [Production] → [Polish] → [Export] → [Engine Import] → [Integration]
```

### 단계별 검수 기준

| 단계 | 검수 항목 | 합격 기준 | 검수자 |
|---|---|---|---|
| Blockout |  |  |  |
| Production |  |  |  |
| Export |  |  |  |
| Integration |  |  |  |

## 3. 엔진 임포트 설정

### Unity

| 에셋 타입 | Import Preset | Compression | Max Size |
|---|---|---|---|
| Texture |  |  |  |
| Mesh |  |  |  |
| Audio |  |  |  |

### Unreal Engine 5

| 에셋 타입 | Import Settings | LOD Policy | Nanite 사용 |
|---|---|---|---|
| Static Mesh |  |  | yes / no |
| Skeletal Mesh |  |  | N/A |
| Texture |  |  | N/A |

## 4. 버전 관리

- **에셋 저장소**:
- **branching 전략**:
- **lock 정책**:
- **대용량 파일 (LFS)**:

## 5. 성능 버짓

| 플랫폼 | 동시 드로콜 | VRAM 버짓 | 텍스처 풀 | 폴리곤 버짓 |
|---|---|---|---|---|
| PC (min spec) |  |  |  |  |
| PC (target) |  |  |  |  |
| Console |  |  |  |  |
| Mobile |  |  |  |  |

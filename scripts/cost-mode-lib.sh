#!/usr/bin/env bash
set -euo pipefail

resolve_cost_mode() {
  local project_root="$1"
  local cost_mode_file="${project_root}/.company-project/cost-mode.md"
  local mode="balanced"

  if [[ -f "${cost_mode_file}" ]]; then
    mode="$(awk -F': ' '/^current_mode:/ {print $2; exit}' "${cost_mode_file}" | tr -d '[:space:]')"
  fi

  case "${mode}" in
    cheap|balanced|deep)
      printf '%s\n' "${mode}"
      ;;
    *)
      printf 'balanced\n'
      ;;
  esac
}

cost_mode_worker_limit() {
  local mode="${1:-balanced}"
  case "${mode}" in
    cheap) printf '1\n' ;;
    balanced) printf '2\n' ;;
    deep) printf '5\n' ;;
    *) printf '2\n' ;;
  esac
}

cost_mode_support_limit() {
  local mode="${1:-balanced}"
  case "${mode}" in
    cheap) printf '0\n' ;;
    balanced) printf '1\n' ;;
    deep) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

cost_mode_summary() {
  local mode="${1:-balanced}"
  case "${mode}" in
    cheap) printf 'cheap: worker 1개, supporting worker 없음, 가장 낮은 토큰 비용\n' ;;
    balanced) printf 'balanced: primary 1개 + supporting 1개까지, 기본 운영 모드\n' ;;
    deep) printf 'deep: 최대 5개 worker까지 확장, 복잡한 주제 전용\n' ;;
    *) printf 'balanced: primary 1개 + supporting 1개까지, 기본 운영 모드\n' ;;
  esac
}

# v1.4 Phase 2: cost-mode 를 user-facing lane 라벨로 매핑
# cheap → micro (단순 탐색/문구 변경/작은 버그 수정)
# balanced → standard (기본 — primary 1, supporting 보수적 1)
# deep → deep (대형 기획/출시/다분야/고위험 작업 전용)
cost_mode_lane() {
  local mode="${1:-balanced}"
  case "${mode}" in
    cheap)    printf 'micro\n' ;;
    balanced) printf 'standard\n' ;;
    deep)     printf 'deep\n' ;;
    *)        printf 'standard\n' ;;
  esac
}

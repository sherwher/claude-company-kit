#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-}"
ROOT="${2:-.}"
RECORD_HISTORY="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${TOPIC}" ]]; then
  echo "Usage: $0 <topic> [project-root]"
  exit 1
fi

# shellcheck source=./git-worktree-lib.sh
source "${SCRIPT_DIR}/git-worktree-lib.sh"
# shellcheck source=./cost-mode-lib.sh
source "${SCRIPT_DIR}/cost-mode-lib.sh"

PROJECT_ROOT="$(resolve_shared_project_root "${ROOT}")"
KIT_ROOT="${PROJECT_ROOT}/.company-kit"
if [[ ! -d "${KIT_ROOT}" ]]; then
  KIT_ROOT="${PROJECT_ROOT}"
fi
KEYWORD_FILE="${KIT_ROOT}/config/worker-routing-keywords.tsv"
WORKER_CATEGORIES_FILE="${KIT_ROOT}/config/worker-categories.tsv"
TEMPLATE_LOCK_FILE="${PROJECT_ROOT}/.company-template.lock"
MODE="$(resolve_cost_mode "${PROJECT_ROOT}")"
WORKER_LIMIT="$(cost_mode_worker_limit "${MODE}")"
SUPPORT_LIMIT="$(cost_mode_support_limit "${MODE}")"
TOPIC_LC="$(printf '%s' "${TOPIC}" | tr '[:upper:]' '[:lower:]')"
ROUTING_FEEDBACK_FILE="${PROJECT_ROOT}/.company-project/routing-feedback.md"
SESSION_HISTORY_FILE="${PROJECT_ROOT}/.company-runtime/pattern-memory/session-history.tsv"

# v1.4 도메인 필터: .company-template.lock 의 categories 와 worker-categories.tsv 를
# 교차 검사해, 프로젝트가 활성화하지 않은 카테고리(예: game)에 속한 워커를 라우팅
# 후보군에서 제외한다. 키워드 오탐(비게임 프로젝트에서 game-* 워커 추천) 차단 목적.
PROJECT_CATEGORIES="base,business,engineering,design"
if [[ -f "${TEMPLATE_LOCK_FILE}" ]]; then
  _lock_categories="$(grep -E '^categories:' "${TEMPLATE_LOCK_FILE}" | sed -E 's/^categories:[[:space:]]*//' | head -n1)"
  [[ -n "${_lock_categories}" ]] && PROJECT_CATEGORIES="${_lock_categories}"
fi

# 활성 카테고리 set (공백 구분, 양쪽에 공백 패딩으로 substring match)
_ACTIVE_CATEGORIES=" $(printf '%s' "${PROJECT_CATEGORIES}" | tr ',' ' ' | tr -s ' ') "

# 비활성 워커 목록 작성 (카테고리가 활성 set 에 없는 워커)
EXCLUDED_WORKERS=""
EXCLUDED_CATEGORIES=""
if [[ -f "${WORKER_CATEGORIES_FILE}" ]]; then
  while IFS=$'\t' read -r _w_name _w_cat; do
    [[ -n "${_w_name}" && "${_w_name}" != \#* ]] || continue
    [[ -n "${_w_cat}" ]] || continue
    if [[ "${_ACTIVE_CATEGORIES}" != *" ${_w_cat} "* ]]; then
      EXCLUDED_WORKERS+="${_w_name},"
      [[ "${EXCLUDED_CATEGORIES}" != *"${_w_cat}"* ]] && EXCLUDED_CATEGORIES+="${_w_cat},"
    fi
  done < "${WORKER_CATEGORIES_FILE}"
fi
EXCLUDED_WORKERS="${EXCLUDED_WORKERS%,}"
EXCLUDED_CATEGORIES="${EXCLUDED_CATEGORIES%,}"

feedback_weight_for_worker() {
  local worker="$1"
  local feedback_file="$2"
  if [[ ! -f "${feedback_file}" ]]; then
    printf '0'
    return 0
  fi

  awk -v worker="${worker}" '
    index($0, "primary=`" worker "`") > 0 {
      if ($0 ~ /feedback=`good`/) score += 3
      else if ($0 ~ /feedback=`overkill`/) score -= 1
      else if ($0 ~ /feedback=`insufficient`/) score -= 2
      else if ($0 ~ /feedback=`wrong-worker`/) score -= 4
    }
    END { print score + 0 }
  ' "${feedback_file}"
}

historical_accuracy_weight_for_worker() {
  local worker="$1"
  local feedback_file="$2"
  if [[ ! -f "${feedback_file}" ]]; then
    printf '0'
    return 0
  fi

  awk -v worker="${worker}" '
    index($0, "primary=`" worker "`") > 0 {
      total++
      if ($0 ~ /feedback=`good`/) good++
      else if ($0 ~ /feedback=`wrong-worker`/) wrong++
    }
    END {
      if (total == 0) {
        print 0
      } else {
        rate = (good * 100 / total)
        weight = int(rate / 25)
        if (wrong > 0) weight -= wrong
        print weight
      }
    }
  ' "${feedback_file}"
}

token_overlap_count() {
  local left="$1"
  local right="$2"
  local left_norm right_norm token count
  left_norm="$(printf '%s' "${left}" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:][:space:]가-힣]/ /g')"
  right_norm="$(printf '%s' "${right}" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:][:space:]가-힣]/ /g')"
  count=0
  for token in ${left_norm}; do
    [[ ${#token} -ge 2 ]] || continue
    if [[ " ${right_norm} " == *" ${token} "* ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s' "${count}"
}

similar_topic_feedback_weight_for_worker() {
  local worker="$1"
  local feedback_file="$2"
  local current_topic="$3"
  if [[ ! -f "${feedback_file}" ]]; then
    printf '0'
    return 0
  fi

  local best_weight=0
  while IFS= read -r line; do
    [[ "${line}" == -\ * ]] || continue
    [[ "${line}" == *"primary=\`${worker}\`"* ]] || continue

    IFS='|' read -r _raw_date raw_topic _raw_primary _raw_support raw_feedback <<< "${line}"
    local entry_topic overlap base_weight weighted
    entry_topic="$(printf '%s' "${raw_topic}" | xargs)"
    overlap="$(token_overlap_count "${current_topic}" "${entry_topic}")"
    (( overlap > 0 )) || continue

    base_weight=0
    case "${raw_feedback}" in
      *"feedback=\`good\`"*) base_weight=2 ;;
      *"feedback=\`overkill\`"*) base_weight=-1 ;;
      *"feedback=\`insufficient\`"*) base_weight=-2 ;;
      *"feedback=\`wrong-worker\`"*) base_weight=-3 ;;
    esac
    weighted=$((base_weight * overlap))

    if (( weighted > best_weight )); then
      best_weight="${weighted}"
    fi
  done < "${feedback_file}"

  printf '%s' "${best_weight}"
}

find_best_similar_session_pattern() {
  local history_file="$1"
  local current_topic="$2"
  if [[ ! -f "${history_file}" ]]; then
    return 0
  fi

  awk -F'\t' -v topic="${current_topic}" '
    function norm(s) {
      gsub(/[^[:alnum:][:space:]가-힣]/, " ", s)
      return tolower(s)
    }
    function overlap(a, b,    i, n, arr, count, token) {
      a = norm(a)
      b = norm(b)
      n = split(a, arr, /[[:space:]]+/)
      count = 0
      for (i = 1; i <= n; i++) {
        token = arr[i]
        if (length(token) < 2) continue
        if (index(" " b " ", " " token " ") > 0) count++
      }
      return count
    }
    {
      score = overlap(topic, $5)
      if (score > best_score) {
        best_score = score
        best_line = $0
      }
    }
    END {
      if (best_score > 0) print best_line
    }
  ' "${history_file}"
}

auto_cost_hint_from_pattern() {
  local pattern_line="$1"
  if [[ -z "${pattern_line}" || "${pattern_line}" == "none" ]]; then
    printf 'keep-balanced'
    return 0
  fi

  case "${pattern_line}" in
    *$'\tcheap\t'*"feedback=\`insufficient\`"*)
      printf 'upgrade-to-balanced'
      ;;
    *$'\tbalanced\t'*"feedback=\`insufficient\`"*)
      printf 'consider-deep'
      ;;
    *$'\tdeep\t'*"feedback=\`overkill\`"*)
      printf 'downgrade-to-balanced'
      ;;
    *$'\tbalanced\t'*"feedback=\`overkill\`"*)
      printf 'consider-cheap'
      ;;
    *$'\tcheap\t'*"feedback=\`good\`"*)
      printf 'prefer-cheap'
      ;;
    *$'\tbalanced\t'*"feedback=\`good\`"*)
      printf 'prefer-balanced'
      ;;
    *$'\tdeep\t'*"feedback=\`good\`"*)
      printf 'prefer-deep'
      ;;
    *"feedback=\`wrong-worker\`"*)
      printf 'recheck-routing-before-spawn'
      ;;
    *)
      printf 'keep-balanced'
      ;;
  esac
}

best_worker="service-planner"
best_score=-1
best_content_score=0
best_prior_score=0
best_keywords=""
best_support=""
best_feedback_weight="0"
best_similarity_weight="0"
best_accuracy_weight="0"
best_reasons=""
total_content_matched=0

while IFS=$'\t' read -r worker keywords reasons support_workers; do
  [[ -n "${worker}" ]] || continue
  # v1.4 도메인 필터: 비활성 카테고리 워커는 후보에서 즉시 제외
  if [[ -n "${EXCLUDED_WORKERS}" ]] && [[ ",${EXCLUDED_WORKERS}," == *",${worker},"* ]]; then
    continue
  fi
  matched_count=0
  matched=()
  # 토픽을 공백 구분 토큰 배열로 준비 (단어 경계 매칭용)
  read -r -a topic_tokens <<< "${TOPIC_LC}"
  for keyword in ${keywords}; do
    keyword_lc="$(printf '%s' "${keyword}" | tr '[:upper:]' '[:lower:]')"
    keyword_matched=0
    if [[ ${#keyword_lc} -ge 3 ]]; then
      # 3자 이상 키워드: 토큰 단위 정확 매칭 또는 토큰 내 포함 허용
      for token in "${topic_tokens[@]}"; do
        if [[ "${token}" == "${keyword_lc}" || "${token}" == *"${keyword_lc}"* ]]; then
          # false positive 방지: 키워드가 토큰의 일부일 때 키워드 길이가 토큰 길이의 절반 이상이어야 매칭
          if [[ "${token}" == "${keyword_lc}" ]]; then
            keyword_matched=1
            break
          elif (( ${#keyword_lc} * 2 >= ${#token} )); then
            keyword_matched=1
            break
          fi
        fi
      done
    else
      # 2자 이하 키워드(한글 등): 토큰 정확 매칭만 허용
      for token in "${topic_tokens[@]}"; do
        if [[ "${token}" == "${keyword_lc}" ]]; then
          keyword_matched=1
          break
        fi
      done
    fi
    if (( keyword_matched )); then
      matched_count=$((matched_count + 1))
      matched+=("${keyword}")
    fi
  done

  feedback_weight="$(feedback_weight_for_worker "${worker}" "${ROUTING_FEEDBACK_FILE}")"
  similarity_weight="$(similar_topic_feedback_weight_for_worker "${worker}" "${ROUTING_FEEDBACK_FILE}" "${TOPIC}")"
  accuracy_weight="$(historical_accuracy_weight_for_worker "${worker}" "${ROUTING_FEEDBACK_FILE}")"

  # content_score: 키워드 매치 + 유사 피드백 가중치
  content_score=$(( matched_count + similarity_weight ))
  # prior_score: 누적 피드백 + 정확도 가중치
  prior_score=$(( feedback_weight + accuracy_weight ))

  # content가 있을 때만 prior를 boost로 더함. content 없이는 winner 불가 (score=0)
  if (( content_score > 0 )); then
    score=$(( content_score + prior_score ))
  else
    score=0
  fi

  total_content_matched=$(( total_content_matched + matched_count ))

  if (( score > best_score )); then
    best_score="${score}"
    best_content_score="${content_score}"
    best_prior_score="${prior_score}"
    best_worker="${worker}"
    best_feedback_weight="${feedback_weight}"
    best_similarity_weight="${similarity_weight}"
    best_accuracy_weight="${accuracy_weight}"
    best_reasons="${reasons}"
    if (( ${#matched[@]} > 0 )); then
      best_keywords="$(IFS=', '; printf '%s' "${matched[*]}")"
    else
      best_keywords="none"
    fi
    best_support="${support_workers}"
  fi
done < "${KEYWORD_FILE}"

# matched=0인 경우 priors로 뽑힌 winner를 무효화하고 service-planner로 폴백
if (( total_content_matched == 0 )); then
  best_worker="service-planner"
  best_support="brainstormer,strategy-planner"
  best_keywords="fallback-no-content"
  best_reasons="토픽에서 매칭되는 워커 키워드 없음 — 범용 메타 워커로 폴백"
  best_score=0
  best_content_score=0
  best_prior_score=0
fi

supporting_workers="none"
support_skip_reason=""
# v1.4 Phase 2: balanced(standard) 라우팅 보수화
# 키워드 매칭이 부족한 경우(<2개) supporting worker 를 붙이지 않는다.
# 1개 키워드 단독 매칭은 라우팅 신호로 약하므로 supporting 비용을 정당화하지 못한다.
# deep 모드는 대형 작업 전용이라 이 보수화를 적용하지 않는다.
SUPPORT_MIN_MATCHED=0
if [[ "${MODE}" == "balanced" ]]; then
  SUPPORT_MIN_MATCHED=2
fi
if (( SUPPORT_LIMIT > 0 )) && (( total_content_matched < SUPPORT_MIN_MATCHED )); then
  support_skip_reason="balanced 보수화: 매칭 키워드 ${total_content_matched}개 < ${SUPPORT_MIN_MATCHED}개 임계"
elif (( SUPPORT_LIMIT > 0 )) && [[ -n "${best_support}" ]]; then
  IFS=',' read -r -a support_array <<< "${best_support}"
  selected=()
  for worker in "${support_array[@]}"; do
    worker="$(printf '%s' "${worker}" | xargs)"
    [[ -n "${worker}" && "${worker}" != "${best_worker}" ]] || continue
    # v1.4 도메인 필터: supporting 후보에서도 비활성 카테고리 워커 제거
    if [[ -n "${EXCLUDED_WORKERS}" ]] && [[ ",${EXCLUDED_WORKERS}," == *",${worker},"* ]]; then
      continue
    fi
    selected+=("${worker}")
    (( ${#selected[@]} >= SUPPORT_LIMIT )) && break
  done
  if (( ${#selected[@]} > 0 )); then
    supporting_workers="$(IFS=', '; printf '%s' "${selected[*]}")"
  else
    support_skip_reason="primary 외 도메인 적합 supporting 후보 없음"
  fi
elif (( SUPPORT_LIMIT == 0 )); then
  support_skip_reason="cost_mode=${MODE} (supporting 비활성)"
fi
LANE="$(cost_mode_lane "${MODE}")"

history_file="${PROJECT_ROOT}/.company-runtime/pattern-memory/routing-history.tsv"
timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\(..\)$/:\1/')"
if [[ "${RECORD_HISTORY}" == "--record" && -d "${PROJECT_ROOT}/.company-project" ]]; then
  mkdir -p "$(dirname "${history_file}")"
  # 헤더가 없으면 한 번 추가
  if [[ ! -f "${history_file}" ]] || ! head -n1 "${history_file}" 2>/dev/null | grep -q "^timestamp"; then
    printf 'timestamp\tmode\tprimary_worker\tsupporting_workers\ttopic\n' >> "${history_file}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${timestamp}" "${MODE}" "${best_worker}" "${supporting_workers}" "${TOPIC}" >> "${history_file}"
fi

recent_pattern="none"
auto_cost_hint="keep-balanced"
similar_session_pattern="none"
if [[ -f "${SESSION_HISTORY_FILE}" ]]; then
  recent_pattern="$(awk -F'\t' -v worker="${best_worker}" '
    $4 ~ worker {
      if ($6 ~ /feedback=`good`/) good=$0
      last=$0
    }
    END {
      if (good != "") print good
      else if (last != "") print last
    }' "${SESSION_HISTORY_FILE}")"
  [[ -n "${recent_pattern}" ]] || recent_pattern="none"

  similar_session_pattern="$(find_best_similar_session_pattern "${SESSION_HISTORY_FILE}" "${TOPIC}")"
  [[ -n "${similar_session_pattern}" ]] || similar_session_pattern="none"
fi

if [[ "${recent_pattern}" != "none" ]]; then
  auto_cost_hint="$(auto_cost_hint_from_pattern "${recent_pattern}")"
fi

if [[ "${similar_session_pattern}" != "none" ]]; then
  auto_cost_hint="$(auto_cost_hint_from_pattern "${similar_session_pattern}")"
fi

echo "Topic: ${TOPIC}"
echo "Lane: ${LANE}"
echo "Cost Mode: ${MODE}"
echo "Cost Summary: $(cost_mode_summary "${MODE}")"
echo "Auto Cost Hint: ${auto_cost_hint}"
echo "Project Categories: ${PROJECT_CATEGORIES}"
echo "Excluded Categories: ${EXCLUDED_CATEGORIES:-none}"
echo "Recommended Primary Worker: ${best_worker}"
echo "Supporting Workers: ${supporting_workers}"
if [[ "${supporting_workers}" == "none" && -n "${support_skip_reason}" ]]; then
  echo "Supporting Skip Reason: ${support_skip_reason}"
fi
echo "Worker Limit: ${WORKER_LIMIT}"
echo "Routing Why: matched=${best_keywords}; content_score=${best_content_score}; prior_score=${best_prior_score}; feedback_weight=${best_feedback_weight}; similar_feedback=${best_similarity_weight}; accuracy_weight=${best_accuracy_weight}; total=${best_score}"
echo "Recent Similar Pattern: ${recent_pattern}"
echo "Similar Session Pattern: ${similar_session_pattern}"

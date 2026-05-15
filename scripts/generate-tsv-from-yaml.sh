#!/usr/bin/env bash
set -euo pipefail

# generate-tsv-from-yaml.sh
# company.yaml (정본) → 레거시 TSV 파일 자동 생성
# 기존 스크립트가 TSV를 읽으므로, YAML 변경 시 이 스크립트를 실행해 동기화합니다.
#
# 사용: bash scripts/generate-tsv-from-yaml.sh [config-dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${1:-$(cd "${SCRIPT_DIR}/../config" && pwd)}"
YAML_FILE="${CONFIG_DIR}/company.yaml"

if [[ ! -f "${YAML_FILE}" ]]; then
  echo "Error: ${YAML_FILE} not found" >&2
  exit 1
fi

# ── company.yaml 파서 (awk 기반, 우리 포맷 전용) ──
# company.yaml은 2단계 중첩 + 인라인 배열 [a, b, c] 포맷으로 고정됨.
# 범용 YAML 파서가 아님. 포맷 변경 시 이 스크립트도 수정 필요.

parse_workers() {
  awk '
    # 인라인 배열 [a, b, c] → "a,b,c" 변환
    function parse_array(line,    arr, result, n, i) {
      gsub(/.*\[/, "", line)
      gsub(/\].*/, "", line)
      gsub(/^ +| +$/, "", line)
      n = split(line, arr, ", *")
      result = ""
      for (i = 1; i <= n; i++) {
        gsub(/^ +| +$/, "", arr[i])
        if (result != "") result = result ","
        result = result arr[i]
      }
      return result
    }

    # 블록 배열 항목 "  - value" → 공백 구분 문자열로 누적
    function flush_block_array(    result, i) {
      result = ""
      for (i = 1; i <= block_count; i++) {
        if (result != "") result = result " "
        result = result block_items[i]
      }
      block_count = 0
      return result
    }

    # 블록 배열 항목 "  - value" → 파이프(|) 구분 문자열로 누적 (key_questions 전용)
    function flush_block_pipe(    result, i) {
      result = ""
      for (i = 1; i <= block_count; i++) {
        if (result != "") result = result "|"
        result = result block_items[i]
      }
      block_count = 0
      return result
    }

    BEGIN {
      in_workers = 0
      current_worker = ""
      in_section = ""
      block_count = 0
    }

    # workers: 섹션 시작
    /^workers:/ { in_workers = 1; next }

    # workers 밖의 최상위 키 → workers 종료
    in_workers && /^[a-z]/ && !/^  / { in_workers = 0 }

    !in_workers { next }

    # 워커 이름 (2칸 들여쓰기 + 콜론)
    /^  [a-z][a-z0-9_-]+:$/ {
      # 이전 워커의 블록 배열 마무리
      if (current_worker != "" && block_count > 0) {
        if (in_section == "work_dirs") workers[current_worker,"work_dirs"] = flush_block_array()
        else if (in_section == "keywords") workers[current_worker,"keywords"] = flush_block_array()
        else if (in_section == "priority_keywords") workers[current_worker,"priority_keywords"] = flush_block_array()
        else if (in_section == "default_support") workers[current_worker,"default_support"] = flush_block_array()
        else if (in_section == "key_questions") workers[current_worker,"key_questions"] = flush_block_pipe()
        else if (in_section == "deliverables") workers[current_worker,"deliverables"] = flush_block_array()
        else if (in_section == "tasks") workers[current_worker,"tasks"] = flush_block_array()
      }
      gsub(/^  /, "")
      gsub(/:$/, "")
      current_worker = $0
      in_section = ""
      block_count = 0
      next
    }

    current_worker == "" { next }

    # 블록 배열 항목 (6칸 또는 8칸 들여쓰기 + "- ")
    /^      - / || /^        - / {
      val = $0
      gsub(/^[ ]*- /, "", val)
      gsub(/^ +| +$/, "", val)
      block_count++
      block_items[block_count] = val
      next
    }

    # 새 필드 시작 → 이전 블록 배열 마무리
    /^    [a-z]/ {
      if (block_count > 0) {
        if (in_section == "work_dirs") workers[current_worker,"work_dirs"] = flush_block_array()
        else if (in_section == "keywords") workers[current_worker,"keywords"] = flush_block_array()
        else if (in_section == "priority_keywords") workers[current_worker,"priority_keywords"] = flush_block_array()
        else if (in_section == "default_support") workers[current_worker,"default_support"] = flush_block_array()
        else if (in_section == "key_questions") workers[current_worker,"key_questions"] = flush_block_pipe()
        else if (in_section == "deliverables") workers[current_worker,"deliverables"] = flush_block_array()
        else if (in_section == "tasks") workers[current_worker,"tasks"] = flush_block_array()
        block_count = 0
      }
    }

    # 인라인 키: 값 (4칸 들여쓰기)
    /^    aliases:/ {
      in_section = "aliases"
      if ($0 ~ /\[/) {
        workers[current_worker,"aliases"] = parse_array($0)
      }
      next
    }
    /^    profile:/ {
      val = $0; gsub(/^    profile: */, "", val)
      workers[current_worker,"profile"] = val
      in_section = "profile"
      next
    }
    /^    starter:/ {
      val = $0; gsub(/^    starter: */, "", val)
      workers[current_worker,"starter"] = val
      in_section = "starter"
      next
    }
    /^    display_name:/ {
      val = $0; gsub(/^    display_name: */, "", val)
      workers[current_worker,"display_name"] = val
      in_section = "display_name"
      next
    }
    /^    work_dirs:/ {
      in_section = "work_dirs"
      if ($0 ~ /\[/) {
        workers[current_worker,"work_dirs"] = parse_array($0)
        gsub(/,/, " ", workers[current_worker,"work_dirs"])
      }
      next
    }

    # routing 하위 필드 (6칸 들여쓰기)
    /^    routing:/ { in_section = "routing"; next }
    /^      keywords:/ {
      in_section = "keywords"
      if ($0 ~ /\[/) {
        workers[current_worker,"keywords"] = parse_array($0)
        gsub(/,/, " ", workers[current_worker,"keywords"])
      }
      next
    }
    /^      priority_keywords:/ {
      in_section = "priority_keywords"
      if ($0 ~ /\[/) {
        workers[current_worker,"priority_keywords"] = parse_array($0)
        gsub(/,/, " ", workers[current_worker,"priority_keywords"])
      }
      next
    }
    /^      default_support:/ {
      in_section = "default_support"
      if ($0 ~ /\[/) {
        workers[current_worker,"default_support"] = parse_array($0)
      }
      next
    }

    # brief 하위 필드
    /^    brief:/ { in_section = "brief"; next }
    /^      mission:/ {
      val = $0; gsub(/^      mission: */, "", val)
      workers[current_worker,"mission"] = val
      in_section = "mission"
      next
    }
    /^      tasks:/ {
      in_section = "tasks"
      if ($0 ~ /\[/) {
        workers[current_worker,"tasks"] = parse_array($0)
      }
      next
    }
    /^      deliverables:/ {
      in_section = "deliverables"
      if ($0 ~ /\[/) {
        workers[current_worker,"deliverables"] = parse_array($0)
      }
      next
    }
    /^      key_questions:/ {
      in_section = "key_questions"
      next
    }

    END {
      # 마지막 워커의 블록 배열 마무리
      if (current_worker != "" && block_count > 0) {
        if (in_section == "work_dirs") workers[current_worker,"work_dirs"] = flush_block_array()
        else if (in_section == "keywords") workers[current_worker,"keywords"] = flush_block_array()
        else if (in_section == "key_questions") workers[current_worker,"key_questions"] = flush_block_pipe()
      }

      # 워커 목록 수집
      n = 0
      for (key in workers) {
        split(key, parts, SUBSEP)
        w = parts[1]
        found = 0
        for (i = 1; i <= n; i++) {
          if (worker_list[i] == w) { found = 1; break }
        }
        if (!found) { n++; worker_list[n] = w }
      }

      # worker-definitions.tsv 출력
      for (i = 1; i <= n; i++) {
        w = worker_list[i]
        aliases = w "," workers[w,"aliases"]
        profile = workers[w,"profile"]
        starter = workers[w,"starter"]
        work_dirs = workers[w,"work_dirs"]
        printf "%s\t%s\t%s\t%s\t%s\n", aliases, w, profile, starter, work_dirs
      }

      # 구분자
      print "---ROUTING---"

      # worker-routing-keywords.tsv 출력
      for (i = 1; i <= n; i++) {
        w = worker_list[i]
        kw = workers[w,"keywords"]
        gsub(/,/, " ", kw)
        pkw = workers[w,"priority_keywords"]
        gsub(/,/, " ", pkw)
        ds = workers[w,"default_support"]
        printf "%s\t%s\t%s\t%s\n", w, kw, pkw, ds
      }

      # 구분자
      print "---BRIEFS---"

      # worker-role-briefs.tsv 출력 (6필드: name, display_name, internal_agents, mission, outputs, questions)
      for (i = 1; i <= n; i++) {
        w = worker_list[i]
        display_name = workers[w,"display_name"]
        internal_agents = workers[w,"default_support"]
        if (internal_agents == "") internal_agents = "-"
        mission = workers[w,"mission"]
        outputs = workers[w,"deliverables"]
        if (outputs == "") outputs = "-"
        questions = workers[w,"key_questions"]
        # key_questions는 flush_block_pipe()로 수집 시 이미 | 구분됨
        if (questions == "") questions = "-"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", w, display_name, internal_agents, mission, outputs, questions
      }
    }
  ' "${YAML_FILE}"
}

# ── R21: worker-role-mcp.tsv 사이드카 생성기 ──
# 스키마: worker_id\tsection\ttool\tpayload
# sections: meta / preferred / prefetch / deferred
# deferred payload: "reason||fallback"
# rationale 검증: "이 도구 없이는 .*(위험|오염|추측|품질)" 패턴 미통과 시 exit 1
generate_mcp_sidecar() {
  awk '
    BEGIN {
      in_workers = 0
      current_worker = ""
      in_mcp = 0
      in_preferred = 0
      in_prefetch = 0
      in_deferred = 0
      current_id = ""
      current_rationale = ""
      current_tool = ""
      current_query = ""
      current_why = ""
      current_reason = ""
      current_fallback = ""
      current_min_call = ""
      item_type = ""
    }

    # workers: 섹션 시작
    /^workers:/ { in_workers = 1; next }

    # workers 밖 최상위 키 → 종료
    in_workers && /^[a-z]/ && !/^  / { in_workers = 0 }
    !in_workers { next }

    # 워커 이름 (2칸 들여쓰기)
    /^  [a-z][a-z0-9_-]+:$/ {
      flush_item()
      current_worker = $0
      gsub(/^  /, "", current_worker)
      gsub(/:$/, "", current_worker)
      in_mcp = 0; in_preferred = 0; in_prefetch = 0; in_deferred = 0
      current_min_call = ""
      next
    }

    current_worker == "" { next }

    # mcp: 섹션 (6칸)
    /^      mcp:/ { in_mcp = 1; in_preferred = 0; in_prefetch = 0; in_deferred = 0; next }

    !in_mcp { next }

    # minimum_call (8칸)
    /^        minimum_call:/ {
      val = $0; gsub(/^        minimum_call: */, "", val)
      gsub(/^ +| +$/, "", val)
      current_min_call = val
      printf "%s\tmeta\t-\tminimum_call=%s\n", current_worker, val
      next
    }

    # preferred_tools: (8칸)
    /^        preferred_tools:/ { in_preferred = 1; in_prefetch = 0; in_deferred = 0; next }
    /^        prefetch_queries:/ {
      flush_item()
      in_preferred = 0; in_prefetch = 1; in_deferred = 0
      next
    }
    /^        deferred:/ {
      flush_item()
      in_preferred = 0; in_prefetch = 0; in_deferred = 1
      next
    }

    # preferred item: - id: (10칸)
    in_preferred && /^          - id:/ {
      flush_item()
      item_type = "preferred"
      val = $0; gsub(/^          - id: */, "", val); gsub(/^ +| +$/, "", val)
      current_id = val
      next
    }
    in_preferred && /^            rationale:/ {
      val = $0; gsub(/^            rationale: *"/, "", val); gsub(/"$/, "", val)
      gsub(/^ +| +$/, "", val)
      current_rationale = val
      next
    }

    # prefetch item: - tool: (10칸)
    in_prefetch && /^          - tool:/ {
      flush_item()
      item_type = "prefetch"
      val = $0; gsub(/^          - tool: */, "", val); gsub(/^ +| +$/, "", val)
      current_tool = val
      next
    }
    in_prefetch && /^            query:/ {
      val = $0; gsub(/^            query: *"/, "", val); gsub(/"$/, "", val)
      gsub(/^ +| +$/, "", val)
      current_query = val
      next
    }
    in_prefetch && /^            why:/ {
      val = $0; gsub(/^            why: *"/, "", val); gsub(/"$/, "", val)
      gsub(/^ +| +$/, "", val)
      current_why = val
      next
    }

    # deferred item: - tool: (10칸)
    in_deferred && /^          - tool:/ {
      flush_item()
      item_type = "deferred"
      val = $0; gsub(/^          - tool: */, "", val); gsub(/^ +| +$/, "", val)
      current_tool = val
      next
    }
    in_deferred && /^            reason:/ {
      val = $0; gsub(/^            reason: *"/, "", val); gsub(/"$/, "", val)
      gsub(/^ +| +$/, "", val)
      current_reason = val
      next
    }
    in_deferred && /^            fallback:/ {
      val = $0; gsub(/^            fallback: *"/, "", val); gsub(/"$/, "", val)
      gsub(/^ +| +$/, "", val)
      current_fallback = val
      next
    }

    function flush_item(    payload) {
      if (item_type == "preferred" && current_id != "") {
        payload = current_rationale
        printf "%s\tpreferred\t%s\t%s\n", current_worker, current_id, payload
        current_id = ""; current_rationale = ""
      } else if (item_type == "prefetch" && current_tool != "") {
        payload = current_query "\t" current_why
        printf "%s\tprefetch\t%s\t%s\t%s\n", current_worker, current_tool, current_query, current_why
        current_tool = ""; current_query = ""; current_why = ""
      } else if (item_type == "deferred" && current_tool != "") {
        payload = current_reason "||" current_fallback
        printf "%s\tdeferred\t%s\t%s\n", current_worker, current_tool, payload
        current_tool = ""; current_reason = ""; current_fallback = ""
      }
      item_type = ""
    }

    END { flush_item() }
  ' "${YAML_FILE}"
}

# ── R21: rationale 검증 ──
# "이 도구 없이는 .*(위험|오염|추측|품질)" 패턴 미통과 시 exit 1
validate_mcp_rationales() {
  local violation_count=0
  while IFS=$'\t' read -r worker section tool payload; do
    [[ "${section}" == "preferred" ]] || continue
    if ! echo "${payload}" | grep -qE '이 도구 없이는 .*(위험|오염|추측|품질)'; then
      echo "ERROR: rationale 검증 실패 — worker=${worker} tool=${tool}" >&2
      echo "       payload: ${payload}" >&2
      violation_count=$((violation_count + 1))
    fi
  done < "${SIDECAR_FILE}"
  if [[ ${violation_count} -gt 0 ]]; then
    echo "ERROR: ${violation_count}개 rationale이 템플릿 패턴을 통과하지 못했습니다." >&2
    exit 1
  fi
}

echo "Generating TSV files from ${YAML_FILE}..."

# 파싱 실행
OUTPUT="$(parse_workers)"

# 분할 저장
DEFINITIONS="$(echo "${OUTPUT}" | sed -n '1,/^---ROUTING---$/p' | grep -v '^---')"
ROUTING="$(echo "${OUTPUT}" | sed -n '/^---ROUTING---$/,/^---BRIEFS---$/p' | grep -v '^---')"
BRIEFS="$(echo "${OUTPUT}" | sed -n '/^---BRIEFS---$/,$p' | grep -v '^---')"

echo "${DEFINITIONS}" > "${CONFIG_DIR}/worker-definitions.tsv"
echo "${ROUTING}" > "${CONFIG_DIR}/worker-routing-keywords.tsv"
echo "${BRIEFS}" > "${CONFIG_DIR}/worker-role-briefs.tsv"

# R21: MCP sidecar 생성
SIDECAR_FILE="${CONFIG_DIR}/worker-role-mcp.tsv"
generate_mcp_sidecar > "${SIDECAR_FILE}"
validate_mcp_rationales

echo ""
echo "Generated:"
echo "  ${CONFIG_DIR}/worker-definitions.tsv ($(wc -l < "${CONFIG_DIR}/worker-definitions.tsv") lines)"
echo "  ${CONFIG_DIR}/worker-routing-keywords.tsv ($(wc -l < "${CONFIG_DIR}/worker-routing-keywords.tsv") lines)"
echo "  ${CONFIG_DIR}/worker-role-briefs.tsv ($(wc -l < "${CONFIG_DIR}/worker-role-briefs.tsv") lines)"
echo "  ${CONFIG_DIR}/worker-role-mcp.tsv ($(wc -l < "${CONFIG_DIR}/worker-role-mcp.tsv") lines) [R21]"
echo ""
echo "TSV files are now generated artifacts. Edit company.yaml, then re-run this script."
echo "worker-role-briefs.tsv fields: name, display_name, internal_agents, mission, outputs, questions (6 fields)"
echo "worker-role-mcp.tsv fields: worker_id, section, tool, payload [R21]"

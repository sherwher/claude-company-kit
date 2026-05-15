#!/usr/bin/env bash
# validate-evidence.sh — v0.3-alpha evidence validator (B4 hard gate + R9 cleanup)
#
# 왜: must_call_mcp(도구 카운트) 게이트의 한계를 극복하기 위해 evidence_kind 게이트를
#     도입하는 v0.3 마이그레이션의 최종 단계(B4). B3에서 mode가 primary로 승격되어
#     workers/<name>/expected-evidence.json (prepare-worker.sh가 떨굼) 까지 비교했고,
#     B4에서 `EVIDENCE_STRICT=1` 환경 변수가 설정되면 expected-gate 위반이 있을 때
#     exit 1로 approve를 차단한다. company-approve.sh가 config/company.yaml의
#     `validator.exit_on_failure: true` 를 감지해 STRICT 플래그를 전달한다.
#     R9에서 R5 유산 source-key heuristic(빈 `source:` 키만 카운트) 경로를 완전 제거했다.
#     해당 휴리스틱은 nested `source:` 객체를 잡지 못해 의미가 왜곡되어 있었고,
#     evidence 구조 검사는 별도 v2 schema deliverable 범위로 분리. SUMMARY 라인의
#     카운터는 `soft_warnings`(알 수 없는 kind, manifest kind 없음 같은 품질 신호) +
#     `hard_fails`(expected 게이트 위반, JSON 파싱 실패 — STRICT 모드 차단 사유)로
#     의미 축을 분리했다 — 회고 시 "품질" vs "게이트 준수"를 구분해서 읽을 수 있다.
#     R10 Phase 2에서 `duplicate evidence_id` 검출을 soft WARN 경로로 추가했다.
#     복붙 실수로 워커가 같은 evidence_id를 재사용하면 manifest 데이터 무결성이
#     깨지지만 distinct kind 카운트는 영향 없을 수 있어 게이트 조건과 직교한다.
#     CCG 교차 자문(Codex+Gemini)에서 hard_fail 로 승격하지 말고 soft_warn 으로
#     집계하는 것이 의미 축 보존에 맞다고 합의했다.
#
# 입력: $1 = SESSION_DIR (예: .company-runtime/sessions/<id>)
# 동작: ${SESSION_DIR}/workers/<worker>/ 순회.
#       (a) evidence-manifest.yaml: kind enum 유효성, distinct count 산출
#       (b) expected-evidence.json (B3~): manifest distinct kinds vs minimum_distinct_kinds
#                                          + required_kinds 충족 여부 비교 (hard gate 대상)
#       파일 부재 시 INFO 1줄.
# exit:
#   - EVIDENCE_STRICT 미설정 또는 0 → 항상 0 (warn-only, 기존 B1~B3 동작 호환)
#   - EVIDENCE_STRICT=1 + hard_fail_count > 0 → exit 1 (expected-gate 위반으로 approve 차단)
#   - EVIDENCE_STRICT=1 + hard_fail_count = 0 → exit 0
#   hard_fail_count는 expected-evidence.json 게이트 위반 및 JSON 파싱 실패만 계산한다.
#   soft WARN (알 수 없는 kind, manifest kind 없음)은 strict 모드에서도 approve를
#   차단하지 않고 stderr 개별 라인으로만 출력된다.
#
# 부착 위치: scripts/company-approve.sh (force gate 통과 직후, marker 생성 직전).

set -uo pipefail

LOG_TAG="evidence"

SESSION_DIR="${1:-}"
if [[ -z "${SESSION_DIR}" || ! -d "${SESSION_DIR}" ]]; then
  echo "[${LOG_TAG}] INFO: session dir 없음 (skip)" >&2
  exit 0
fi

WORKERS_DIR="${SESSION_DIR}/workers"
if [[ ! -d "${WORKERS_DIR}" ]]; then
  echo "[${LOG_TAG}] INFO: workers/ 없음 (skip)" >&2
  exit 0
fi

# v0.3-alpha SSOT — config/company.yaml의 evidence.kinds[].id 와 1:1 동기화 필요
KNOWN_KINDS="code_symbol_or_reference repo_text_or_diff external_spec_or_policy api_contract_or_schema runtime_log_or_trace static_vuln_scan product_metric_lookup experiment_or_feedback_artifact dependency_or_sbom architecture_or_decision_record"

is_known_kind() {
  local k="$1"
  case " ${KNOWN_KINDS} " in
    *" ${k} "*) return 0 ;;
    *) return 1 ;;
  esac
}

worker_count=0
manifest_count=0
soft_warn_count=0   # R9: 품질 WARN (알 수 없는 kind / manifest kind 없음) — STRICT 차단 대상 아님
hard_fail_count=0   # B4: expected-evidence.json 게이트 위반만 집계 (strict exit 결정용)

while IFS= read -r worker_dir; do
  [[ -d "${worker_dir}" ]] || continue
  worker_name="$(basename "${worker_dir}")"
  worker_count=$((worker_count + 1))
  manifest="${worker_dir}/evidence-manifest.yaml"

  if [[ ! -f "${manifest}" ]]; then
    echo "[${LOG_TAG}] INFO: ${worker_name} — evidence-manifest.yaml 없음" >&2
    continue
  fi
  manifest_count=$((manifest_count + 1))

  # kind 라인 추출 (단순 텍스트 휴리스틱, yq 의존 회피)
  kinds_raw="$(grep -E '^[[:space:]]*kind:[[:space:]]*' "${manifest}" 2>/dev/null | sed -E 's/^[[:space:]]*kind:[[:space:]]*//; s/[[:space:]]+$//' || true)"
  if [[ -z "${kinds_raw}" ]]; then
    echo "[${LOG_TAG}] WARN: ${worker_name} — manifest에 kind: 항목 없음" >&2
    soft_warn_count=$((soft_warn_count + 1))
    continue
  fi

  distinct_count=$(printf '%s\n' "${kinds_raw}" | sort -u | wc -l | tr -d ' ')

  unknown_kinds=""
  while IFS= read -r k; do
    [[ -z "${k}" ]] && continue
    if ! is_known_kind "${k}"; then
      unknown_kinds="${unknown_kinds} ${k}"
    fi
  done <<< "${kinds_raw}"

  if [[ -n "${unknown_kinds}" ]]; then
    echo "[${LOG_TAG}] WARN: ${worker_name} — 알 수 없는 kind:${unknown_kinds}" >&2
    soft_warn_count=$((soft_warn_count + 1))
  fi

  # evidence entry 카운트 (OK 라인 요약 표시용, 게이트 판정에는 사용 안 함)
  # grep -c는 0건일 때 exit 1 → `|| true` + `:-0` fallback으로 정규화.
  ev_count=$(grep -cE '^[[:space:]]*-[[:space:]]*evidence_id:[[:space:]]*' "${manifest}" 2>/dev/null || true)
  ev_count="${ev_count:-0}"

  # R10 Phase 2: duplicate evidence_id 검출 (soft WARN, distinct kind 게이트와 직교)
  # 워커가 복붙 과정에서 같은 evidence_id 를 재사용해도 distinct_count 는 kind 기준으로
  # 산출되므로 expected 게이트는 속을 수 있다. 데이터 무결성 관점에서 dup은 항상 신호.
  dup_ids="$(grep -E '^[[:space:]]*-[[:space:]]*evidence_id:[[:space:]]*' "${manifest}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*-[[:space:]]*evidence_id:[[:space:]]*//; s/[[:space:]]+$//' \
    | sort | uniq -d | tr '\n' ',' | sed 's/,$//' || true)"
  if [[ -n "${dup_ids}" ]]; then
    echo "[${LOG_TAG}] WARN: ${worker_name} — 중복 evidence_id: ${dup_ids}" >&2
    soft_warn_count=$((soft_warn_count + 1))
  fi

  # ── expected-evidence.json 비교 (B3 primary gate, B4에서 strict 모드 시 hard gate) ──
  expected="${worker_dir}/expected-evidence.json"
  if [[ -f "${expected}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      manifest_kinds_csv="$(printf '%s\n' "${kinds_raw}" | sort -u | tr '\n' ',' | sed 's/,$//')"
      cmp_out="$(MANIFEST_KINDS="${manifest_kinds_csv}" DISTINCT="${distinct_count}" \
        python3 - "${expected}" <<'PYEOF' 2>/dev/null || true
import json, os, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        exp = json.load(f)
except Exception as exc:
    print(f"PARSE_ERROR:{exc}")
    sys.exit(0)
mdk = int(exp.get("minimum_distinct_kinds", 0))
required = set(exp.get("required_kinds") or [])
deferred = set(exp.get("deferred_kinds") or [])
present = set(k for k in os.environ.get("MANIFEST_KINDS", "").split(",") if k)
distinct = int(os.environ.get("DISTINCT", "0") or 0)
warns = []
if distinct < mdk:
    warns.append(f"distinct {distinct} < minimum {mdk}")
missing_required = sorted((required - present) - deferred)
if missing_required:
    warns.append("required missing: " + ",".join(missing_required))
if warns:
    print("WARN:" + " | ".join(warns))
else:
    print(f"OK:expected mdk={mdk} required={len(required)} (deferred={len(deferred)})")
PYEOF
)"
      case "${cmp_out}" in
        WARN:*)
          echo "[${LOG_TAG}] WARN: ${worker_name} — expected 게이트: ${cmp_out#WARN:}" >&2
          hard_fail_count=$((hard_fail_count + 1))
          ;;
        OK:*)
          echo "[${LOG_TAG}] EXPECTED-OK: ${worker_name} — ${cmp_out#OK:}" >&2
          ;;
        PARSE_ERROR:*)
          echo "[${LOG_TAG}] WARN: ${worker_name} — expected-evidence.json 파싱 실패 (${cmp_out#PARSE_ERROR:})" >&2
          hard_fail_count=$((hard_fail_count + 1))
          ;;
        *)
          echo "[${LOG_TAG}] INFO: ${worker_name} — expected 비교 skip (python3 출력 비어있음)" >&2
          ;;
      esac
    else
      echo "[${LOG_TAG}] INFO: ${worker_name} — python3 없음 → expected 비교 skip" >&2
    fi
  fi

  echo "[${LOG_TAG}] OK: ${worker_name} — distinct kinds=${distinct_count}, evidence=${ev_count}" >&2
done < <(find "${WORKERS_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

if [[ "${EVIDENCE_STRICT:-0}" == "1" && "${hard_fail_count}" -gt 0 ]]; then
  echo "[${LOG_TAG}] SUMMARY: workers=${worker_count}, manifests=${manifest_count}, soft_warnings=${soft_warn_count}, hard_fails=${hard_fail_count} (STRICT 모드, approve 차단)" >&2
  exit 1
fi

echo "[${LOG_TAG}] SUMMARY: workers=${worker_count}, manifests=${manifest_count}, soft_warnings=${soft_warn_count}, hard_fails=${hard_fail_count} (strict=${EVIDENCE_STRICT:-0}, approve 통과)" >&2
exit 0

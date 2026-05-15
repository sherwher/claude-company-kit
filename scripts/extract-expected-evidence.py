#!/usr/bin/env python3
"""extract-expected-evidence.py — v0.3-alpha B3 helper

왜: prepare-worker.sh가 워커별 진입점에 expected-evidence.json을 떨궈둬야
    validator(shadow→primary)가 yq 의존 없이 must_provide_evidence를 비교할
    수 있다. config/company.yaml은 2단계 중첩 + 인라인 배열 고정 포맷이므로
    PyYAML 없이 stdlib만으로 파싱한다 (target 프로젝트 prereq 추가 회피).

입력:
  argv[1] = config/company.yaml 경로
  argv[2] = worker name (예: backend-engineer)

출력:
  stdout = JSON 객체
  {
    "worker": "<name>",
    "minimum_distinct_kinds": <int>,
    "required_kinds": [...],
    "optional_kinds": [...],
    "deferred_kinds": [...]
  }

워커 매핑이 없으면 evidence.default_must_provide로 fallback.
워커 자체가 yaml에 없으면 exit 2.
"""

import json
import re
import sys
from pathlib import Path


INLINE_LIST_RE = re.compile(r"\[(.*)\]\s*$")


def parse_inline_list(value: str) -> list[str]:
    """[a, b, c] → [a, b, c]; 빈 리스트는 []."""
    m = INLINE_LIST_RE.search(value)
    if not m:
        return []
    inner = m.group(1).strip()
    if not inner:
        return []
    return [item.strip() for item in inner.split(",") if item.strip()]


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def strip_comment(line: str) -> str:
    """Strip trailing # comments while preserving inline `[a, b]` brackets.

    company.yaml은 키 값에 `#`가 들어가지 않는 단순 포맷이라 1차 컷으로 충분.
    """
    # 따옴표 안 # 보호는 현재 포맷에 없음 — 단순 분리.
    if "#" in line:
        # 인라인 배열 안 # 처리는 우리 포맷에 없음. 첫 # 기준 컷.
        head, _, _tail = line.partition("#")
        return head.rstrip()
    return line.rstrip()


def parse_must_provide(yaml_path: Path, worker_name: str) -> dict | None:
    """선형 라인 스캐너 — workers.<worker>.brief.must_provide_evidence 추출.

    반환: dict 또는 None (워커는 있지만 must_provide_evidence 미정)
    워커 자체가 없으면 KeyError.
    """
    lines = yaml_path.read_text(encoding="utf-8").splitlines()

    in_workers = False
    in_target_worker = False
    in_brief = False
    in_must = False
    must: dict = {}
    found_worker = False
    current_list_key: str | None = None

    for raw in lines:
        stripped = strip_comment(raw)
        if not stripped.strip():
            current_list_key = None
            continue

        if stripped.startswith("workers:"):
            in_workers = True
            continue

        if not in_workers:
            continue

        # Top-level key after workers: → workers section ends.
        if re.match(r"^[A-Za-z]", stripped):
            break

        ind = indent_of(stripped)

        # 2-space indent → worker name (예: "  backend-engineer:")
        if ind == 2 and stripped.endswith(":"):
            name = stripped.strip().rstrip(":")
            in_target_worker = (name == worker_name)
            if in_target_worker:
                found_worker = True
            in_brief = False
            in_must = False
            current_list_key = None
            continue

        if not in_target_worker:
            continue

        # 4-space indent → worker field (brief: 등)
        if ind == 4 and stripped.strip().startswith("brief:"):
            in_brief = True
            in_must = False
            current_list_key = None
            continue

        if ind == 4 and not stripped.strip().startswith("brief:"):
            # 다른 워커 필드 (display_name, aliases, profile ...)
            in_brief = False
            in_must = False
            current_list_key = None
            continue

        if not in_brief:
            continue

        # 6-space indent → brief field
        if ind == 6:
            key_match = re.match(r"^\s*([a-z_]+):\s*(.*)$", stripped)
            if not key_match:
                continue
            key = key_match.group(1)
            in_must = (key == "must_provide_evidence")
            current_list_key = None
            continue

        # 8-space indent → must_provide_evidence field
        if in_must and ind == 8:
            kv = re.match(r"^\s*([a-z_]+):\s*(.*)$", stripped)
            if not kv:
                continue
            key, value = kv.group(1), kv.group(2).strip()
            if key == "minimum_distinct_kinds":
                try:
                    must["minimum_distinct_kinds"] = int(value)
                except ValueError:
                    must["minimum_distinct_kinds"] = 0
                current_list_key = None
            elif key in ("required_kinds", "optional_kinds", "deferred_kinds"):
                if value.startswith("["):
                    must[key] = parse_inline_list(value)
                    current_list_key = None
                else:
                    # block list 형태 — 다음 라인부터 "  - item" 수집
                    must[key] = []
                    current_list_key = key
            continue

        # 10-space indent → block list item under current_list_key
        if in_must and ind == 10 and current_list_key is not None:
            item = stripped.strip()
            if item.startswith("- "):
                must[current_list_key].append(item[2:].strip())
            continue

    if not found_worker:
        raise KeyError(f"worker '{worker_name}' not found in {yaml_path}")

    if not must:
        return None
    return must


def parse_default(yaml_path: Path) -> dict:
    """evidence.default_must_provide 추출."""
    lines = yaml_path.read_text(encoding="utf-8").splitlines()
    in_evidence = False
    in_default = False
    default: dict = {
        "minimum_distinct_kinds": 0,
        "required_kinds": [],
        "optional_kinds": [],
        "deferred_kinds": [],
    }
    current_list_key: str | None = None

    for raw in lines:
        stripped = strip_comment(raw)
        if not stripped.strip():
            current_list_key = None
            continue

        if stripped.startswith("evidence:"):
            in_evidence = True
            continue

        if in_evidence and re.match(r"^[A-Za-z]", stripped) and not stripped.startswith("evidence:"):
            break

        if not in_evidence:
            continue

        ind = indent_of(stripped)
        if ind == 2 and stripped.strip().startswith("default_must_provide:"):
            in_default = True
            current_list_key = None
            continue
        if ind == 2 and not stripped.strip().startswith("default_must_provide:"):
            in_default = False
            current_list_key = None
            continue

        if in_default and ind == 4:
            kv = re.match(r"^\s*([a-z_]+):\s*(.*)$", stripped)
            if not kv:
                continue
            key, value = kv.group(1), kv.group(2).strip()
            if key == "minimum_distinct_kinds":
                try:
                    default["minimum_distinct_kinds"] = int(value)
                except ValueError:
                    pass
                current_list_key = None
            elif key in ("required_kinds", "optional_kinds", "deferred_kinds"):
                if value.startswith("["):
                    default[key] = parse_inline_list(value)
                    current_list_key = None
                else:
                    default[key] = []
                    current_list_key = key
            continue

        if in_default and ind == 6 and current_list_key is not None:
            item = stripped.strip()
            if item.startswith("- "):
                default[current_list_key].append(item[2:].strip())
            continue

    return default


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: extract-expected-evidence.py <company.yaml> <worker-name>", file=sys.stderr)
        return 1

    yaml_path = Path(sys.argv[1])
    worker_name = sys.argv[2]

    if not yaml_path.is_file():
        print(f"Error: {yaml_path} not found", file=sys.stderr)
        return 1

    try:
        must = parse_must_provide(yaml_path, worker_name)
    except KeyError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    if must is None:
        must = parse_default(yaml_path)

    out = {
        "worker": worker_name,
        "minimum_distinct_kinds": must.get("minimum_distinct_kinds", 0),
        "required_kinds": must.get("required_kinds", []),
        "optional_kinds": must.get("optional_kinds", []),
        "deferred_kinds": must.get("deferred_kinds", []),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

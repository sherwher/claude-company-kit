#!/usr/bin/env python3
"""
validate-compact-frontmatter.py

R15 5-C 2차 — compact-{plan,result}.md 의 YAML frontmatter.meta 5필드를
schema 상 pattern/minLength 제약까지 검증한다. R13 5-C 1차 bash grep 은 존재
여부만 확인했고, 이번 2차는 실제 constraint 까지 확인한다.

왜 stdlib 만 쓰는가:
  jsonschema/PyYAML 의존성 추가를 피한다. compact-{plan,result}.md 의
  frontmatter 는 `meta:` 1-level 하위에 5개 스칼라 필드만 가지는 고정 형태라
  line-based 파싱으로 충분하다. 5-C 3차 (마크다운 body → JSON 변환) 진입 시
  PyYAML/jsonschema 재검토.

제약은 schema 와 수동 sync:
  templates/schemas/compact-{plan,result}.schema.json 의 frontmatter.meta
  subschema 와 아래 CONSTRAINTS 는 수동으로 일치시킨다. schema 쪽 변경 시
  이 상수도 갱신. 향후 schema parse 연결은 3차에서.

사용법:
  python3 scripts/validate-compact-frontmatter.py <md-file> [<md-file> ...]

출력:
  각 파일별로 OK / 위반 라인을 stdout/stderr 에 쓴다.
  위반 존재 시 exit code 2 — 단, 호출부 bash 에서 soft-warn 으로 downgrade 한다.
  파일 자체 미존재/파싱 실패는 exit code 1.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Iterator

# ── schema SSOT 와 수동 sync ──
# templates/schemas/compact-{plan,result}.schema.json 의 frontmatter.meta 에
# 기술된 제약을 반영. enum 이 아닌 pattern/minLength 만 사용하므로 간단.
CONSTRAINTS: dict[str, dict] = {
    "session_id": {"min_length": 3},
    "worker": {"pattern": r"^[a-z0-9][a-z0-9-]{1,63}$"},
    "role": {"min_length": 3},
    "plan_sha256": {"pattern": r"^[a-f0-9]{64}$"},
    # ISO 8601 date-time (schema "format": "date-time"). format 강제는 draft-07
    # 권장이라 여기서는 실용적 subset 정규식으로 처리 — `2026-04-08T15:09:00Z`,
    # `2026-04-08T15:09:00.123+09:00` 등 흔한 형태 수용.
    "created_at": {
        "pattern": r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"
    },
}

REQUIRED_META_FIELDS = tuple(CONSTRAINTS.keys())


def extract_frontmatter(lines: list[str]) -> list[str] | None:
    """YAML frontmatter (``---`` 펜스) 블록의 본문 라인을 반환. 없으면 None."""
    if not lines or lines[0].strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i]
    return None  # 닫는 펜스 없음


def parse_meta_block(fm_lines: list[str]) -> dict[str, str]:
    """frontmatter 안의 ``meta:`` 하위 5 필드를 평탄 dict 로 추출.

    중첩 YAML 을 일반화하지 않는다 — compact-{plan,result} 의 meta 구조가
    ``meta:\\n  <key>: <value>`` 로 고정이라는 가정. 더 복잡한 구조 등장 시
    5-C 3차에서 PyYAML 도입.
    """
    result: dict[str, str] = {}
    in_meta = False
    meta_indent: int | None = None
    for raw in fm_lines:
        if raw.rstrip() == "meta:":
            in_meta = True
            continue
        if in_meta:
            stripped = raw.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(raw) - len(stripped)
            if meta_indent is None:
                meta_indent = indent
            if indent < meta_indent:
                # meta 블록 종료 (다시 top-level)
                in_meta = False
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", stripped)
            if not m:
                continue
            key, value = m.group(1), m.group(2).strip()
            # YAML 간단 quoting 벗기기
            if (value.startswith("\"") and value.endswith("\"")) or (
                value.startswith("'") and value.endswith("'")
            ):
                value = value[1:-1]
            result[key] = value
    return result


def validate_meta(meta: dict[str, str]) -> Iterator[str]:
    """누락 + 제약 위반을 위반 사유 문자열로 yield."""
    for field in REQUIRED_META_FIELDS:
        if field not in meta:
            yield f"meta.{field}: 누락"
            continue
        value = meta[field]
        cons = CONSTRAINTS[field]
        if "min_length" in cons and len(value) < cons["min_length"]:
            yield f"meta.{field}: minLength {cons['min_length']} 위반 (got {len(value)})"
        if "pattern" in cons and not re.match(cons["pattern"], value):
            yield f"meta.{field}: pattern 위반 ({cons['pattern']!r} vs {value!r})"


def validate_file(path: Path) -> tuple[bool, list[str]]:
    """(valid, violations) 반환. valid=False 면 violations 에 사유 들어있음."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception as exc:
        return False, [f"파일 읽기 실패: {exc}"]
    fm = extract_frontmatter(lines)
    if fm is None:
        return False, ["frontmatter 펜스 (---) 누락 또는 미종료"]
    meta = parse_meta_block(fm)
    violations = list(validate_meta(meta))
    return (not violations), violations


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: validate-compact-frontmatter.py <md-file> [<md-file> ...]", file=sys.stderr)
        return 1
    had_violation = False
    had_ioerror = False
    for raw_path in argv[1:]:
        p = Path(raw_path)
        if not p.exists():
            print(f"[FAIL] {raw_path}: not found", file=sys.stderr)
            had_ioerror = True
            continue
        ok, violations = validate_file(p)
        if ok:
            print(f"[OK]   {raw_path}")
        else:
            had_violation = True
            for v in violations:
                print(f"[WARN] {raw_path}: {v}", file=sys.stderr)
    if had_ioerror:
        return 1
    return 2 if had_violation else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

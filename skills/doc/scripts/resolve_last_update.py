#!/usr/bin/env python3
"""Resolve /doc last_update provenance from scrum board annotations."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path
from typing import Any

COMPLETED_STATUSES = {"Done", "Passed"}
BOARD_DIRS = (
    ("epic", Path("project/board/epics")),
    ("story", Path("project/board/stories")),
    ("task", Path("project/board/tasks")),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve the latest completed board date for a documentation target.",
    )
    parser.add_argument("target_path", help="Repo-relative documentation target path, e.g. README.md")
    parser.add_argument(
        "--root",
        default=Path(__file__).resolve().parents[3],
        type=Path,
        help="Repository root containing project/board/",
    )
    return parser.parse_args()


def parse_scalar(value: str) -> Any:
    text = value.strip()
    if text in {"", "null", "~"}:
        return ""
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [item.strip().strip("\"'") for item in inner.split(",") if item.strip()]
    return text.strip("\"'")


def parse_frontmatter(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        raise ValueError("missing opening frontmatter delimiter")
    parts = text.split("\n---\n", 1)
    if len(parts) != 2:
        raise ValueError("missing closing frontmatter delimiter")

    lines = parts[0].splitlines()[1:]
    data: dict[str, Any] = {}
    current_key: str | None = None

    for line in lines:
        if not line.strip():
            continue
        if line.startswith("  - "):
            if current_key is None:
                raise ValueError(f"orphaned list item: {line.strip()}")
            existing = data.get(current_key, "")
            if existing == "":
                existing = []
                data[current_key] = existing
            if not isinstance(existing, list):
                raise ValueError(f"frontmatter key {current_key!r} is not a list")
            existing.append(line[4:].strip().strip("\"'"))
            continue
        if ":" not in line:
            raise ValueError(f"invalid frontmatter line: {line}")
        key, raw_value = line.split(":", 1)
        key = key.strip()
        value = parse_scalar(raw_value)
        data[key] = value
        current_key = key if value == "" else None

    return data


def iter_matches(root: Path, target_path: str):
    for item_type, relative_dir in BOARD_DIRS:
        board_dir = root / relative_dir
        if not board_dir.exists():
            continue
        for path in sorted(board_dir.glob("*.md")):
            try:
                frontmatter = parse_frontmatter(path)
            except Exception as exc:  # pragma: no cover - defensive degradation
                print(f"warning: skipping {path}: {exc}", file=sys.stderr)
                continue

            if frontmatter.get("status") not in COMPLETED_STATUSES:
                continue

            docs = frontmatter.get("docs")
            if not isinstance(docs, list) or target_path not in docs:
                continue

            completed_raw = str(frontmatter.get("date_completed", "")).strip()
            if not completed_raw:
                print(
                    f"warning: skipping {path}: matching docs annotation without date_completed",
                    file=sys.stderr,
                )
                continue

            try:
                completed_on = date.fromisoformat(completed_raw)
            except ValueError:
                print(
                    f"warning: skipping {path}: invalid date_completed {completed_raw!r}",
                    file=sys.stderr,
                )
                continue

            yield {
                "id": frontmatter.get("id") or path.stem,
                "type": item_type,
                "status": frontmatter.get("status"),
                "date_completed": completed_on.isoformat(),
                "path": path.relative_to(root).as_posix(),
            }


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    matches = sorted(
        iter_matches(root, args.target_path),
        key=lambda item: (item["date_completed"], item["id"]),
    )
    last_update = matches[-1]["date_completed"] if matches else "unknown"
    payload = {
        "target_path": args.target_path,
        "last_update": last_update,
        "provenance_found": bool(matches),
        "fallback": "unknown",
        "matched_items": matches,
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

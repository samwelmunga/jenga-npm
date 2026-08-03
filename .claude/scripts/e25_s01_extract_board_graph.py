#!/usr/bin/env python3
# THROWAWAY — spike prototype for E25_S01 latency measurement. Do not import.

import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path

PREFIXED_REF = r"(?:[A-Z0-9]+_)?"
EPIC_ID_RE = re.compile(rf"^{PREFIXED_REF}E\d{{2}}$")
STORY_ID_RE = re.compile(rf"^{PREFIXED_REF}E\d{{2}}_S\d{{2}}$")
TASK_ID_RE = re.compile(rf"^{PREFIXED_REF}E\d{{2}}_S\d{{2}}_T\d{{2}}$")
TARGET_REF_RE = re.compile(rf"^({PREFIXED_REF}E\d{{2}}_S\d{{2}}(?:_T\d{{2}})?)-(plan|summary)\.md$")
TODO_REF_RE = re.compile(rf"\b({PREFIXED_REF}E\d{{2}}_S\d{{2}}(?:_T\d{{2}})?)\b")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Throwaway board graph extractor for E25_S01.")
    parser.add_argument("root", nargs="?", default="project", help="Project-like root containing board/, documentation/, and todo.md")
    parser.add_argument("--profile", action="store_true", help="Include coarse timing breakdown in the output JSON")
    return parser.parse_args()


def parse_scalar(value: str):
    text = value.strip()
    if text in {"", "null", "~"}:
        return ""
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [item.strip().strip("'\"") for item in inner.split(",") if item.strip()]
    return text.strip("'\"")


def parse_frontmatter(path: Path) -> tuple[dict, str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return {}, text
    parts = text.split("\n---\n", 1)
    if len(parts) != 2:
        return {}, text
    raw, body = parts
    lines = raw.splitlines()[1:]
    data: dict[str, object] = {}
    current_key = None
    for line in lines:
        if not line.strip():
            continue
        if line.startswith("  - ") and current_key:
            data.setdefault(current_key, [])
            cast = data[current_key]
            if isinstance(cast, list):
                cast.append(line[4:].strip().strip("'\""))
            continue
        if ":" not in line:
            current_key = None
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        parsed = parse_scalar(value)
        data[key] = parsed
        current_key = key if parsed == "" else None
    return data, body


def relpath(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def node_sort_key(node: dict) -> tuple:
    return (node.get("type", ""), node.get("id", ""), node.get("path", ""), node.get("line_number", 0))


def edge_sort_key(edge: dict) -> tuple:
    return (edge.get("type", ""), edge.get("from", ""), edge.get("to", ""), edge.get("source", ""))


def rounded_timings(timings: dict[str, float]) -> dict[str, float]:
    return {key: round(value, 3) for key, value in timings.items()}


def add_board_nodes(
    root: Path,
    collection: str,
    node_type: str,
    nodes: list[dict],
    records: list[dict],
    timings: dict[str, float],
):
    base = root / "board" / collection
    walk_started = time.perf_counter()
    paths = sorted(base.glob("*.md"))
    timings["board_directory_walk_ms"] = timings.get("board_directory_walk_ms", 0.0) + ((time.perf_counter() - walk_started) * 1000)
    for path in paths:
        parse_started = time.perf_counter()
        frontmatter, _ = parse_frontmatter(path)
        timings["board_frontmatter_parse_ms"] = timings.get("board_frontmatter_parse_ms", 0.0) + ((time.perf_counter() - parse_started) * 1000)
        node = {
            "id": frontmatter.get("id") or path.stem.split("_", 1)[0],
            "type": node_type,
            "path": relpath(path, root),
            "title": frontmatter.get("title", ""),
            "status": frontmatter.get("status", ""),
        }
        if frontmatter.get("epic_id"):
            node["epic_id"] = frontmatter["epic_id"]
        if frontmatter.get("story_id"):
            node["story_id"] = frontmatter["story_id"]
        if isinstance(frontmatter.get("stories"), list):
            node["stories"] = list(frontmatter["stories"])
        if isinstance(frontmatter.get("tasks"), list):
            node["tasks"] = list(frontmatter["tasks"])
        nodes.append(node)
        records.append({"node": node, "frontmatter": frontmatter})


def add_doc_nodes(
    root: Path,
    folder: str,
    node_type: str,
    nodes: list[dict],
    records: list[dict],
    timings: dict[str, float],
):
    base = root / "documentation" / folder
    walk_started = time.perf_counter()
    paths = sorted(base.glob("*.md"))
    timings["doc_directory_walk_ms"] = timings.get("doc_directory_walk_ms", 0.0) + ((time.perf_counter() - walk_started) * 1000)
    for path in paths:
        parse_started = time.perf_counter()
        frontmatter, _ = parse_frontmatter(path)
        timings["doc_frontmatter_parse_ms"] = timings.get("doc_frontmatter_parse_ms", 0.0) + ((time.perf_counter() - parse_started) * 1000)
        stem = path.stem
        node = {
            "id": stem,
            "type": node_type,
            "path": relpath(path, root),
            "title": frontmatter.get("title") or frontmatter.get("id") or stem,
        }
        match = TARGET_REF_RE.match(path.name)
        if match:
            node["target_ref"] = match.group(1)
        nodes.append(node)
        records.append({"node": node, "frontmatter": frontmatter})


def add_todo_nodes(root: Path, nodes: list[dict], records: list[dict], timings: dict[str, float]):
    todo_path = root / "todo.md"
    started = time.perf_counter()
    for line_number, raw_line in enumerate(todo_path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("<!--"):
            continue
        if line.startswith("#"):
            continue
        if set(line) <= {"-"}:
            continue
        refs = TODO_REF_RE.findall(line)
        digest = hashlib.sha1(line.encode("utf-8")).hexdigest()[:12]
        node = {
            "id": f"todo:{line_number}:{digest}",
            "type": "TodoEntry",
            "path": relpath(todo_path, root),
            "line_number": line_number,
            "text": line,
        }
        if refs:
            node["board_refs"] = refs
        nodes.append(node)
        records.append({"node": node, "refs": refs})
    timings["todo_parse_ms"] = timings.get("todo_parse_ms", 0.0) + ((time.perf_counter() - started) * 1000)


def target_type(target_id: str) -> str:
    if TASK_ID_RE.match(target_id):
        return "Task"
    if STORY_ID_RE.match(target_id):
        return "Story"
    if EPIC_ID_RE.match(target_id):
        return "Epic"
    return "Unknown"


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    nodes: list[dict] = []
    edges: list[dict] = []

    started = time.perf_counter()
    timings: dict[str, float] = {}

    t0 = time.perf_counter()
    epic_records: list[dict] = []
    story_records: list[dict] = []
    task_records: list[dict] = []
    add_board_nodes(root, "epics", "Epic", nodes, epic_records, timings)
    add_board_nodes(root, "stories", "Story", nodes, story_records, timings)
    add_board_nodes(root, "tasks", "Task", nodes, task_records, timings)
    plan_records: list[dict] = []
    summary_records: list[dict] = []
    add_doc_nodes(root, "plans", "Plan", nodes, plan_records, timings)
    add_doc_nodes(root, "summaries", "Summary", nodes, summary_records, timings)
    todo_records: list[dict] = []
    add_todo_nodes(root, nodes, todo_records, timings)
    timings["node_extraction_ms"] = round((time.perf_counter() - t0) * 1000, 3)

    t0 = time.perf_counter()
    known_ids = {node["id"] for node in nodes}
    for record in epic_records:
        source = record["node"]
        for story_id in source.get("stories", []):
            edges.append({
                "type": "contains",
                "from": source["id"],
                "to": story_id,
                "from_type": "Epic",
                "to_type": target_type(story_id),
                "source": source["path"],
            })
    for record in story_records:
        source = record["node"]
        for task_id in source.get("tasks", []):
            edges.append({
                "type": "contains",
                "from": source["id"],
                "to": task_id,
                "from_type": "Story",
                "to_type": target_type(task_id),
                "source": source["path"],
            })
    for record in plan_records:
        source = record["node"]
        target = source.get("target_ref")
        if target:
            edges.append({
                "type": "plans",
                "from": source["id"],
                "to": target,
                "from_type": "Plan",
                "to_type": target_type(target),
                "source": source["path"],
            })
    for record in summary_records:
        source = record["node"]
        target = source.get("target_ref")
        if target:
            edges.append({
                "type": "summarizes",
                "from": source["id"],
                "to": target,
                "from_type": "Summary",
                "to_type": target_type(target),
                "source": source["path"],
            })
    for record in todo_records:
        source = record["node"]
        for ref in record.get("refs", []):
            if ref in known_ids:
                edges.append({
                    "type": "queued_as",
                    "from": source["id"],
                    "to": ref,
                    "from_type": "TodoEntry",
                    "to_type": target_type(ref),
                    "source": source["path"],
                })
    timings["edge_derivation_ms"] = round((time.perf_counter() - t0) * 1000, 3)

    t0 = time.perf_counter()
    nodes.sort(key=node_sort_key)
    edges.sort(key=edge_sort_key)
    payload = {"nodes": nodes, "edges": edges}
    if args.profile:
        payload["profile"] = rounded_timings(timings)
    rendered = json.dumps(payload, indent=2, sort_keys=True)
    timings["json_serialization_ms"] = round((time.perf_counter() - t0) * 1000, 3)
    if args.profile:
        timings["total_ms"] = round((time.perf_counter() - started) * 1000, 3)
        payload["profile"] = rounded_timings(timings)
        rendered = json.dumps(payload, indent=2, sort_keys=True)
    sys.stdout.write(rendered)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

NODE_TYPES = {
    "Epic",
    "Story",
    "Task",
    "Plan",
    "Summary",
    "Doc",
    "TodoEntry",
    "Skill",
    "Agent",
}
EDGE_TYPES = {
    "contains",
    "plans",
    "summarizes",
    "queued_as",
    "mentions_skill",
    "mentions_agent",
    "depends_on",
    "blocks",
    "parent_doc",
}
FRONTMATTER_BOUNDARY = "---"
ROOT_DIR = Path(__file__).resolve().parents[3]
BOARD_ID_RE = re.compile(r"^E\d{2}(?:_S\d{2})?(?:_T\d{2})?$")
PLAN_RE = re.compile(r"^(E\d{2}_S\d{2}(?:_T\d{2})?)-plan$")
SUMMARY_RE = re.compile(r"^(E\d{2}_S\d{2}(?:_T\d{2})?)-summary$")
TODO_REF_AT_END_RE = re.compile(r"(E\d{2}_S\d{2}(?:_T\d{2})?)\s*$")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="board-index",
        description="Walk project artifacts and emit board-index graph JSON.",
    )
    subparsers = parser.add_subparsers(dest="command")

    for command_name, help_text in (
        ("graph::nodes", "Emit graph nodes as a JSON array."),
        ("graph::edges", "Emit graph edges as a JSON array."),
    ):
        command_parser = subparsers.add_parser(command_name, help=help_text)
        command_parser.add_argument("--type", dest="type_filter", help="Optional type filter.")
        command_parser.add_argument(
            "--format",
            default="json",
            choices=["json"],
            help="Output format. Only JSON is supported in S02.",
        )

    return parser


def emit_json(payload: list[dict[str, Any]]) -> int:
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def warn(message: str) -> None:
    print(f"board-index: warning: {message}", file=sys.stderr)


def relative_path(path: Path) -> str:
    return path.relative_to(ROOT_DIR).as_posix()


def parse_scalar(value: str) -> Any:
    text = value.strip()
    if not text or text in {"null", "~"}:
        return None
    if text in {"true", "false"}:
        return text == "true"
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        parts = [part.strip() for part in inner.split(",") if part.strip()]
        return [strip_quotes(part) for part in parts]
    return strip_quotes(text)


def strip_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def extract_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith(f"{FRONTMATTER_BOUNDARY}\n"):
        return {}, text

    lines = text.splitlines()
    try:
        end_index = lines[1:].index(FRONTMATTER_BOUNDARY) + 1
    except ValueError as exc:
        raise ValueError("frontmatter closing boundary not found") from exc

    frontmatter_text = "\n".join(lines[1:end_index])
    body = "\n".join(lines[end_index + 1 :])
    return parse_yaml_like(frontmatter_text), body


def parse_yaml_like(text: str) -> dict[str, Any]:
    lines = text.splitlines()
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any] | list[Any]]] = [(0, root)]
    index = 0

    while index < len(lines):
        raw_line = lines[index]
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            index += 1
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        while len(stack) > 1 and indent < stack[-1][0]:
            stack.pop()

        container = stack[-1][1]

        if stripped.startswith("- "):
            if not isinstance(container, list):
                raise ValueError(f"list item without list container: {raw_line}")
            container.append(parse_scalar(stripped[2:]))
            index += 1
            continue

        if not isinstance(container, dict) or ":" not in stripped:
            raise ValueError(f"unsupported frontmatter line: {raw_line}")

        key, remainder = stripped.split(":", 1)
        key = key.strip()
        remainder = remainder.strip()

        if remainder in {">", "|"}:
            block_lines: list[str] = []
            block_index = index + 1
            min_indent: int | None = None
            while block_index < len(lines):
                candidate = lines[block_index]
                if not candidate.strip():
                    block_lines.append("")
                    block_index += 1
                    continue
                candidate_indent = len(candidate) - len(candidate.lstrip(" "))
                if candidate_indent <= indent:
                    break
                if min_indent is None or candidate_indent < min_indent:
                    min_indent = candidate_indent
                block_lines.append(candidate)
                block_index += 1
            normalized = []
            for line in block_lines:
                if not line:
                    normalized.append("")
                    continue
                normalized.append(line[min_indent or 0 :].rstrip())
            root_value = " ".join(part for part in normalized if part).strip() if remainder == ">" else "\n".join(normalized).strip()
            container[key] = root_value or None
            index = block_index
            continue

        if remainder == "":
            next_index = index + 1
            next_line = None
            while next_index < len(lines):
                candidate = lines[next_index]
                if candidate.strip() and not candidate.lstrip().startswith("#"):
                    next_line = candidate
                    break
                next_index += 1
            if next_line is None:
                container[key] = None
                index += 1
                continue
            next_indent = len(next_line) - len(next_line.lstrip(" "))
            if next_indent <= indent:
                container[key] = None
                index += 1
                continue
            if next_line.strip().startswith("- "):
                new_list: list[Any] = []
                container[key] = new_list
                stack.append((next_indent, new_list))
            else:
                new_dict: dict[str, Any] = {}
                container[key] = new_dict
                stack.append((next_indent, new_dict))
            index += 1
            continue

        container[key] = parse_scalar(remainder)
        index += 1

    return root


def normalize_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value).strip()
    return [text] if text else []


def first_heading(body: str) -> str | None:
    for line in body.splitlines():
        if line.startswith("#"):
            return line.lstrip("#").strip()
    return None


def first_paragraph(body: str) -> str:
    paragraph_lines: list[str] = []
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            if paragraph_lines:
                break
            continue
        if stripped.startswith("#"):
            stripped = stripped.lstrip("#").strip()
        paragraph_lines.append(stripped)
        if len(paragraph_lines) >= 2:
            break
    return " ".join(paragraph_lines).strip()


def parse_markdown_with_frontmatter(path: Path, *, required_frontmatter: bool) -> tuple[dict[str, Any], str] | None:
    try:
        frontmatter, body = extract_frontmatter(path)
    except Exception as exc:  # noqa: BLE001
        warn(f"skipping {relative_path(path)}: {exc}")
        return None

    if required_frontmatter and not frontmatter:
        warn(f"skipping {relative_path(path)}: missing frontmatter")
        return None

    return frontmatter, body


def build_core_node(path: Path, node_type: str, frontmatter: dict[str, Any], body: str) -> dict[str, Any]:
    title = (
        frontmatter.get("title")
        or first_heading(body)
        or path.stem
    )
    return {
        "id": frontmatter.get("id") or path.stem,
        "type": node_type,
        "title": title,
        "status": frontmatter.get("status"),
        "path": relative_path(path),
        "mentions_skills": normalize_list(frontmatter.get("mentions_skills")),
        "mentions_agents": normalize_list(frontmatter.get("mentions_agents")),
        "depends_on": normalize_list(frontmatter.get("depends_on")),
        "parent_doc": frontmatter.get("parent_doc"),
    }


def extract_board_nodes_and_edges() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    board_specs = (
        (
            "Epic",
            ROOT_DIR / "project/board/epics",
            {
                "stories": "stories",
                "epic_id": None,
                "story_id": None,
            },
        ),
        (
            "Story",
            ROOT_DIR / "project/board/stories",
            {
                "stories": None,
                "tasks": "tasks",
                "epic_id": "epic_id",
                "story_id": None,
            },
        ),
        (
            "Task",
            ROOT_DIR / "project/board/tasks",
            {
                "stories": None,
                "tasks": None,
                "epic_id": "epic_id",
                "story_id": "story_id",
            },
        ),
    )

    for node_type, directory, fields in board_specs:
        if not directory.exists():
            continue
        for path in sorted(directory.glob("*.md")):
            parsed = parse_markdown_with_frontmatter(path, required_frontmatter=True)
            if parsed is None:
                continue
            frontmatter, body = parsed
            node = build_core_node(path, node_type, frontmatter, body)
            node["date_created"] = frontmatter.get("date_created")
            node["date_started"] = frontmatter.get("date_started")
            node["date_completed"] = frontmatter.get("date_completed")
            if fields.get("epic_id"):
                node["epic_id"] = frontmatter.get("epic_id") or frontmatter.get("epic")
            if fields.get("story_id"):
                node["story_id"] = frontmatter.get("story_id")
            if fields.get("stories"):
                node["stories"] = normalize_list(frontmatter.get("stories"))
                for child_id in node["stories"]:
                    edges.append({"from": node["id"], "to": child_id, "type": "contains"})
            if fields.get("tasks"):
                node["tasks"] = normalize_list(frontmatter.get("tasks"))
                for child_id in node["tasks"]:
                    edges.append({"from": node["id"], "to": child_id, "type": "contains"})
            nodes.append(node)

    return nodes, edges


def build_graph() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    nodes, edges = extract_board_nodes_and_edges()
    extra_nodes, extra_edges = extract_documentation_nodes_and_edges()
    nodes.extend(extra_nodes)
    edges.extend(extra_edges)
    skill_nodes = extract_skill_nodes()
    agent_nodes = extract_agent_nodes()
    nodes.extend(skill_nodes)
    nodes.extend(agent_nodes)
    edges.extend(derive_optional_edges(nodes))
    return sort_nodes(nodes), sort_edges(edges)


def infer_story_id(ref_id: str | None) -> str | None:
    if not ref_id:
        return None
    if "_T" in ref_id:
        return ref_id.rsplit("_T", 1)[0]
    return ref_id if BOARD_ID_RE.match(ref_id) else None


def infer_plan_or_summary_targets(stem: str, pattern: re.Pattern[str]) -> tuple[str | None, str | None]:
    match = pattern.match(stem)
    if not match:
        return None, None
    target_id = match.group(1)
    return infer_story_id(target_id), target_id if "_T" in target_id else None


def extract_documentation_nodes_and_edges() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    documentation_dir = ROOT_DIR / "project/documentation"

    plan_dir = documentation_dir / "plans"
    if plan_dir.exists():
        for path in sorted(plan_dir.glob("*.md")):
            parsed = parse_markdown_with_frontmatter(path, required_frontmatter=False)
            if parsed is None:
                continue
            frontmatter, body = parsed
            story_id, task_id = infer_plan_or_summary_targets(path.stem, PLAN_RE)
            node = build_core_node(path, "Plan", frontmatter, body)
            node["story_id"] = story_id
            node["task_id"] = task_id
            nodes.append(node)
            target_id = task_id or story_id
            if target_id:
                edges.append({"from": node["id"], "to": target_id, "type": "plans"})

    summary_dir = documentation_dir / "summaries"
    if summary_dir.exists():
        for path in sorted(summary_dir.glob("*.md")):
            parsed = parse_markdown_with_frontmatter(path, required_frontmatter=False)
            if parsed is None:
                continue
            frontmatter, body = parsed
            story_id, task_id = infer_plan_or_summary_targets(path.stem, SUMMARY_RE)
            node = build_core_node(path, "Summary", frontmatter, body)
            node["story_id"] = story_id
            node["task_id"] = task_id
            nodes.append(node)
            target_id = task_id or story_id
            if target_id:
                edges.append({"from": node["id"], "to": target_id, "type": "summarizes"})

    example_dir = documentation_dir / "examples"
    seen_docs: set[Path] = set()
    if example_dir.exists():
        for path in sorted(example_dir.glob("*.md")):
            parsed = parse_markdown_with_frontmatter(path, required_frontmatter=False)
            if parsed is None:
                continue
            frontmatter, body = parsed
            node = build_core_node(path, "Doc", frontmatter, body)
            nodes.append(node)
            seen_docs.add(path.resolve())

    for path in sorted(documentation_dir.glob("*.md")):
        if path.resolve() in seen_docs:
            continue
        parsed = parse_markdown_with_frontmatter(path, required_frontmatter=False)
        if parsed is None:
            continue
        frontmatter, body = parsed
        node = build_core_node(path, "Doc", frontmatter, body)
        nodes.append(node)

    todo_path = ROOT_DIR / "project/todo.md"
    if todo_path.exists():
        todo_nodes, todo_edges = extract_todo_nodes_and_edges(todo_path)
        nodes.extend(todo_nodes)
        edges.extend(todo_edges)

    return nodes, edges


def extract_todo_nodes_and_edges(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    nodes: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    in_comment_block = False

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if in_comment_block:
            if "-->" in raw_line:
                in_comment_block = False
            continue
        if not stripped:
            continue
        if stripped.startswith("<!--"):
            if "-->" not in stripped:
                in_comment_block = True
            continue

        board_ref_match = TODO_REF_AT_END_RE.search(stripped)
        board_ref = board_ref_match.group(1) if board_ref_match else None
        normalized = " ".join(stripped.split())
        fallback_id = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
        node_id = board_ref or fallback_id
        nodes.append(
            {
                "id": node_id,
                "type": "TodoEntry",
                "title": normalized,
                "status": None,
                "path": relative_path(path),
                "text": stripped,
                "board_ref": board_ref,
            }
        )
        if board_ref:
            edges.append({"from": node_id, "to": board_ref, "type": "queued_as"})

    return nodes, edges


def extract_description_from_markdown(path: Path) -> tuple[dict[str, Any], str, str]:
    parsed = parse_markdown_with_frontmatter(path, required_frontmatter=False)
    if parsed is None:
        return {}, "", ""
    frontmatter, body = parsed
    description = str(frontmatter.get("description") or first_paragraph(body) or "").strip()
    return frontmatter, body, description


def deduplicate_named_nodes(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    preferred: dict[str, dict[str, Any]] = {}
    for node in candidates:
        current = preferred.get(node["id"])
        if current is None:
            preferred[node["id"]] = node
            continue
        current_is_root = not current["path"].startswith(".agents/")
        new_is_root = not node["path"].startswith(".agents/")
        if new_is_root and not current_is_root:
            preferred[node["id"]] = node
    return sort_nodes(list(preferred.values()))


def extract_skill_nodes() -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for base_dir in (ROOT_DIR / "skills", ROOT_DIR / ".agents/skills"):
        if not base_dir.exists():
            continue
        for skill_file in sorted(base_dir.glob("*/SKILL.md")):
            frontmatter, body, description = extract_description_from_markdown(skill_file)
            skill_id = skill_file.parent.name
            candidates.append(
                {
                    "id": skill_id,
                    "type": "Skill",
                    "title": frontmatter.get("name") or skill_id,
                    "status": None,
                    "path": relative_path(skill_file),
                    "description": description,
                }
            )
    return deduplicate_named_nodes(candidates)


def extract_agent_nodes() -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    base_patterns = (
        ROOT_DIR / "agents",
        ROOT_DIR / ".agents",
        ROOT_DIR / ".agents/agents",
    )
    for base_dir in base_patterns:
        if not base_dir.exists():
            continue
        for agent_file in sorted(base_dir.glob("*.md")):
            frontmatter, body, description = extract_description_from_markdown(agent_file)
            agent_id = agent_file.stem
            candidates.append(
                {
                    "id": agent_id,
                    "type": "Agent",
                    "title": frontmatter.get("name") or first_heading(body) or agent_id,
                    "status": None,
                    "path": relative_path(agent_file),
                    "description": description,
                }
            )
    return deduplicate_named_nodes(candidates)


def derive_optional_edges(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    edges: list[dict[str, Any]] = []
    skill_ids = {node["id"] for node in nodes if node.get("type") == "Skill"}
    agent_ids = {node["id"] for node in nodes if node.get("type") == "Agent"}

    for node in nodes:
        node_type = node.get("type")
        for skill_id in normalize_list(node.get("mentions_skills")):
            edges.append({"from": node["id"], "to": skill_id, "type": "mentions_skill"})
            if skill_id not in skill_ids:
                node.setdefault("debug", {}).setdefault("unknown_mentions_skills", []).append(skill_id)

        for agent_id in normalize_list(node.get("mentions_agents")):
            edges.append({"from": node["id"], "to": agent_id, "type": "mentions_agent"})
            if agent_id not in agent_ids:
                node.setdefault("debug", {}).setdefault("unknown_mentions_agents", []).append(agent_id)

        if node_type in {"Story", "Task"}:
            for dependency_id in normalize_list(node.get("depends_on")):
                edges.append({"from": node["id"], "to": dependency_id, "type": "depends_on"})
                edges.append({"from": dependency_id, "to": node["id"], "type": "blocks"})

        if node_type == "Doc" and node.get("parent_doc"):
            edges.append({"from": node["id"], "to": str(node["parent_doc"]), "type": "parent_doc"})

    return edges


def sort_nodes(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(nodes, key=lambda node: (node.get("type", ""), node.get("id", ""), node.get("path", "")))


def sort_edges(edges: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(edges, key=lambda edge: (edge.get("type", ""), edge.get("from", ""), edge.get("to", "")))


def filter_by_type(items: list[dict[str, Any]], type_filter: str | None, allowed: set[str]) -> list[dict[str, Any]]:
    if not type_filter:
        return items
    if type_filter not in allowed:
        return []
    return [item for item in items if item.get("type") == type_filter]


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.command:
        parser.print_help(sys.stderr)
        return 1

    nodes, edges = build_graph()

    if args.command == "graph::nodes":
        return emit_json(filter_by_type(nodes, args.type_filter, NODE_TYPES))

    if args.command == "graph::edges":
        return emit_json(filter_by_type(edges, args.type_filter, EDGE_TYPES))

    parser.print_help(sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
# THROWAWAY — spike prototype for E25_S01 latency measurement. Do not import.

import argparse
import re
import shutil
from pathlib import Path

BOARD_REF_RE = re.compile(r"\b(E\d{2}(?:_S\d{2})?(?:_T\d{2})?)\b")
FILE_GROUPS = [
    ("board/epics", "*.md"),
    ("board/stories", "*.md"),
    ("board/tasks", "*.md"),
    ("documentation/plans", "*.md"),
    ("documentation/summaries", "*.md"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a deterministic synthetic 10x board for E25_S01.")
    parser.add_argument("source_root", nargs="?", default="project", help="Source project-like root")
    parser.add_argument("output_root", nargs="?", default="project/.synthetic/E25_S01_board_10x", help="Synthetic output root")
    parser.add_argument("--replicas", type=int, default=10, help="Number of synthetic replicas to generate")
    return parser.parse_args()


def prefix_for(index: int) -> str:
    return f"SYNTH{index:02d}_"


def rewrite_board_refs(text: str, prefix: str) -> str:
    return BOARD_REF_RE.sub(lambda match: f"{prefix}{match.group(1)}", text)


def rewrite_file(source_file: Path, destination_file: Path, prefix: str) -> None:
    rewritten = rewrite_board_refs(source_file.read_text(encoding="utf-8"), prefix)
    destination_file.write_text(rewritten, encoding="utf-8")


def ensure_clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def generate_docs(source_root: Path, output_root: Path, replicas: int) -> None:
    for relative_dir, pattern in FILE_GROUPS:
        source_dir = source_root / relative_dir
        destination_dir = output_root / relative_dir
        destination_dir.mkdir(parents=True, exist_ok=True)
        for index in range(1, replicas + 1):
            prefix = prefix_for(index)
            for source_file in sorted(source_dir.glob(pattern)):
                destination_name = f"{prefix}{source_file.name}"
                rewrite_file(source_file, destination_dir / destination_name, prefix)


def generate_todo(source_root: Path, output_root: Path, replicas: int) -> None:
    source_lines = (source_root / "todo.md").read_text(encoding="utf-8").splitlines()
    preserved = []
    entries = []
    for line in source_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("<!--") or set(stripped) <= {"-"}:
            preserved.append(line)
        else:
            entries.append(line)
    todo_lines = list(preserved)
    if todo_lines and todo_lines[-1] != "":
        todo_lines.append("")
    for index in range(1, replicas + 1):
        prefix = prefix_for(index)
        todo_lines.append(f"<!-- {prefix[:-1]} -->")
        todo_lines.extend(rewrite_board_refs(line, prefix) for line in entries)
        todo_lines.append("")
    (output_root / "todo.md").write_text("\n".join(todo_lines).rstrip() + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    source_root = Path(args.source_root).resolve()
    output_root = Path(args.output_root).resolve()
    ensure_clean_dir(output_root)
    generate_docs(source_root, output_root, args.replicas)
    generate_todo(source_root, output_root, args.replicas)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BOARD_INDEX="$SCRIPT_DIR/board-index"

"$BOARD_INDEX" graph::nodes | python3 -m json.tool >/dev/null
"$BOARD_INDEX" graph::edges | python3 -m json.tool >/dev/null

export REPO_ROOT BOARD_INDEX
python3 - <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
board_index = os.environ["BOARD_INDEX"]

nodes = json.loads(subprocess.check_output([board_index, "graph::nodes"], text=True))
edges = json.loads(subprocess.check_output([board_index, "graph::edges"], text=True))

node_counts = {}
for node in nodes:
    node_counts[node["type"]] = node_counts.get(node["type"], 0) + 1

thresholds = {
    "Epic": 22,
    "Story": 90,
    "Task": 150,
    "TodoEntry": 10,
    "Skill": 5,
    "Agent": 2,
}

for node_type, minimum in thresholds.items():
    actual = node_counts.get(node_type, 0)
    if actual < minimum:
        raise SystemExit(f"{node_type} count too low: expected >= {minimum}, got {actual}")

contains_edges = [edge for edge in edges if edge["type"] == "contains"]
queued_edges = [edge for edge in edges if edge["type"] == "queued_as"]
if not contains_edges:
    raise SystemExit("contains edge set is empty")
if not queued_edges:
    raise SystemExit("queued_as edge set is empty")

allowed_prefixes = ("project/", "skills/", "agents/", ".agents/")
bad_paths = sorted(
    {
        node["path"]
        for node in nodes
        if "path" in node and node["path"] and not node["path"].startswith(allowed_prefixes)
    }
)
if bad_paths:
    raise SystemExit(f"unexpected node paths found: {bad_paths}")

throwaway_files = [
    repo_root / "scripts/e25_s01_extract_board_graph.py",
    repo_root / "scripts/e25_s01_generate_synthetic_board.py",
]
for throwaway_file in throwaway_files:
    if throwaway_file.exists():
        content = throwaway_file.read_text(encoding="utf-8")
        if "# THROWAWAY" not in content:
            raise SystemExit(f"throwaway marker missing: {throwaway_file.relative_to(repo_root)}")

new_library_files = [
    repo_root / "skills/index/scripts/board_index.py",
    repo_root / "skills/index/scripts/board-index",
]
blocked_names = {
    "e25_s01_extract_board_graph.py",
    "e25_s01_generate_synthetic_board.py",
}
for library_file in new_library_files:
    content = library_file.read_text(encoding="utf-8")
    for blocked_name in blocked_names:
        if blocked_name in content:
            raise SystemExit(f"throwaway reference leaked into {library_file.relative_to(repo_root)}")

print("SMOKE TEST PASSED")
PY

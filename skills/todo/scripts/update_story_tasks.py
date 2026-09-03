#!/usr/bin/env python3
"""
skills/todo/scripts/update_story_tasks.py

Mechanically inserts a task ID into a story board file's `tasks:` frontmatter
list, if it is not already present. Idempotent (a re-run with the same
task_id is a no-op, exit 0).

This is a pure text/frontmatter edit and does no board-wide validation beyond
"frontmatter block exists" — it is intended to be invoked already wrapped in
scripts/with-lock.sh, keyed to the story file, per templates/SCRUM_BOARD_SCHEMA.md's
File Locking section (board frontmatter writes must go through the lock wrapper).

Usage:
    python3 skills/todo/scripts/update_story_tasks.py <story-file> <task-id>

Exit codes:
    0   success (task_id inserted, or already present)
    1   usage error
    2   story file has no parseable frontmatter block
"""
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: update_story_tasks.py <story-file> <task-id>", file=sys.stderr)
        return 1

    path, task_id = sys.argv[1], sys.argv[2]

    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    parts = content.split("---", 2)
    if len(parts) < 3:
        print(f"Error: {path} has no valid '---' frontmatter block", file=sys.stderr)
        return 2

    _, frontmatter, rest = parts
    lines = frontmatter.split("\n")
    task_line = f"  - {task_id}"

    if any(line.strip() == task_line.strip() for line in lines):
        print(f"No-op: {task_id} already present in {path}'s tasks: list")
        return 0

    idx = None
    inline_empty_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "tasks:":
            idx = i
            break
        if stripped == "tasks: []":
            inline_empty_idx = i
            break

    if inline_empty_idx is not None:
        lines[inline_empty_idx] = "tasks:"
        lines.insert(inline_empty_idx + 1, task_line)
    elif idx is not None:
        j = idx + 1
        while j < len(lines) and lines[j].strip().startswith("- "):
            j += 1
        lines.insert(j, task_line)
    else:
        # No tasks: key found at all — append one at the end of the frontmatter,
        # trimming any single trailing blank line first so formatting stays tidy.
        if lines and lines[-1].strip() == "":
            lines.pop()
        lines.append("tasks:")
        lines.append(task_line)
        lines.append("")

    new_frontmatter = "\n".join(lines)
    new_content = "---" + new_frontmatter + "---" + rest

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"Updated {path}: added {task_id} to tasks:")
    return 0


if __name__ == "__main__":
    sys.exit(main())

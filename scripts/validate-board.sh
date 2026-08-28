#!/usr/bin/env bash
# validate-board.sh — validate scrum board frontmatter for epic, story, and task files
#
# Usage: ./scripts/validate-board.sh <path-to-board-file> [more-files...]

set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "❌ Usage: $(basename "$0") <path-to-board-file> [more-files...]"
  exit 1
fi

python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

STATUS_VALUES = {
    "Pending",
    "In Progress",
    "Passed",
    "Passed with remarks",
    "Failed",
    "Rejected",
    "Blocked",
    "Backlog",
    "Done",
}

# E39 tiered item-level caution/escalation. crucial_level is OPTIONAL — absence means no
# elevated caution. When present it must be one of these three values (see
# templates/SCRUM_BOARD_SCHEMA.md). crucial_set_by / crucial_note are free-text fields that are
# only recognised (not enum-validated) here; their "required when crucial_level is set" rule is
# an authoring discipline documented in the schema, not mechanically enforced by this script —
# the same treatment given to scope_rationale's "required when execution_scope is set" rule.
CRUCIAL_LEVEL_VALUES = {
    "advisory",
    "gated",
    "locked",
}

# Base keys shared by every item type, plus the E32 adaptive-execution-scope fields.
#
# The execution-scope fields are all OPTIONAL — a board file that omits them is valid and is
# treated as execution_scope: task / needs_docs: true (see the backward-compatibility rule in
# templates/SCRUM_BOARD_SCHEMA.md). They are listed here so that files which DO carry them are
# not rejected as unknown.
#
# Two groups, distinguished by who writes them:
#   - assigned at breakdown time by the scrum-master (execution_scope … epic_scope_approval)
#   - written at runtime by /close-story and /do (actual_files_changed … divergence_flag)
# Runtime fields appear only after a task has executed, so most task files will lack them.
# task_changed_files is deliberately absent: it lives in the bundle manifest JSON
# (project/queue/bundle-<E##_S##>.json), not in task frontmatter.
EXECUTION_SCOPE_KEYS = {
    "execution_scope", "needs_docs", "scope_rationale",
    "jenga_assigned", "override_justification", "epic_scope_approval",
}

CLOSE_STORY_KEYS = {
    "actual_files_changed", "actual_lines_delta", "scope_divergence_flag", "divergence_flag",
}

# E39 tiered item-level caution/escalation fields. OPTIONAL and story/task-only — epics do not
# carry these; an epic's risk gating is already handled by epic_scope_approval. See
# templates/SCRUM_BOARD_SCHEMA.md.
#
# crucial_declined / crucial_declined_note (E39_S02_T03) are a separate optional pair recording
# that a scrum-master-proposed crucial_level was explicitly declined by the user for this item —
# the durable decline-tracking mechanism that stops the breakdown step from re-proposing on a
# later pass. Like crucial_set_by / crucial_note, they are free-text/recognised-not-enum-validated
# here; their "required when crucial_declined: true" rule is an authoring discipline documented in
# the schema, not mechanically enforced by this script.
CRUCIAL_KEYS = {
    "crucial_level", "crucial_set_by", "crucial_note",
    "crucial_declined", "crucial_declined_note",
}

ALLOWED_KEYS = {
    "epic": {
        "id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "stories", "docs",
        "epic_scope_approval",
        # OPTIONAL. Marks how the epic came to exist; only written by `/uncharted onboard`
        # (value: backfilled). Absence means the epic was authored normally, so every existing
        # epic that omits it stays valid. See templates/SCRUM_BOARD_SCHEMA.md.
        "provenance",
    },
    "story": {
        "id", "epic_id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "tasks", "docs",
        "priority", "depends_on",
        *CRUCIAL_KEYS,
    },
    "task": {
        "id", "story_id", "epic_id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "assigned_to", "docs",
        "depends_on",
        *EXECUTION_SCOPE_KEYS, *CLOSE_STORY_KEYS, *CRUCIAL_KEYS,
    },
}

ID_PATTERNS = {
    "epic": re.compile(r"^E\d{2}$"),
    "story": re.compile(r"^E\d{2}_S\d{2}$"),
    "task": re.compile(r"^E\d{2}_S\d{2}_T\d{2}$"),
}

ASSIGNEES = {"developer", "tester", "scrum-master"}

def split_comment(value: str) -> str:
    if "#" in value:
        return value.split("#", 1)[0].rstrip()
    return value.rstrip()

def extract_frontmatter(text: str, source: Path) -> list[str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError(f"{source}: missing opening frontmatter delimiter")
    try:
        end_index = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise ValueError(f"{source}: missing closing frontmatter delimiter")
    return lines[1:end_index]

def classify_item(item_id: str) -> str:
    for item_type, pattern in ID_PATTERNS.items():
        if pattern.match(item_id):
            return item_type
    raise ValueError(f"unrecognised board item id format: {item_id}")

def parse_frontmatter(lines: list[str], source: Path) -> dict:
    data = {}
    i = 0
    while i < len(lines):
        raw = lines[i]
        if not raw.strip():
            i += 1
            continue
        if raw.startswith("  - "):
            raise ValueError(f"{source}: list item without a parent key: {raw.strip()}")
        if ":" not in raw:
            raise ValueError(f"{source}: invalid frontmatter line: {raw.strip()}")

        key, value = raw.split(":", 1)
        key = key.strip()
        value = split_comment(value.strip())

        if value == "":
            items = []
            j = i + 1
            while j < len(lines) and lines[j].startswith("  - "):
                items.append(split_comment(lines[j][4:].strip()))
                j += 1
            data[key] = items if items else ""
            i = j
            continue

        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            if inner == "":
                data[key] = []
            else:
                parts = [part.strip() for part in inner.split(",")]
                parsed = []
                for part in parts:
                    parsed.append(part.strip().strip('"').strip("'"))
                data[key] = parsed
        else:
            data[key] = value.strip().strip('"').strip("'")
        i += 1
    return data

def validate_docs(source: Path, docs):
    if docs == "":
        raise ValueError(f"{source}: docs must be a YAML list when present")
    if not isinstance(docs, list):
        raise ValueError(f"{source}: docs must be a YAML list")
    for entry in docs:
        if not isinstance(entry, str) or not entry.strip():
            raise ValueError(f"{source}: docs entries must be non-empty strings")
        cleaned = entry.strip()
        if (
            cleaned.startswith("/")
            or cleaned.startswith("./")
            or cleaned.startswith("../")
            or "/./" in cleaned
            or cleaned.endswith("/.")
            or "/../" in cleaned
            or cleaned == ".."
        ):
            raise ValueError(f"{source}: docs entry must be repo-relative without leading './' or '/' ({entry})")

def validate_file(source: Path):
    text = source.read_text(encoding="utf-8")
    frontmatter_lines = extract_frontmatter(text, source)
    data = parse_frontmatter(frontmatter_lines, source)

    item_id = data.get("id")
    if not item_id:
        raise ValueError(f"{source}: missing required 'id' frontmatter field")

    item_type = classify_item(item_id)
    allowed_keys = ALLOWED_KEYS[item_type]
    unknown_keys = sorted(set(data.keys()) - allowed_keys)
    if unknown_keys:
        raise ValueError(f"{source}: unknown frontmatter field(s) for {item_type}: {', '.join(unknown_keys)}")

    status = data.get("status")
    if status and status not in STATUS_VALUES:
        raise ValueError(f"{source}: invalid status '{status}'")

    crucial_level = data.get("crucial_level")
    if crucial_level and crucial_level not in CRUCIAL_LEVEL_VALUES:
        raise ValueError(f"{source}: invalid crucial_level '{crucial_level}'")

    docs = data.get("docs", None)
    if docs is not None:
        validate_docs(source, docs)

    if item_type == "epic":
        if "stories" in data and data["stories"] != "" and not isinstance(data["stories"], list):
            raise ValueError(f"{source}: stories must be a YAML list when present")
    elif item_type == "story":
        if not data.get("epic_id"):
            raise ValueError(f"{source}: story files require epic_id")
        if "tasks" in data and data["tasks"] != "" and not isinstance(data["tasks"], list):
            raise ValueError(f"{source}: tasks must be a YAML list when present")
    elif item_type == "task":
        if not data.get("epic_id") or not data.get("story_id"):
            raise ValueError(f"{source}: task files require both epic_id and story_id")
        assigned_to = data.get("assigned_to", "")
        if assigned_to and assigned_to not in ASSIGNEES:
            raise ValueError(f"{source}: assigned_to must be one of: developer, tester, scrum-master")

    print(f"✅ {source}: board frontmatter valid ({item_type})")

exit_code = 0
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    if not path.is_file():
        print(f"❌ {path}: file not found or not readable", file=sys.stderr)
        exit_code = 1
        continue
    try:
        validate_file(path)
    except Exception as exc:
        print(f"❌ {exc}", file=sys.stderr)
        exit_code = 1

sys.exit(exit_code)
PY

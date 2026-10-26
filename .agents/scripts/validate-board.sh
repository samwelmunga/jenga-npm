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
import datetime
import re
import sys
from pathlib import Path

# The strict-YAML gate (assert_parses_as_yaml) needs PyYAML, which is not guaranteed present.
# Imported ONCE here, rather than per file, so the warning below is emitted once per run instead
# of once per board file.
#
# When it is missing this validator still exits 0 on frontmatter it has NOT fully checked, so the
# absence must be audible. Silence would be a validator that reports a clean board while skipping
# the very shapes it exists to catch -- which is how 36 malformed files accumulated in the first
# place (see assert_parses_as_yaml). The warning goes to stderr so stdout stays a clean report.
try:
    import yaml as _yaml
except ImportError:
    _yaml = None
    sys.stderr.write(
        "validate-board.sh: warning: PyYAML is not installed, so the strict-YAML check is SKIPPED. "
        "An unquoted ':' in a scalar and a value merely starting with a quote will NOT be rejected "
        "(duplicate keys still are). A pass from this run is weaker than a normal pass. "
        "Install it (apt: python3-yaml, pip: PyYAML) to get the full check.\n")

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
    "Merged",
    "Publicized",
    "Privatized",
    "Deployed to Stage",
    "Deployed to Prod",
}

# E39 tiered item-level caution/escalation. crucial_level is OPTIONAL — absence means no
# elevated caution. When present it must be one of these three values (see
# templates/SCRUM_BOARD_SCHEMA.md). crucial_set_by / crucial_note are free-text fields that are
# only recognised (not enum-validated) here; their "required when crucial_level is set" rule is
# an authoring discipline documented in the schema, not mechanically enforced by this script —
# the same treatment given to scope_rationale's "required when execution_scope is set" rule.
#
# jenga_assigned / override_justification is the ONE pairing rule this script does enforce (see
# validate_file's task branch). It is the exception because /do step 4.1 halts on the invalid
# pairing, so an unenforced violation makes the task undispatchable rather than just untidy.
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

# E51_S05_T02. Written by scripts/mark-deployed.sh in the same locked write window a ticket is
# set to status: Deployed to Prod (never on a Deployed to Stage-only write). Allow-listed for
# epic, story, AND task per this field's own AC, even though in practice only tasks (and
# occasionally stories) are expected to ever carry it.
DEPLOY_KEYS = {
    "date_deployed_prod",
}

# E76_S01_T01 per-task token usage. Runtime-written, never authored by hand (by /close-story and
# scripts/task-usage.sh --persist). TASK-ONLY: not allow-listed for epics or stories. Absence means
# "not measured", not zero. Names are checked by exact spelling, so a misspelling such as
# usage_tokens_in is still rejected as an unknown key. See "Usage fields" in
# templates/SCRUM_BOARD_SCHEMA.md.
USAGE_KEYS = {
    "usage_input_tokens", "usage_output_tokens", "usage_cache_write_tokens",
    "usage_cache_read_tokens", "usage_total_tokens", "usage_transcripts",
    "usage_measured_on", "usage_possibly_incomplete",
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

# E71_S03 external links. OPTIONAL, and valid on epics, stories AND tasks (unlike CRUCIAL_KEYS,
# which is story/task-only, so it must not be reused here). external_refs is a block list of
# mappings; external_refs_declined (true only) / external_refs_declined_note record that the user
# skipped the link prompt. See "External Refs Fields" and "Declined External Refs Fields" in
# templates/SCRUM_BOARD_SCHEMA.md. Absence of all three is always valid.
EXTERNAL_REFS_KEYS = {
    "external_refs", "external_refs_declined", "external_refs_declined_note",
}

# Documented values for external_refs entries. Adding a system means adding a row here and to the
# tables in templates/SCRUM_BOARD_SCHEMA.md; it never means adding a frontmatter key.
EXTERNAL_REF_KINDS = {
    "jira": {"issue"},
    "confluence": {"page"},
    "bitbucket": {"repo", "pull-request"},
}
EXTERNAL_REF_ENTRY_KEYS = {"system", "kind", "key", "url", "linked_on"}

ALLOWED_KEYS = {
    "epic": {
        "id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "stories", "docs",
        "epic_scope_approval",
        # OPTIONAL. Marks how the epic came to exist; only written by `/uncharted onboard`
        # (value: backfilled). Absence means the epic was authored normally, so every existing
        # epic that omits it stays valid. See templates/SCRUM_BOARD_SCHEMA.md.
        "provenance",
        *DEPLOY_KEYS, *EXTERNAL_REFS_KEYS,
    },
    "story": {
        "id", "epic_id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "tasks", "docs",
        "priority", "depends_on",
        *CRUCIAL_KEYS, *DEPLOY_KEYS, *EXTERNAL_REFS_KEYS,
    },
    "task": {
        "id", "story_id", "epic_id", "title", "status", "date_created", "date_started", "date_completed",
        "dates_previously_completed", "reopened_on", "reopened_reason", "assigned_to", "docs",
        "depends_on",
        *EXECUTION_SCOPE_KEYS, *CLOSE_STORY_KEYS, *USAGE_KEYS, *CRUCIAL_KEYS, *DEPLOY_KEYS,
        *EXTERNAL_REFS_KEYS,
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

def clean_scalar(value: str) -> str:
    """Strip a trailing ' # comment' and surrounding quotes from a mapping-entry value.

    Unlike split_comment(), a '#' only starts a comment when preceded by whitespace, so a URL
    fragment (https://host/page#section) survives intact.
    """
    value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    return value.strip('"').strip("'")

def parse_mapping_block(lines: list[str], start: int, source: Path):
    """Read a YAML block list of flat mappings beginning at lines[start].

    Accepts the documented shape: `  - k: v` opens an entry, `    k: v` continues it. Returns
    (entries, next_index). Stops at the first line that is neither, leaving it to the caller.
    """
    entries = []
    j = start
    while j < len(lines):
        raw = lines[j]
        if not raw.strip():
            j += 1
            continue
        if raw.startswith("  - "):
            entries.append({})
            body = raw[4:]
        elif raw.startswith("    ") and entries:
            body = raw.strip()
        else:
            break
        if ":" not in body:
            raise ValueError(
                f"{source}: external_refs entry {len(entries)} has a line that is not 'key: value': "
                f"{raw.strip()} (entries must be mappings, one '- system: ...' block per link)"
            )
        entry_key, entry_value = body.split(":", 1)
        entry_key = entry_key.strip()
        if entry_key in entries[-1]:
            raise ValueError(
                f"{source}: external_refs entry {len(entries)} repeats key '{entry_key}'"
            )
        entries[-1][entry_key] = clean_scalar(entry_value.strip())
        j += 1
    return entries, j

def validate_external_refs(source: Path, refs):
    """Enforce the contract in templates/SCRUM_BOARD_SCHEMA.md's External Refs Fields."""
    if not isinstance(refs, list):
        raise ValueError(
            f"{source}: external_refs must be a YAML list of mappings when present "
            "(use 'external_refs: []' for none)"
        )
    for index, entry in enumerate(refs, start=1):
        where = f"{source}: external_refs entry {index}"
        if not isinstance(entry, dict):
            raise ValueError(
                f"{where} must be a block mapping ('- system: ...' with the other keys indented "
                f"beneath it), got {entry!r}"
            )
        unknown = sorted(set(entry) - EXTERNAL_REF_ENTRY_KEYS)
        if unknown:
            raise ValueError(
                f"{where} has unknown key(s): {', '.join(unknown)} "
                f"(allowed: {', '.join(sorted(EXTERNAL_REF_ENTRY_KEYS))})"
            )
        system = entry.get("system", "")
        if not system:
            raise ValueError(f"{where} is missing required 'system' "
                             f"(one of: {', '.join(sorted(EXTERNAL_REF_KINDS))})")
        if system not in EXTERNAL_REF_KINDS:
            raise ValueError(f"{where} has unknown system '{system}' "
                             f"(one of: {', '.join(sorted(EXTERNAL_REF_KINDS))})")
        kind = entry.get("kind", "")
        if not kind:
            raise ValueError(f"{where} is missing required 'kind' for system '{system}' "
                             f"(one of: {', '.join(sorted(EXTERNAL_REF_KINDS[system]))})")
        if kind not in EXTERNAL_REF_KINDS[system]:
            raise ValueError(f"{where} has invalid kind '{kind}' for system '{system}' "
                             f"(one of: {', '.join(sorted(EXTERNAL_REF_KINDS[system]))})")
        has_key = bool(entry.get("key", ""))
        has_url = bool(entry.get("url", ""))
        if "key" in entry and not has_key:
            raise ValueError(f"{where} has an empty 'key'")
        if "url" in entry and not has_url:
            raise ValueError(f"{where} has an empty 'url'")
        if has_key and has_url:
            raise ValueError(f"{where} has both 'key' and 'url'; exactly one is allowed")
        if not has_key and not has_url:
            raise ValueError(f"{where} has neither 'key' nor 'url'; exactly one is required")
        linked_on = entry.get("linked_on", "")
        if not linked_on:
            raise ValueError(f"{where} is missing required 'linked_on' (YYYY-MM-DD)")
        try:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", linked_on):
                raise ValueError
            datetime.date.fromisoformat(linked_on)
        except ValueError:
            raise ValueError(f"{where} has linked_on '{linked_on}' which is not a real "
                             "YYYY-MM-DD date") from None

def validate_external_refs_declined(source: Path, data: dict):
    """external_refs_declined accepts only 'true'; a blank note is rejected when it is present."""
    if "external_refs_declined" not in data:
        return
    declined = data["external_refs_declined"]
    if declined != "true":
        raise ValueError(
            f"{source}: external_refs_declined must be 'true' when present (got {declined!r}); "
            "there is no false state, omit the field instead"
        )
    note = data.get("external_refs_declined_note", "")
    if not isinstance(note, str) or not note.strip():
        raise ValueError(
            f"{source}: external_refs_declined: true requires a non-empty "
            "external_refs_declined_note (templates/SCRUM_BOARD_SCHEMA.md)"
        )

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

        # external_refs is the one key whose block list holds MAPPINGS rather than plain strings
        # (templates/SCRUM_BOARD_SCHEMA.md, External Refs Fields). Scoped to this key on purpose:
        # the generic string-list branch below stays byte-for-byte what it was, so no existing
        # key can change how it parses.
        if key == "external_refs" and value == "":
            data[key], i = parse_mapping_block(lines, i + 1, source)
            if not data[key]:
                data[key] = ""
            continue

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

def assert_parses_as_yaml(lines: list[str], source: Path) -> None:
    """Reject frontmatter that a real YAML parser cannot read.

    parse_frontmatter() below is a hand-rolled line splitter, and it is far more
    lenient than YAML itself. That gap was not theoretical: 36 board files
    accumulated frontmatter this script called valid but every real consumer --
    the dashboard's board parser among them -- silently skipped, so the board
    under-reported itself with no error surfaced anywhere. The three shapes that
    got through were an unquoted colon in a scalar (`title: Adopt j: prefix`), a
    value merely starting with a quote (`title: "Merged" Status via /self-sync`),
    and a duplicated key.

    PyYAML is stdlib-adjacent but not guaranteed present on every consumer, so a
    missing import degrades to a skip rather than a hard failure. Be precise about
    what that costs: of the three shapes above, only the duplicated key is covered
    by the targeted checks below. The unquoted colon and the leading-quote value
    are caught by PyYAML and by nothing else, so without it this function's main
    purpose is not served. The import is attempted once at module level, which
    warns loudly on stderr -- the skip is never silent.
    """
    body = "\n".join(lines)
    yaml = _yaml
    if yaml is not None:
        try:
            yaml.safe_load(body)
        except yaml.YAMLError as exc:
            detail = str(exc).splitlines()[0]
            raise ValueError(
                f"{source}: frontmatter is not valid YAML ({detail}). "
                "Free-text values containing ':' must be quoted, and multiple "
                "reopen reasons must be a YAML list -- see "
                "templates/SCRUM_BOARD_SCHEMA.md's Reopen Tracking Fields."
            )
        except ValueError as exc:
            # PyYAML resolves an unquoted 2026-02-30 to a date and raises a bare ValueError
            # (not a YAMLError) with no file name. Surface it as a normal, attributable failure.
            raise ValueError(
                f"{source}: frontmatter contains a value YAML cannot load ({exc}). "
                "Dates such as external_refs linked_on must be real YYYY-MM-DD dates."
            )

    # Duplicate keys are legal-ish to some YAML loaders (last wins) but always a
    # board-authoring bug: one of the two values is being silently discarded.
    seen = set()
    for line in lines:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
        if not match:
            continue
        key = match.group(1)
        if key in seen:
            raise ValueError(
                f"{source}: duplicated frontmatter key '{key}' -- one of its two "
                "values is silently discarded; merge them into a single entry"
            )
        seen.add(key)

def validate_file(source: Path):
    text = source.read_text(encoding="utf-8")
    frontmatter_lines = extract_frontmatter(text, source)
    assert_parses_as_yaml(frontmatter_lines, source)
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

    if "external_refs" in data:
        validate_external_refs(source, data["external_refs"])
    validate_external_refs_declined(source, data)

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
        # jenga_assigned: false asserts a human overrode the machine-assigned scope, and
        # templates/SCRUM_BOARD_SCHEMA.md makes override_justification required in that case.
        # Enforced rather than left to authoring discipline because the empty pairing is not
        # merely untidy: skills/j-do/SKILL.md's step 4.1 HALTS the dispatch on it, so the task
        # cannot be worked at all. 35 task files accumulated the combination unnoticed before
        # this check existed, 16 of them still Pending and therefore still undispatchable.
        if str(data.get("jenga_assigned", "")).strip().lower() == "false" \
                and not str(data.get("override_justification", "")).strip():
            raise ValueError(
                f"{source}: jenga_assigned: false requires a non-empty override_justification "
                "(templates/SCRUM_BOARD_SCHEMA.md). /do step 4.1 halts dispatch on this pairing. "
                "If the scope was machine-assigned, set jenga_assigned: true instead."
            )

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

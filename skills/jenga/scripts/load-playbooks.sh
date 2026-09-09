#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/load-playbooks.sh
#
# Deterministic loader for `/jenga`'s multi-skill PLAYBOOK catalog (E53_S02_T01) — the SINGLE
# REQUIRED SOURCE of playbook data for E53_S02_T02's `match-playbook.sh` and E53_S02_T04's wiring
# into `skills/jenga/SKILL.md`. Neither of those may re-scan `skills/jenga/playbooks/` or
# hand-maintain a playbook list of their own; they only ever invoke this script and read its
# stdout, mirroring the single-source contract `load-nl-catalog.sh` already established for the
# single-skill catalog (E53_S01_T02).
#
# A "playbook" is an ORDERED chain of steps (e.g. brainstorm -> todo -> do -> dev-done ->
# mirror-public) that `/jenga`'s natural-language branch may propose, as an editable, confirmable
# numbered list (see `render-playbook-confirmation.sh`, E53_S02_T03), when free-text intent spans
# more than one skill and does not cleanly resolve to a single one.
#
# ---------------------------------------------------------------------------
# STEP SHAPES (E53_S03_T01 — Playbooks v2)
# ---------------------------------------------------------------------------
# Each entry in a playbook's `steps` array may be either:
#
#   - a BARE STRING — unchanged, original behavior. Shorthand for `{"skill": "<string>"}`. No
#     migration needed: an all-bare-string playbook (e.g. the committed `brainstorm-to-mirror.json`)
#     loads byte-for-byte the same as before this task, including in this script's own JSON
#     output — a bare-string step is never rewritten into an object in the catalog. This is a
#     deliberate backward-compatibility choice: `match-playbook.sh`, `render-playbook-confirmation.sh`,
#     and `run-playbook-step.sh` (all from E53_S02) consume `steps` as a comma-joinable list of
#     plain skill-name strings and are NOT updated by this story to understand StepObjects — that
#     downstream wiring is future work (E53_S04-S06). A playbook that uses any StepObject step is
#     therefore validated and cataloged by this script, but is not yet safely executable through
#     the E53_S02 runner chain.
#
#   - a STepObject (a JSON object) — `{"skill": "<string>"}` OR `{"playbook": "<string>"}`,
#     mutually exclusive (a step naming both, or naming neither, is a validation error — see
#     below), plus all of the following OPTIONAL fields, each validated only for shape at this
#     point in the pipeline (cross-step/cross-file validation of `forward_from` and `resolve` is
#     added by `E53_S03_T03`/`E53_S03_T04` — see that section of this header once present):
#       - `instruction`  (string) — static natural-language text appended to this step's own
#                                    invocation message.
#       - `forward_from` (string) — names a prior step this step's invocation input is drawn from.
#       - `resolve`      (string) — natural-language instructions for reshaping/filtering/
#                                    type-bridging a forwarded value.
#       - `version` / `schema_version` (any type, either key name) — RESERVED. Accepted verbatim,
#                                    passed through into the catalog unchanged, and never acted
#                                    upon by this script. Exists purely so a future schema revision
#                                    has a place to declare itself without every existing playbook
#                                    file needing a retroactive migration.
#
# ---------------------------------------------------------------------------
# FORWARD_FROM RESOLUTION (E53_S03_T03, extended by E53_S03_T04)
# ---------------------------------------------------------------------------
# A step whose StepObject carries `forward_from: "<name>"` is validated as follows, entirely at
# load time, entirely from this repository's own files on disk:
#
#   1. EXISTENCE — `<name>` must equal the skill name of some EARLIER step in the same playbook's
#      `steps` array (a bare string equal to `<name>`, or a StepObject whose `skill` field equals
#      `<name>`; a `playbook`-type step never satisfies this, since it has no single skill name).
#      If no earlier step matches, the playbook is rejected.
#
#   2. DECLARED OUTPUT — the source skill's own `skills/<name>/SKILL.md` frontmatter must declare
#      a non-empty `output_types` field (see `docs/skill-authoring.md`'s `output_types` section,
#      E53_S03_T02). A skill with no declared `output_types` cannot be a forward source — this is
#      the design's partial-adoption rule (`templates/playbook-types.json`, E53_S03_T02) made
#      load-time-enforced: only `j.status`, `j.uncharted`, `j.jenga`, and `j.reconcile` declare it
#      as of this story. If the source has no declared `output_types`, the playbook is rejected.
#
#   3. BLOCKER 1'S STRUCTURAL {when, type} CHECK (E53_S03_T04) — applies only when the source's
#      `output_types` is the list-of-`{when, type}` form (as opposed to a single static type
#      string). For each `{when, type}` entry:
#        - both `when` and `type` must be present, or the playbook is rejected.
#        - if `when` is one of the two BUILT-IN predicates (`argument_empty` / `argument_nonempty`),
#          no further check is made here — those predicates describe the STEP's own invocation
#          shape, not a separate classifier, and are accepted as-is.
#        - otherwise `when` is a CLASSIFIER-SCRIPT REFERENCE (e.g. `j.jenga`'s own `when:
#          detect-nl-intent`, referencing `skills/jenga/scripts/detect-nl-intent.sh`). This is
#          exactly the ambiguity Blocker 1 of
#          `project/documentation/plans/e53-playbooks-v2-extension-plan.md` identified: a
#          classifier script's ACTUAL runtime result (which branch fires) can only be known by
#          running it against a real argument, which this loader never does and never will. What
#          IS load-time-knowable, and the only claim this check ever makes, is purely structural:
#          does a script matching that reference actually exist on disk
#          (`skills/<name>/scripts/<when>.sh`)? If not, the reference is bogus and the playbook is
#          rejected. If the script exists, the claim this loader makes to the rest of the system is
#          exactly: "IF this classifier-based source step continues at all (produces any output
#          rather than halting), its declared type is `<type>`" — never "we know in advance which
#          branch will fire". Traced end-to-end against `skills/jenga/scripts/detect-nl-intent.sh`
#          and `skills/jenga/SKILL.md`'s Phase 0.75 "Entry Mode Resolution": `detect-nl-intent.sh`
#          exits 0 on both its `all_resolved` and `nl_intent` classifications (both produce real,
#          forwardable output) and exits 1 only on `mixed`, which Phase 0.75 already halts on
#          before any forwarding could occur. So "the source's declared type guarantees non-empty
#          output whenever forwarding actually happens" is an honest claim to make purely from
#          `detect-nl-intent.sh`'s and Phase 0.75's own documented contracts — this loader never
#          invokes either of them to make it. `detect-nl-intent.sh` and Phase 0.75 are themselves
#          entirely unmodified by this story.
#
# ---------------------------------------------------------------------------
# CONFIRMATION-GATE CONVENTION (E53_S03_T03 — Blocker 2 v1 scope cut, load-time half)
# ---------------------------------------------------------------------------
# The design's Blocker 2 (see the plan doc's Open Decisions) splits `resolve` into two stories:
# this one ships `resolve` for reshaping/filtering/type-bridging a forwarded value ONLY, never for
# pre-authorizing a downstream confirmation gate — that combination is explicitly out of scope and
# rejected here, at load time. `E53_S06` owns `resolve`'s own runtime behavior; this is only the
# load-time rejection rule.
#
# This script's load-time convention for what counts as a "downstream confirmation gate": a
# `{"playbook": "<id>"}` step. Entering ANY nested playbook always passes through that playbook's
# own up-front `render-playbook-confirmation.sh` confirmation (E53_S02_T03) before any of its
# steps run — a playbook-type step therefore IS a confirmation gate by construction, in every
# case, with no exceptions to enumerate. A step that carries BOTH `resolve` and `playbook` is
# rejected: `resolve` may only ever shape a value flowing into an ordinary `skill` step.
#
# ---------------------------------------------------------------------------
# DATA SOURCE
# ---------------------------------------------------------------------------
# Every `*.json` file directly under `skills/jenga/playbooks/`, EXCLUDING `schema.json` (which
# documents the required shape — see that file's own header — but is never itself a playbook
# entry). See `schema.json` for the authoritative field list; this script's validation below is
# a runtime mirror of that schema, not a substitute for it.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   skills/jenga/scripts/load-playbooks.sh
#
# No arguments. Emits the full JSON playbook catalog array to stdout.
#
# TESTING OVERRIDE — JENGA_PLAYBOOKS_TEST_ROOT (E53_S03_T05): when this environment variable is
# set, it overrides the monorepo/node_modules PKG_ROOT auto-detection below, pointing
# PLAYBOOKS_DIR/SKILLS_DIR at `<value>/skills/jenga/playbooks` and `<value>/skills` respectively.
# This exists exclusively so `tests/load-playbooks-stepobject.bats` can point this loader at a
# synthetic, throwaway fixture tree under `$BATS_TEST_TMPDIR` instead of this repository's own
# `skills/` — per this repo's fixture-tree testing convention, a test asserting on candidate sets
# never targets the repository root. Never set this variable in a real invocation.
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# stdout is a single JSON array, one object per valid playbook:
#
#   [
#     {
#       "id":          "brainstorm-to-mirror",
#       "name":        "Idea to Public Release",
#       "description": "...",
#       "keywords":    ["..."],
#       "examples":    ["..."],
#       "steps":       ["brainstorm", "todo", "do", "dev-done", "mirror-public"]
#     },
#     ...
#   ]
#
# `steps` entries are emitted exactly as validated: a bare string stays a bare string; a
# StepObject is emitted as an object carrying only its recognized fields (`skill` XOR `playbook`,
# plus whichever of `instruction`/`forward_from`/`resolve`/`version`/`schema_version` were present
# on the source step).
#
# Nothing but this JSON array is ever written to stdout. Skip warnings go to stderr only and are
# non-fatal — a single malformed playbook file never aborts the whole catalog load.
#
# ---------------------------------------------------------------------------
# VALIDATION / SKIP CONDITIONS (each skip is a stderr warning, never fatal — the WHOLE playbook is
# skipped on any of these, never just the offending step, consistent with this script's existing
# "a chain with a broken link is not a usable chain" skip granularity)
# ---------------------------------------------------------------------------
#   - File is not valid JSON, or is not a JSON object                      -> skipped
#   - Missing any required field: id, name, description, keywords,
#     examples, steps                                                     -> skipped
#   - `keywords`, `examples`, or `steps` present but empty (or not a
#     list)                                                                -> skipped
#   - `id` does not equal the filename's basename without `.json`          -> skipped
#     (prevents a playbook's identity from silently drifting from its
#     file location)
#   - A `steps` entry is neither a string nor an object, or is an empty
#     string                                                               -> skipped
#   - A StepObject step carries BOTH `skill` and `playbook`, or NEITHER    -> skipped
#   - A StepObject's `skill`/`playbook`/`instruction`/`forward_from`/
#     `resolve` field is present but not a non-empty string                -> skipped
#   - Any `skill`-type step (bare string or StepObject) has no
#     corresponding `skills/<name>/SKILL.md` on disk                       -> skipped
#     (`playbook`-type step existence/cycle-detection is E53_S05's scope — not checked here)
#   - A `forward_from` names a step that is not an EARLIER step in the
#     same playbook                                                        -> skipped
#   - A `forward_from` names a source step whose skill has no declared
#     `output_types` in its own `SKILL.md` frontmatter                     -> skipped
#   - A `forward_from` source's `output_types` list has a `{when, type}`
#     entry missing `when`/`type`, or a classifier-script `when` with no
#     matching `skills/<name>/scripts/<when>.sh` on disk (Blocker 1,
#     E53_S03_T04)                                                         -> skipped
#   - A step carries both `resolve` and `playbook` (resolve targeting a
#     downstream confirmation gate — Blocker 2 v1 scope cut, E53_S03_T03)  -> skipped
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   catalog written to stdout (possibly with skip warnings already emitted to stderr;
#       an empty catalog `[]` is a valid, non-error outcome — e.g. every playbook file was
#       malformed, or no playbook files exist yet beyond schema.json)
#   2   usage error, or a real setup failure (playbooks directory missing entirely, or
#       python3 unavailable)
#
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${JENGA_PLAYBOOKS_TEST_ROOT:-}" ]; then
  # Test-only override — see "TESTING OVERRIDE" in the header above (E53_S03_T05). Never set in
  # a real invocation.
  PKG_ROOT="$JENGA_PLAYBOOKS_TEST_ROOT"
# Resolve the jenga-agent PACKAGE root (where the canonical skills/ tree actually lives) — same
# monorepo-checkout vs. installed-npm-package detection used by
# skills/jenga/scripts/load-nl-catalog.sh's PKG_ROOT resolution and skills/init/scripts/init.sh.
elif [ -d "$SCRIPT_DIR/../../../templates" ]; then
  PKG_ROOT="$SCRIPT_DIR/../../.."
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent/templates" ]; then
  PKG_ROOT="${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent"
else
  echo "Error: could not locate the jenga-agent package root (templates/ not found via monorepo checkout or node_modules/@jenga-ai/agent)." >&2
  exit 2
fi

PLAYBOOKS_DIR="$PKG_ROOT/skills/jenga/playbooks"
SKILLS_DIR="$PKG_ROOT/skills"

if [ ! -d "$PLAYBOOKS_DIR" ]; then
  echo "Error: playbooks directory not found at $PLAYBOOKS_DIR" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by load-playbooks.sh" >&2
  exit 2
fi

PY_SCRIPT="$(mktemp -t load-playbooks-XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PY'
import json
import os
import re
import sys

playbooks_dir = sys.argv[1]
skills_dir = sys.argv[2]

REQUIRED_FIELDS = ["id", "name", "description", "keywords", "examples", "steps"]
LIST_FIELDS = ["keywords", "examples", "steps"]

# Optional StepObject fields that must be non-empty strings when present.
STEP_STRING_FIELDS = ("instruction", "forward_from", "resolve")
# Reserved, currently-unused StepObject fields -- accepted verbatim, never validated or acted
# upon (E53_S03_T01).
STEP_RESERVED_FIELDS = ("version", "schema_version")

# The two built-in {when, type} predicates every skill may use without naming a classifier
# script. Any other `when` value is a classifier-script reference (E53_S03_T04's Blocker 1
# check).
BUILTIN_WHEN_PREDICATES = {"argument_empty", "argument_nonempty"}

catalog = []


def normalize_step(entry, idx):
    """Validate and normalize one `steps` entry. Returns (normalized_step, error_or_None)."""
    if isinstance(entry, str):
        if entry == "":
            return None, f"step {idx} is an empty string"
        return entry, None

    if not isinstance(entry, dict):
        return None, f"step {idx} is neither a string nor an object"

    has_skill = "skill" in entry
    has_playbook = "playbook" in entry
    if has_skill and has_playbook:
        return None, f"step {idx} has both 'skill' and 'playbook' (mutually exclusive)"
    if not has_skill and not has_playbook:
        return None, f"step {idx} has neither 'skill' nor 'playbook' (a StepObject requires exactly one)"

    out = {}
    target_field = "skill" if has_skill else "playbook"
    target_value = entry[target_field]
    if not isinstance(target_value, str) or not target_value:
        return None, f"step {idx} '{target_field}' must be a non-empty string"
    out[target_field] = target_value

    for field in STEP_STRING_FIELDS:
        if field in entry:
            value = entry[field]
            if not isinstance(value, str) or not value:
                return None, f"step {idx} '{field}' must be a non-empty string"
            out[field] = value

    for field in STEP_RESERVED_FIELDS:
        if field in entry:
            # Reserved, no-op: accepted and passed through verbatim, no type check.
            out[field] = entry[field]

    return out, None


def step_skill_name(step):
    """The skill name a step resolves to for forward_from-source matching, or None for a
    playbook-type step (which has no single skill name to match against)."""
    if isinstance(step, str):
        return step
    if isinstance(step, dict) and "skill" in step:
        return step["skill"]
    return None


_FRONTMATTER_RE = re.compile(r'^---\r?\n(.*?)\r?\n---', re.DOTALL)


def extract_output_types(skill_md_path):
    """Best-effort extraction of the `output_types` frontmatter field from a SKILL.md.

    Returns None if the file/field is missing or unparseable, a `str` for the single-static-type
    form, or a `list[dict]` for the `{when, type}` list form. This is a small, targeted parser for
    this repository's own hand-authored frontmatter shape -- not a general YAML parser -- mirroring
    the existing precedent of purpose-built frontmatter extraction over pulling in a YAML
    dependency (see lib/generate-skill-allow-list.js's extractName()).
    """
    try:
        with open(skill_md_path, encoding="utf-8") as fh:
            content = fh.read()
    except OSError:
        return None

    fm_match = _FRONTMATTER_RE.match(content)
    if not fm_match:
        return None

    fm_lines = fm_match.group(1).splitlines()

    for i, line in enumerate(fm_lines):
        key_match = re.match(r'^output_types:\s*(.*)$', line)
        if not key_match:
            continue

        rest = key_match.group(1).strip()
        if rest:
            return rest.strip('"\'')

        # Block/list form: gather subsequent, more-indented lines into a list of dicts.
        items = []
        current = {}
        j = i + 1
        while j < len(fm_lines):
            raw_line = fm_lines[j]
            if not raw_line.strip():
                j += 1
                continue
            if not raw_line[0].isspace():
                break  # a new top-level frontmatter key ends this block

            stripped = raw_line.strip()
            item_match = re.match(r'^-\s*(.*)$', stripped)
            if item_match:
                if current:
                    items.append(current)
                current = {}
                remainder = item_match.group(1)
                kv = re.match(r'^([a-zA-Z_]+):\s*(.*)$', remainder) if remainder else None
                if kv:
                    current[kv.group(1)] = kv.group(2).strip().strip('"\'')
            else:
                kv = re.match(r'^([a-zA-Z_]+):\s*(.*)$', stripped)
                if kv:
                    current[kv.group(1)] = kv.group(2).strip().strip('"\'')
            j += 1

        if current:
            items.append(current)
        return items if items else None

    return None


try:
    filenames = sorted(
        f for f in os.listdir(playbooks_dir)
        if f.endswith(".json") and f != "schema.json"
    )
except OSError as e:
    print(f"Error: could not list {playbooks_dir}: {e}", file=sys.stderr)
    sys.exit(2)

for filename in filenames:
    path = os.path.join(playbooks_dir, filename)
    basename = filename[: -len(".json")]

    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        print(f"Warning: {path} is not valid JSON ({e}) — skipped", file=sys.stderr)
        continue

    if not isinstance(data, dict):
        print(f"Warning: {path} is not a JSON object — skipped", file=sys.stderr)
        continue

    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        print(f"Warning: {path} missing required field(s) {missing} — skipped", file=sys.stderr)
        continue

    bad_list = [
        f for f in LIST_FIELDS
        if not isinstance(data.get(f), list) or len(data.get(f)) == 0
    ]
    if bad_list:
        print(f"Warning: {path} field(s) {bad_list} must be non-empty lists — skipped", file=sys.stderr)
        continue

    if data["id"] != basename:
        print(
            f"Warning: {path} has id '{data['id']}' which does not match its filename "
            f"'{basename}.json' — skipped",
            file=sys.stderr,
        )
        continue

    # --- E53_S03_T01: StepObject shape acceptance + bare-string back-compat ---
    normalized_steps = []
    step_error = None
    for idx, raw_step in enumerate(data["steps"]):
        normalized, err = normalize_step(raw_step, idx)
        if err:
            step_error = err
            break
        normalized_steps.append(normalized)

    if step_error:
        print(f"Warning: {path} {step_error} — skipped", file=sys.stderr)
        continue

    # Existence check for skill-type steps only (bare string, or StepObject with `skill`).
    # `playbook`-type step existence/cycle-detection is E53_S05's scope, not this script's.
    skill_names_to_check = [
        name for name in (step_skill_name(s) for s in normalized_steps)
        if name is not None
    ]
    missing_skills = [
        name for name in skill_names_to_check
        if not os.path.isfile(os.path.join(skills_dir, name, "SKILL.md"))
    ]
    if missing_skills:
        print(
            f"Warning: {path} references nonexistent skill(s) {missing_skills} "
            f"(no skills/<name>/SKILL.md found) — playbook skipped",
            file=sys.stderr,
        )
        continue

    # --- E53_S03_T03: forward_from resolution + resolve/confirmation-gate rejection ---
    validation_error = None
    for idx, step in enumerate(normalized_steps):
        if not isinstance(step, dict):
            continue

        if "resolve" in step and "playbook" in step:
            validation_error = (
                f"step {idx} has 'resolve' targeting a playbook-composition step "
                f"('{step['playbook']}'), which is always a downstream confirmation gate "
                f"(see header 'CONFIRMATION-GATE CONVENTION') — 'resolve' may never target one"
            )
            break

        if "forward_from" not in step:
            continue

        source_name = step["forward_from"]
        earlier_names = [step_skill_name(s) for s in normalized_steps[:idx]]
        if source_name not in earlier_names:
            validation_error = (
                f"step {idx} 'forward_from' names '{source_name}', which is not an earlier "
                f"skill step in this playbook"
            )
            break

        source_skill_md = os.path.join(skills_dir, source_name, "SKILL.md")
        output_types_val = extract_output_types(source_skill_md)
        if not output_types_val:
            validation_error = (
                f"step {idx} 'forward_from' names '{source_name}', which has no declared "
                f"output_types in its SKILL.md frontmatter"
            )
            break

        # --- E53_S03_T04: Blocker 1's structural {when, type} check ---
        if isinstance(output_types_val, list):
            for ot_entry in output_types_val:
                when_val = ot_entry.get("when") if isinstance(ot_entry, dict) else None
                type_val = ot_entry.get("type") if isinstance(ot_entry, dict) else None
                if not when_val or not type_val:
                    validation_error = (
                        f"step {idx} forward_from source '{source_name}' declares a malformed "
                        f"output_types entry (missing 'when' or 'type')"
                    )
                    break
                if when_val not in BUILTIN_WHEN_PREDICATES:
                    # `when` names a classifier script. Only its EXISTENCE is checkable at load
                    # time -- never its actual runtime result. See header 'FORWARD_FROM
                    # RESOLUTION' step 3 for the full reasoning behind this structural claim.
                    classifier_script = os.path.join(skills_dir, source_name, "scripts", f"{when_val}.sh")
                    if not os.path.isfile(classifier_script):
                        validation_error = (
                            f"step {idx} forward_from source '{source_name}' declares output_types "
                            f"with classifier-script when '{when_val}' but no script exists at "
                            f"skills/{source_name}/scripts/{when_val}.sh"
                        )
                        break
            if validation_error:
                break

    if validation_error:
        print(f"Warning: {path} {validation_error} — skipped", file=sys.stderr)
        continue

    catalog.append({
        "id": data["id"],
        "name": data["name"],
        "description": data["description"],
        "keywords": data["keywords"],
        "examples": data["examples"],
        "steps": normalized_steps,
    })

print(json.dumps(catalog, indent=2))
PY

python3 "$PY_SCRIPT" "$PLAYBOOKS_DIR" "$SKILLS_DIR"
exit $?

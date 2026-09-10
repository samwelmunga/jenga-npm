#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/jenga/scripts/run-playbook-step.sh
#
# Deterministic step-SEQUENCING state tracker for a confirmed playbook chain (E53_S02_T03). This
# script does NOT execute a skill step itself — invoking a skill's `SKILL.md` instructions (and,
# where applicable, loading `agents/<prefered_agent>.md`) is inherently the calling agent's job
# and cannot live in a shell script. What belongs in a script, per `CLAUDE.md`'s Skill
# Implementation Principle, is the deterministic bookkeeping around that: which step is current,
# which have completed, which have failed, and enforcing that a failure halts the sequence
# permanently with no silent skip-ahead — exactly the story's acceptance criterion for mid-chain
# failure handling. Conditional predicate EVALUATION (E53_S04_T02) is the same kind of
# deterministic bookkeeping — it belongs here too, never as inline `SKILL.md` reasoning.
#
# `/jenga`'s natural-language branch (wired in E53_S02_T04, extended by E53_S04_T07) uses this
# script as follows, after `render-playbook-confirmation.sh` (E53_S02_T03) returns a `confirmed`
# result:
#
#   1. `init` with the confirmed, ordered step list (and, optionally, per-step conditional
#      metadata — see CONDITIONALS below) -> get the first step to invoke.
#   2. `should-skip <state_file>` -> deterministically decide whether the CURRENT step should run.
#      - `{"skip": true, ...}`  -> do NOT invoke the step; call `advance <state_file> skipped`.
#      - `{"skip": false, ...}` -> invoke the step (as `/route`'s Step 6 already does for a single
#        matched skill), then call `advance <state_file> passed ["<typed-output-value>"]` (step
#        succeeded) or `advance <state_file> failed [note]` (step failed).
#   3. Any of the three `advance` outcomes returns the next step, a "complete" signal, or (on
#      failure) a halt report.
#   4. Repeat 2-3 until "complete" or a halt report is returned.
#
# A `forward_from` step (E53_S03) resolves its actual invocation input via
# `get-output <state_file> <step_name>` (see GET-OUTPUT below) before being invoked in step 2.
#
# ---------------------------------------------------------------------------
# CAPTURED TYPED-OUTPUT ARTIFACTS (E53_S04_T01)
# ---------------------------------------------------------------------------
# `forward_from` (E53_S03) and conditional step execution (E53_S04_T02) both need a single,
# shared record of "what typed output did step X actually produce when it ran" -- this is that
# record, and there is no second, separate capture path. Every step that produces a forwardable
# typed output value (per its own `output_types` declaration, see `docs/skill-authoring.md`)
# reports that value on its `advance ... passed` call; this script stores it in the state file's
# `captured_outputs` map, keyed by the step name that just completed. A step with no typed output
# to report simply omits the argument -- `captured_outputs` only ever gains entries for steps that
# actually supplied a value. A `skipped` step (see CONDITIONALS below) never runs, so it can never
# populate `captured_outputs` for itself either -- see GET-OUTPUT for the defined failure mode this
# causes for a downstream `forward_from` that names a skipped step.
#
# ---------------------------------------------------------------------------
# CONDITIONALS AND THE `skipped` STATUS (E53_S04_T02)
# ---------------------------------------------------------------------------
# A step may declare a conditional predicate, evaluated against a NAMED PRIOR STEP's captured
# typed-output artifact (the same `captured_outputs` map above), that determines whether it
# executes. `init`'s optional 4th argument carries this metadata (see USAGE); a step absent from
# that map has no conditional and always runs, exactly as before this task.
#
# PREDICATE GRAMMAR (the simplest grammar that satisfies "evaluated against a named prior step's
# captured typed-output artifact" -- documented here as the single source of truth; playbook
# authors declare it via `load-playbooks.sh`'s StepObject `conditional` field, see that script's
# own header):
#
#   non_empty          true if the depended-on step's captured output is a non-empty string
#   empty               true if the depended-on step's captured output is absent or an empty string
#   equals:<value>       true if the captured output string equals <value> exactly
#   not_equals:<value>   true if the captured output string does NOT equal <value> exactly
#
# A depended-on step with NO captured output at all (never ran, ran but reported no value, or was
# itself skipped) is treated as an empty string for evaluation purposes -- `empty` matches,
# `non_empty` does not, `equals:<anything-nonblank>` does not, `not_equals:<anything-nonblank>`
# does.
#
# `should-skip <state_file>` evaluates the CURRENT step's conditional (if any) and reports whether
# it should be skipped, WITHOUT mutating the state file or advancing anything -- pure evaluation.
# The calling agent then either invokes the step normally, or calls `advance <state_file> skipped`
# directly without ever invoking the step. A `skipped` step is recorded in a `skipped` list
# (distinct from `completed`), advances the pointer exactly like `passed`, and NEVER halts the
# chain -- it is non-blocking, non-failing, per the story's explicit requirement.
#
# ---------------------------------------------------------------------------
# COMPOSED/NESTED STEP HANDLING (E53_S05_T04)
# ---------------------------------------------------------------------------
# A composed/nested playbook chain (built by `load-playbooks.sh`'s composition resolution,
# E53_S05_T01) arrives here already fully flattened into ONE ordered `steps` list before it is ever
# passed to `init` -- this script never sees a raw `{"playbook": ...}` reference, only a flat,
# comma-separated list of step names, exactly as it already did before this story. Consequently the
# sequencing/halt state machine required ZERO behavioral changes: it was already format-agnostic to
# where each step name originated.
#
# The only addition is bookkeeping/traceability: `init`'s optional 5th argument (`<json-origins>`,
# see USAGE) stores per-step `{"playbook_id": ..., "depth": N}` metadata verbatim in the state
# file's `origins` map. This map is a PURE PASSTHROUGH -- no subcommand in this script (`init`,
# `should-skip`, `advance`, `get-output`) ever reads or branches on it. In particular:
#   - HALT-ON-FAILURE is origin-agnostic: `advance <state_file> failed` halts the entire chain
#     based purely on `current_index` -- a step's origin plays no role in this decision. Verified
#     against a manually constructed composed scenario (three steps, the middle one tagged with
#     `origins` metadata, `failed` called on it): the chain halted exactly as it would for an
#     un-composed chain, with `failed_step` correctly naming the composed step and `never_run`
#     correctly listing everything after it.
#   - REPORTING SHAPES are unaffected: `completed`/`skipped`/`failed_step`/`failed_note`/`never_run`
#     never include or omit anything based on `origins` -- their shape is identical whether or not
#     any step in the run has an `origins` entry.
#   - `should-skip`/`get-output`/`captured_outputs` addressing is unaffected: all three already key
#     purely off step NAME (`current_step`/`step_name`), never consulting `origins` at all.
#
# ---------------------------------------------------------------------------
# ARTIFACT PERSISTENCE AND REDACTION POLICY (E53_S04_T05)
# ---------------------------------------------------------------------------
# Every captured typed-output VALUE (a `passed` advance call that supplies one -- the exact same
# data `captured_outputs` holds, no new data captured by this policy) is ALSO persisted to a
# per-run log file, separate from the ephemeral temp state file:
#
#   project/logs/playbook-runs/<run_id>/artifacts.jsonl
#
# `<run_id>` (`<UTC-timestamp>-<playbook_id>-<8-hex>`) is generated once at `init` and stored in
# the state file; every `advance` call re-derives the same directory path from it. This reuses this
# repository's existing per-run/per-event JSON-LINES logging convention (the same append-one-line
# format `project/queue/scrum_triggers.jsonl` already uses) rather than inventing a new format.
# Each line is one JSON object: `{"step": "<name>", "captured_at": "<iso8601>", "value":
# "<redacted-or-original>"}`.
#
# PROJECT ROOT RESOLUTION mirrors `scripts/write-context-digest.sh`'s existing probing order:
# `JENGA_PROJECT_DIR` -> `CLAUDE_PROJECT_DIR` -> `git rev-parse --show-toplevel` -> `pwd`.
#
# TESTING OVERRIDE -- `JENGA_PLAYBOOK_RUNS_TEST_ROOT`: when set, overrides the project-root
# resolution above for this persistence path only (mirrors `load-playbooks.sh`'s own
# `JENGA_PLAYBOOKS_TEST_ROOT` convention). Fixture tests always set this to a throwaway
# `$BATS_TEST_TMPDIR` location -- never to this repository's own `project/logs/`.
#
# REDACTION (narrow, documented, BEST-EFFORT -- not exhaustive, not a guarantee) is applied ONLY to
# the PERSISTED copy, before it is written to `artifacts.jsonl`:
#   - an absolute path OUTSIDE the resolved project root -> replaced with `[REDACTED_ABS_PATH]`
#   - an email-address-shaped substring                  -> replaced with `[REDACTED_EMAIL]`
#   - a phone-number-shaped digit sequence                -> replaced with `[REDACTED_PHONE]`
# The LIVE `captured_outputs` value inside the temp state file is NEVER redacted -- `should-skip`
# and `get-output` need the real, unredacted value to evaluate predicates and resolve
# `forward_from` correctly. Redaction is a persistence-time-only transform on a separate copy of
# the data, never a mutation of the functional state.
#
# RETENTION/ROTATION POSTURE: identical to `project/logs/events.json`'s own actual current
# posture -- append-only, unbounded growth, no automatic deletion or rotation of old run
# directories. This is a deliberate, documented BEST-EFFORT policy, not a guarantee of bounded
# storage or of redaction completeness -- a narrow initial pattern set will not catch every
# possible sensitive value.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   run-playbook-step.sh init "<playbook_id>" "<name>" "<comma-separated confirmed step names>" ["<json-conditionals>" ["<json-origins>"]]
#       Starts a new run. Creates a state file tracking the ordered step list, a current-step
#       pointer (starts at the first step), an empty `captured_outputs` map, empty
#       completed/skipped/failed lists, and (if given) per-step conditional metadata and origin
#       metadata. Emits the first step's info as JSON on stdout and a `STATE_FILE:` path on stderr.
#
#       `<json-conditionals>` is OPTIONAL. When given, it is a JSON object mapping step name ->
#       `{"depends_on": "<earlier step name>", "predicate": "<predicate>"}` for ONLY the steps
#       that carry a conditional (steps absent from the object always run). Example:
#         '{"stepC": {"depends_on": "stepA", "predicate": "non_empty"}}'
#       Omitting this argument entirely (a 3-arg `init` call, E53_S04_T01's original form) means no
#       step in this run carries a conditional -- fully backward compatible.
#
#       `<json-origins>` is OPTIONAL (E53_S05_T04), and may only be given when `<json-conditionals>`
#       is also given (pass `"{}"` for conditionals if there are none, to reach the 5th slot). It is
#       a JSON object mapping a composed/nested step's name -> `{"playbook_id": "...", "depth": N}`,
#       mirroring `render-playbook-confirmation.sh`'s own `<json-origins>` argument (E53_S05_T03).
#       Stored verbatim in the state file's `origins` map -- a PURE PASSTHROUGH annotation, never
#       read or branched on by ANY subcommand in this script (see "COMPOSED/NESTED STEP HANDLING"
#       below). Omitting this argument reproduces the exact pre-this-task behavior, fully backward
#       compatible.
#
#   run-playbook-step.sh should-skip <state_file>
#       Deterministically evaluates the CURRENT step's conditional against `captured_outputs`.
#       Does NOT mutate the state file or advance the pointer -- pure evaluation, safe to call
#       repeatedly. Emits, on stdout:
#         {"skip": false, "step": "<name>"}                                  (no conditional, or it evaluated true)
#         {"skip": true,  "step": "<name>", "depends_on": "...", "predicate": "...", "observed_value": "..." }
#
#   run-playbook-step.sh advance <state_file> passed ["<typed-output-value>"]
#       Records the CURRENT step as completed and advances the pointer. If a typed-output value is
#       given, it is stored in `captured_outputs[<current step name>]` before advancing -- this
#       argument is OPTIONAL; omitting it (a step with no declared output type) leaves
#       `captured_outputs` untouched for that step and behaves exactly as before this argument
#       existed. If more steps remain, emits the next step's info as JSON (same shape as `init`'s
#       stdout). If that was the last step, emits a completion report instead (see OUTPUT SCHEMA)
#       and removes the state file.
#
#   run-playbook-step.sh advance <state_file> skipped
#       Records the CURRENT step as SKIPPED (a new `skipped` list, distinct from `completed`) and
#       advances the pointer exactly like `passed` -- a skipped step never halts the chain and is
#       treated as non-blocking, non-failing. No typed-output value is ever accepted for `skipped`
#       (the step never ran, so it has nothing to report). Same next-step/`complete` result shape
#       as `passed`, except the `complete`/`step_ready` bookkeeping now also reflects the `skipped`
#       list (see OUTPUT SCHEMA).
#
#   run-playbook-step.sh advance <state_file> failed ["<note>"]
#       Records the CURRENT step as failed (optionally with a free-text note) and halts the
#       sequence PERMANENTLY — the state file is marked `halted: true` rather than removed, so a
#       further `advance` call against it is rejected (see EXIT CODES). Emits a halt report (see
#       OUTPUT SCHEMA) listing completed / skipped / failed / never-run steps. (The optional 3rd
#       argument means something different per outcome: a typed-output VALUE for `passed`, a
#       free-text NOTE for `failed`, and is not accepted at all for `skipped` -- never ambiguous,
#       since only one outcome word is given per call.)
#
#   run-playbook-step.sh get-output <state_file> <step_name>
#       Looks up `captured_outputs[<step_name>]` for a `forward_from` step to resolve its actual
#       invocation input. Emits, on stdout, one of:
#         {"status": "found", "step": "<step_name>", "value": "<value>"}
#         {"status": "unavailable", "step": "<step_name>", "reason": "step_skipped"}
#         {"status": "unavailable", "step": "<step_name>", "reason": "not_captured"}
#       `reason: step_skipped` is the DEFINED, DOCUMENTED failure mode for "a skipped step followed
#       by a step that attempts to forward_from it" (E53_S04_T06 fixture-covers this exact case) --
#       this is never silently treated as an empty string; the calling agent must decide how to
#       handle an unavailable forward source (e.g. halt the chain via `advance ... failed`).
#       `reason: not_captured` covers every other case: the named step hasn't run yet, ran but
#       reported no typed-output value, or does not exist in this run's step list at all.
#
# ---------------------------------------------------------------------------
# OUTPUT SCHEMA
# ---------------------------------------------------------------------------
# `init` and a `passed`/`skipped` `advance` call that has more steps remaining both emit, on
# stdout:
#
#   {"status": "step_ready", "step": "<skill name>", "step_index": 2, "total_steps": 5}
#
# A `passed`/`skipped` `advance` call on the FINAL step emits, on stdout (state file removed):
#
#   {"status": "complete", "playbook_id": "...", "name": "...",
#    "completed": ["<step1>", ...], "skipped": ["<step2>", ...]}
#
# A `failed` `advance` call emits, on stdout (state file retained, marked halted):
#
#   {"status": "halted", "playbook_id": "...", "name": "...",
#    "completed": ["<step1>", ...], "skipped": ["<step2>", ...], "failed_step": "<stepN>",
#    "failed_note": "<note or null>", "never_run": ["<stepN+1>", ...]}
#
# Nothing else is ever written to stdout — errors/warnings go to stderr only.
#
# `captured_outputs` itself is internal state-file bookkeeping, never emitted directly on stdout by
# `init`/`advance` -- a consumer that needs a captured value (e.g. a `forward_from` step resolving
# its input) reads it back via `get-output` (see USAGE above).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   `init` succeeded; OR `should-skip` succeeded (regardless of its `skip` verdict — a `true`
#       verdict is a normal, expected outcome, not an error); OR `advance passed`/`advance skipped`
#       succeeded (whether it returned the next step or a "complete" report); OR `advance failed`
#       succeeded in recording the halt (a "halted" report IS the expected, successful outcome of
#       this call — exit 0, not an error); OR `get-output` succeeded (an "unavailable" result IS a
#       normal, expected outcome of this call — exit 0, not an error; the calling agent decides how
#       to react to unavailability)
#   2   usage error (missing/malformed arguments, unrecognized outcome word, malformed
#       `<json-conditionals>`), or a real setup problem (python3 unavailable, state file
#       missing/corrupt)
#   3   `advance`/`should-skip`/`get-output` called against a state file already marked `halted:
#       true` from a prior `failed` call — rejected outright rather than silently resuming; this is
#       the "no skip-ahead, no silent resumption after a halt" guard the story's acceptance
#       criteria require
#
# ---------------------------------------------------------------------------

set -euo pipefail

# Resolve project root (E53_S04_T05, mirrors scripts/write-context-digest.sh's own probing order).
# JENGA_PLAYBOOK_RUNS_TEST_ROOT is a TEST-ONLY override for the artifact-persistence path -- never
# set it in a real invocation (see "ARTIFACT PERSISTENCE AND REDACTION POLICY" above).
resolve_project_dir() {
  if [ -n "${JENGA_PLAYBOOK_RUNS_TEST_ROOT:-}" ]; then
    printf '%s\n' "$JENGA_PLAYBOOK_RUNS_TEST_ROOT"
    return 0
  fi
  if [ -n "${JENGA_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$JENGA_PROJECT_DIR"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required by run-playbook-step.sh" >&2
  exit 2
fi

if [ $# -lt 1 ]; then
  echo "Usage:" >&2
  echo "  run-playbook-step.sh init \"<playbook_id>\" \"<name>\" \"<comma-separated confirmed step names>\" [\"<json-conditionals>\" [\"<json-origins>\"]]" >&2
  echo "  run-playbook-step.sh should-skip <state_file>" >&2
  echo "  run-playbook-step.sh advance <state_file> passed [\"<typed-output-value>\"]" >&2
  echo "  run-playbook-step.sh advance <state_file> skipped" >&2
  echo "  run-playbook-step.sh advance <state_file> failed [\"<note>\"]" >&2
  echo "  run-playbook-step.sh get-output <state_file> <step_name>" >&2
  exit 2
fi

SUBCOMMAND="$1"
shift

if [ "$SUBCOMMAND" = "init" ]; then
  if [ $# -lt 3 ] || [ $# -gt 5 ]; then
    echo 'Usage: run-playbook-step.sh init "<playbook_id>" "<name>" "<comma-separated steps>" ["<json-conditionals>" ["<json-origins>"]]' >&2
    exit 2
  fi
  PLAYBOOK_ID="$1"
  PLAYBOOK_NAME="$2"
  RAW_STEPS="$3"
  RAW_CONDITIONALS="${4:-}"
  RAW_ORIGINS="${5:-}"

  if [ -z "${RAW_STEPS// /}" ]; then
    echo "Error: no steps given to run-playbook-step.sh init" >&2
    exit 2
  fi

  STATE_FILE="$(mktemp -t jenga-playbook-run-XXXXXX.json)"

  PY_SCRIPT="$(mktemp -t run-playbook-step-init-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import re
import secrets
import sys
from datetime import datetime, timezone

state_file_path = sys.argv[1]
playbook_id = sys.argv[2]
playbook_name = sys.argv[3]
raw_steps = sys.argv[4]
raw_conditionals = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] != "" else None
raw_origins = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] != "" else None

steps = [s.strip() for s in raw_steps.split(",") if s.strip() != ""]
if not steps:
    print("Error: no valid step names parsed from the given list", file=sys.stderr)
    sys.exit(2)

PREDICATE_RE = re.compile(r'^(non_empty|empty|equals:.+|not_equals:.+)$')

conditionals = {}
if raw_conditionals is not None:
    try:
        parsed = json.loads(raw_conditionals)
    except Exception as e:
        print(f"Error: <json-conditionals> is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(parsed, dict):
        print("Error: <json-conditionals> must be a JSON object", file=sys.stderr)
        sys.exit(2)
    for step_name, cond in parsed.items():
        if step_name not in steps:
            print(f"Error: conditional given for '{step_name}', which is not in the step list", file=sys.stderr)
            sys.exit(2)
        if not isinstance(cond, dict) or "depends_on" not in cond or "predicate" not in cond:
            print(f"Error: conditional for '{step_name}' must be an object with 'depends_on' and 'predicate'", file=sys.stderr)
            sys.exit(2)
        depends_on = cond["depends_on"]
        predicate = cond["predicate"]
        if depends_on not in steps or steps.index(depends_on) >= steps.index(step_name):
            print(f"Error: conditional for '{step_name}' depends_on '{depends_on}', which is not an earlier step", file=sys.stderr)
            sys.exit(2)
        if not isinstance(predicate, str) or not PREDICATE_RE.match(predicate):
            print(f"Error: conditional for '{step_name}' has an unrecognized predicate '{predicate}'", file=sys.stderr)
            sys.exit(2)
        conditionals[step_name] = {"depends_on": depends_on, "predicate": predicate}

# --- E53_S05_T04: origin/nesting metadata -- a PURE PASSTHROUGH, never read by any subcommand in
# this script (see header 'COMPOSED/NESTED STEP HANDLING'). ---
origins = {}
if raw_origins is not None:
    try:
        parsed_origins = json.loads(raw_origins)
    except Exception as e:
        print(f"Error: <json-origins> is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(parsed_origins, dict):
        print("Error: <json-origins> must be a JSON object", file=sys.stderr)
        sys.exit(2)
    for step_name, meta in parsed_origins.items():
        if step_name not in steps:
            print(f"Error: origin metadata given for '{step_name}', which is not in the step list", file=sys.stderr)
            sys.exit(2)
        if (
            not isinstance(meta, dict)
            or not isinstance(meta.get("playbook_id"), str)
            or not meta.get("playbook_id")
            or not isinstance(meta.get("depth"), int)
            or isinstance(meta.get("depth"), bool)
            or meta.get("depth") <= 1
        ):
            print(
                f"Error: origin metadata for '{step_name}' must be an object with a non-empty "
                f"string 'playbook_id' and an integer 'depth' > 1",
                file=sys.stderr,
            )
            sys.exit(2)
        origins[step_name] = {"playbook_id": meta["playbook_id"], "depth": meta["depth"]}

# run_id (E53_S04_T05) -- identifies this run's persisted-artifact directory
# (project/logs/playbook-runs/<run_id>/), stored here so every later `advance` call (a fresh
# process) can re-derive the same path without needing it passed again.
run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{playbook_id}-{secrets.token_hex(4)}"

state = {
    "version": 1,
    "created_at": datetime.now(timezone.utc).isoformat(),
    "playbook_id": playbook_id,
    "playbook_name": playbook_name,
    "run_id": run_id,
    "steps": steps,
    "current_index": 0,
    "completed": [],
    "skipped": [],
    "captured_outputs": {},
    "conditionals": conditionals,
    "origins": origins,
    "halted": False,
    "failed_step": None,
    "failed_note": None,
}

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

print(json.dumps({
    "status": "step_ready",
    "step": steps[0],
    "step_index": 1,
    "total_steps": len(steps),
}))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$PLAYBOOK_ID" "$PLAYBOOK_NAME" "$RAW_STEPS" "$RAW_CONDITIONALS" "$RAW_ORIGINS"
  exit 0

elif [ "$SUBCOMMAND" = "should-skip" ]; then
  if [ $# -ne 1 ]; then
    echo 'Usage: run-playbook-step.sh should-skip <state_file>' >&2
    exit 2
  fi
  STATE_FILE="$1"

  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: state file not found at $STATE_FILE" >&2
    exit 2
  fi

  PY_SCRIPT="$(mktemp -t run-playbook-step-should-skip-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import sys

state_file_path = sys.argv[1]

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

if state.get("halted"):
    print(
        f"Error: this playbook run already halted on step '{state.get('failed_step')}'. "
        "No further evaluation is meaningful after a halt.",
        file=sys.stderr,
    )
    sys.exit(3)

steps = state["steps"]
idx = state["current_index"]

if idx >= len(steps):
    print(f"Error: state file at {state_file_path} has no current step (already complete).", file=sys.stderr)
    sys.exit(2)

current_step = steps[idx]
conditionals = state.get("conditionals", {})
cond = conditionals.get(current_step)

if not cond:
    print(json.dumps({"skip": False, "step": current_step}))
    sys.exit(0)

depends_on = cond["depends_on"]
predicate = cond["predicate"]
observed = state.get("captured_outputs", {}).get(depends_on, "")


def evaluate(predicate, value):
    if predicate == "non_empty":
        return bool(value)
    if predicate == "empty":
        return not bool(value)
    if predicate.startswith("equals:"):
        return value == predicate[len("equals:"):]
    if predicate.startswith("not_equals:"):
        return value != predicate[len("not_equals:"):]
    # Load-time validation (load-playbooks.sh) and init's own validation above should have already
    # rejected any other shape -- this is a defensive fallback, never expected to trigger.
    return False


predicate_true = evaluate(predicate, observed)
skip = not predicate_true

print(json.dumps({
    "skip": skip,
    "step": current_step,
    "depends_on": depends_on,
    "predicate": predicate,
    "observed_value": observed,
}))
sys.exit(0)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE"
  exit $?

elif [ "$SUBCOMMAND" = "get-output" ]; then
  if [ $# -ne 2 ]; then
    echo 'Usage: run-playbook-step.sh get-output <state_file> <step_name>' >&2
    exit 2
  fi
  STATE_FILE="$1"
  STEP_NAME="$2"

  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: state file not found at $STATE_FILE" >&2
    exit 2
  fi

  PY_SCRIPT="$(mktemp -t run-playbook-step-get-output-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import sys

state_file_path = sys.argv[1]
step_name = sys.argv[2]

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

captured = state.get("captured_outputs", {})
skipped = state.get("skipped", [])

if step_name in captured:
    print(json.dumps({"status": "found", "step": step_name, "value": captured[step_name]}))
    sys.exit(0)

if step_name in skipped:
    print(json.dumps({"status": "unavailable", "step": step_name, "reason": "step_skipped"}))
    sys.exit(0)

print(json.dumps({"status": "unavailable", "step": step_name, "reason": "not_captured"}))
sys.exit(0)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$STEP_NAME"
  exit $?

elif [ "$SUBCOMMAND" = "advance" ]; then
  if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo 'Usage: run-playbook-step.sh advance <state_file> passed|skipped|failed ["<value-or-note>"]' >&2
    exit 2
  fi
  STATE_FILE="$1"
  OUTCOME="$2"
  EXTRA="${3:-}"

  if [ "$OUTCOME" != "passed" ] && [ "$OUTCOME" != "skipped" ] && [ "$OUTCOME" != "failed" ]; then
    echo "Error: outcome must be 'passed', 'skipped', or 'failed', got '$OUTCOME'" >&2
    exit 2
  fi

  if [ "$OUTCOME" = "skipped" ] && [ -n "$EXTRA" ]; then
    echo "Error: 'skipped' does not accept a 3rd argument -- a skipped step never ran and has nothing to report" >&2
    exit 2
  fi

  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: state file not found at $STATE_FILE" >&2
    echo "The playbook run may have expired (e.g. temp dir was cleared), or already completed." >&2
    exit 2
  fi

  PROJECT_DIR="$(resolve_project_dir)"

  PY_SCRIPT="$(mktemp -t run-playbook-step-advance-XXXXXX.py)"
  trap 'rm -f "$PY_SCRIPT"' EXIT

  cat > "$PY_SCRIPT" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

state_file_path = sys.argv[1]
outcome = sys.argv[2]
# The optional 3rd argument means something different per outcome: a typed-output VALUE for
# `passed` (E53_S04_T01), a free-text NOTE for `failed` -- never accepted for `skipped` (rejected
# by the bash-level guard above). Only one of the two is ever read below, selected by `outcome`.
extra = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "" else None
note = extra
project_dir = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "" else None

# --- E53_S04_T05: artifact persistence + redaction (persisted copy only -- see header) ---
_ABS_PATH_RE = re.compile(r'(/[^\s"\']+)')
_EMAIL_RE = re.compile(r'[\w.+-]+@[\w-]+\.[\w.-]+')
_PHONE_RE = re.compile(r'\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b')


def _redact(value, project_root):
    """Best-effort, narrow redaction of a value before it is PERSISTED -- never applied to the
    live, functional captured_outputs value in the state file. See header 'ARTIFACT PERSISTENCE
    AND REDACTION POLICY' for the full policy and its explicit best-effort framing."""
    if not isinstance(value, str):
        return value

    def _replace_path(m):
        p = m.group(1)
        try:
            abs_p = os.path.abspath(p)
            abs_root = os.path.abspath(project_root)
            if abs_p == abs_root or abs_p.startswith(abs_root + os.sep):
                return p  # inside the project root -- not redacted
        except Exception:
            pass
        return "[REDACTED_ABS_PATH]"

    redacted = _ABS_PATH_RE.sub(_replace_path, value) if project_root else value
    redacted = _EMAIL_RE.sub("[REDACTED_EMAIL]", redacted)
    redacted = _PHONE_RE.sub("[REDACTED_PHONE]", redacted)
    return redacted


def _persist_artifact(state, step_name, value, project_root):
    """Append one redacted record to project/logs/playbook-runs/<run_id>/artifacts.jsonl.
    Best-effort: any failure to persist (unwritable filesystem, missing run_id on an old state
    file) is swallowed with a stderr warning -- persistence is a durability nicety, never a reason
    to fail a playbook run that otherwise succeeded."""
    run_id = state.get("run_id")
    if not run_id or not project_root:
        return
    try:
        run_dir = os.path.join(project_root, "project", "logs", "playbook-runs", run_id)
        os.makedirs(run_dir, exist_ok=True)
        record = {
            "step": step_name,
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "value": _redact(value, project_root),
        }
        with open(os.path.join(run_dir, "artifacts.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except OSError as e:
        print(f"Warning: could not persist captured-output artifact for '{step_name}': {e}", file=sys.stderr)

try:
    with open(state_file_path, encoding="utf-8") as f:
        state = json.load(f)
except Exception as e:
    print(f"Error: could not read/parse state file at {state_file_path}: {e}", file=sys.stderr)
    sys.exit(2)

if state.get("halted"):
    print(
        f"Error: this playbook run already halted on step '{state.get('failed_step')}'. "
        "A further advance() call is rejected -- no silent resumption after a halt. "
        "Start a new run with run-playbook-step.sh init if you want to retry.",
        file=sys.stderr,
    )
    sys.exit(3)

steps = state["steps"]
idx = state["current_index"]

if idx >= len(steps):
    print(f"Error: state file at {state_file_path} has no current step (already complete).", file=sys.stderr)
    sys.exit(2)

current_step = steps[idx]
state.setdefault("skipped", [])

if outcome == "failed":
    state["halted"] = True
    state["failed_step"] = current_step
    state["failed_note"] = note
    never_run = steps[idx + 1:]

    with open(state_file_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
        f.write("\n")

    print(json.dumps({
        "status": "halted",
        "playbook_id": state["playbook_id"],
        "name": state["playbook_name"],
        "completed": state["completed"],
        "skipped": state["skipped"],
        "failed_step": current_step,
        "failed_note": note,
        "never_run": never_run,
    }))
    sys.exit(0)

if outcome == "skipped":
    # A skipped step never ran -- it is non-blocking, non-failing, and never captures an output.
    state["skipped"].append(current_step)
else:
    # outcome == "passed"
    typed_output_value = extra
    if typed_output_value is not None:
        state["captured_outputs"][current_step] = typed_output_value
        _persist_artifact(state, current_step, typed_output_value, project_dir)
    state["completed"].append(current_step)

state["current_index"] = idx + 1

if state["current_index"] >= len(steps):
    result = {
        "status": "complete",
        "playbook_id": state["playbook_id"],
        "name": state["playbook_name"],
        "completed": state["completed"],
        "skipped": state["skipped"],
    }
    try:
        os.remove(state_file_path)
    except OSError:
        pass
    print(json.dumps(result))
    sys.exit(0)

with open(state_file_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")

next_step = steps[state["current_index"]]
print(json.dumps({
    "status": "step_ready",
    "step": next_step,
    "step_index": state["current_index"] + 1,
    "total_steps": len(steps),
}))
print(f"STATE_FILE: {state_file_path}", file=sys.stderr)
PY

  python3 "$PY_SCRIPT" "$STATE_FILE" "$OUTCOME" "$EXTRA" "$PROJECT_DIR"
  exit $?

else
  echo "Error: unrecognized subcommand '$SUBCOMMAND' (expected 'init', 'should-skip', 'advance', or 'get-output')" >&2
  exit 2
fi

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
#     plain skill-name strings.
#
#   - a StepObject (a JSON object) — `{"skill": "<string>"}` OR `{"playbook": "<string>"}`,
#     mutually exclusive (a step naming both, or naming neither, is a validation error — see
#     below), plus all of the following OPTIONAL fields, each validated only for shape at this
#     point in the pipeline:
#       - `instruction`  (string) — static natural-language text appended to this step's own
#                                    invocation message.
#       - `forward_from` (string) — names a prior step this step's invocation input is drawn from.
#                                    RUNTIME-EXECUTABLE as of `E53_S04_T02`: the calling agent
#                                    resolves the actual value via
#                                    `run-playbook-step.sh get-output <state_file> <step_name>`.
#                                    Transparent across composition boundaries as of `E53_S05_T02`
#                                    — see "COMPOSITION RESOLUTION" below.
#       - `resolve`      (string) — natural-language instructions for reshaping/filtering/
#                                    type-bridging a forwarded value. Mutually exclusive with
#                                    `playbook` on the SAME step (see "CONFIRMATION-GATE
#                                    CONVENTION" below) — this is now enforced directly in
#                                    `normalize_step()` (E53_S05_T01), since composition
#                                    resolution later splices a `playbook`-type step away
#                                    entirely, which would make the conflict unreachable if this
#                                    check were deferred until after flattening.
#       - `conditional`  (object) — `{"depends_on": "<earlier step name>", "predicate":
#                                    "<predicate>"}` (E53_S04_T02). Determines whether this step
#                                    executes at all, evaluated at RUNTIME by
#                                    `run-playbook-step.sh should-skip` against the named prior
#                                    step's captured typed-output artifact. Transparent across
#                                    composition boundaries as of `E53_S05_T02`, exactly like
#                                    `forward_from`.
#       - `playbook`     (string) — composes in ANOTHER playbook by id, resolved by THIS script
#                                    (E53_S05_T01) — see "COMPOSITION RESOLUTION" below.
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
# load time, entirely from this repository's own files on disk. As of `E53_S05_T01`/`T02`, this
# validation loop runs over the FULLY FLATTENED step list (see "COMPOSITION RESOLUTION" below) —
# "earlier step" below means earlier in that final, flattened, position-ordered list, regardless
# of whether the step originated in the top-level playbook or a nested (composed) one:
#
#   1. EXISTENCE — `<name>` must equal the skill name of some EARLIER step in the FLATTENED
#      `steps` list (a bare string equal to `<name>`, or a StepObject whose `skill` field equals
#      `<name>`; a `playbook`-type step never satisfies this directly, since by the time this loop
#      runs, every `playbook`-type step has already been replaced by its resolved contents — see
#      below). If no earlier match exists, the playbook is rejected.
#
#   2. DECLARED OUTPUT — the source skill's own `skills/<name>/SKILL.md` frontmatter must declare
#      a non-empty `output_types` field (see `docs/skill-authoring.md`'s `output_types` section,
#      E53_S03_T02). A skill with no declared `output_types` cannot be a forward source — this is
#      the design's partial-adoption rule (`templates/playbook-types.json`, E53_S03_T02) made
#      load-time-enforced: only `j.status`, `j.uncharted`, `j.jenga`, and `j.reconcile` declare it
#      as of this story. If the source has no declared `output_types`, the playbook is rejected.
#      This check is keyed purely off the source step's own resolved skill name and its own
#      `SKILL.md` — origin-independent by construction, so it applies identically whether the
#      source step originated in the top-level playbook or a nested one (`E53_S05_T02`).
#
#   3. BLOCKER 1'S STRUCTURAL {when, type} CHECK (E53_S03_T04) — applies only when the source's
#      `output_types` is the list-of-`{when, type}` form (as opposed to a single static type
#      string). For each `{when, type}` entry:
#        - both `when` and `type` must be present, or the playbook is rejected.
#        - if `when` is one of the two BUILT-IN predicates (`argument_empty` / `argument_nonempty`),
#          no further check is made here — those predicates describe the STEP's own invocation
#          shape, not a separate classifier, and are accepted as-is.
#        - otherwise `when` is a CLASSIFIER-SCRIPT REFERENCE (e.g. `j.jenga`'s own `when:
#          detect-nl-intent`, referencing `skills/jenga/scripts/detect-nl-intent.sh`). What IS
#          load-time-knowable, and the only claim this check ever makes, is purely structural:
#          does a script matching that reference actually exist on disk
#          (`skills/<name>/scripts/<when>.sh`)? If not, the reference is bogus and the playbook is
#          rejected. This loader never invokes either the classifier script or the source skill to
#          make this claim.
#
# WORKED TWO-LEVEL CROSS-BOUNDARY EXAMPLE (E53_S05_T02) — demonstrates BOTH directions at once:
#
#   skills/jenga/playbooks/nested.json:
#     { "id": "nested", ..., "steps": [
#         "src",                                            // declares output_types
#         {"skill": "sink", "forward_from": "outer1"}        // forwards from OUTSIDE this file
#     ]}
#
#   skills/jenga/playbooks/outerchain.json:
#     { "id": "outerchain", ..., "steps": [
#         "outer1",                                          // declares output_types
#         {"playbook": "nested"},
#         {"skill": "outer2", "forward_from": "src"}          // forwards from INSIDE "nested"
#     ]}
#
#   Resolved as its OWN top-level entry, "nested" alone is REJECTED — its `sink` step's
#   `forward_from: "outer1"` has no earlier match within nested's own two steps. But composed
#   inside "outerchain", composition resolution (E53_S05_T01) splices nested's steps in first, so
#   by the time the forward_from/conditional loop (below) runs, "outerchain"'s flattened list is:
#   `["outer1", {"skill": "src", "_origin_playbook": "nested", "_origin_depth": 2}, {"skill":
#   "sink", "forward_from": "outer1", "_origin_playbook": "nested", "_origin_depth": 2},
#   {"skill": "outer2", "forward_from": "src"}]` — a single flat, position-ordered list. "sink"'s
#   forward_from now finds "outer1" earlier in that list (an OUTER step forwarding INTO a nested
#   one), and "outer2"'s forward_from finds "src" earlier too (a NESTED step forwarding OUT to an
#   outer one) — both resolved by the exact same existence check, with no origin-based branching
#   anywhere in this loop. `conditional.depends_on` works identically, by the same mechanism.
#
# ---------------------------------------------------------------------------
# CONDITIONAL RESOLUTION (E53_S04_T02)
# ---------------------------------------------------------------------------
# A step's `conditional: {"depends_on": "<name>", "predicate": "<predicate>"}` is validated at load
# time, mirroring `forward_from`'s existence rule exactly — and, as of `E53_S05_T02`, over the same
# FULLY FLATTENED step list:
#
#   1. SHAPE — `conditional` must be an object carrying exactly `depends_on` (non-empty string) and
#      `predicate` (non-empty string). Any other shape is rejected.
#   2. EXISTENCE — `depends_on` must equal the skill name of some EARLIER step in the FLATTENED
#      step list (same rule as `forward_from`'s existence check above).
#   3. PREDICATE GRAMMAR — `predicate` must match one of `non_empty`, `empty`, `equals:<value>`,
#      `not_equals:<value>`. This loader does NOT re-derive that grammar; it is defined once, as the
#      single source of truth, in `run-playbook-step.sh`'s own header (the script that actually
#      EVALUATES it at runtime via `should-skip`) — this loader's job is only to reject an
#      unrecognized predicate string before it ever reaches that runtime evaluation.
#
# Unlike `forward_from`, `conditional` does NOT require the depended-on step to have a declared
# `output_types` — a conditional may legitimately depend on a step whose captured output is simply
# "did it produce anything at all" (the `empty`/`non_empty` predicates), which needs no declared
# type to be meaningful. `conditional` and `forward_from` on the SAME step are independent,
# orthogonal fields and may both be present together (whether this step runs is one question,
# what data flows into it if it does run is another).
#
# ---------------------------------------------------------------------------
# COMPOSITION RESOLUTION (E53_S05_T01, cross-boundary transparency extended by E53_S05_T02)
# ---------------------------------------------------------------------------
# A `{"playbook": "<id>"}` step composes another playbook's own chain into this one. Resolution
# runs AFTER local shape/skill-existence validation of ordinary steps, and BEFORE the
# `forward_from`/`conditional` validation loop described above — that ordering is what makes
# cross-boundary `forward_from`/`conditional` "just work" with no special-casing: by the time that
# loop runs, every playbook-type step has already been replaced by its resolved contents, so the
# loop only ever sees a flat, position-ordered list of skill-only steps.
#
#   1. EXISTENCE — `<id>` must resolve to a real playbook file (`<id>.json` under
#      `skills/jenga/playbooks/`, excluding `schema.json`) that ALSO passes this script's own local
#      validation (shape, required fields, id/filename match, skill-existence for its own
#      skill-type steps). A reference to a file that plain does not exist, and a reference to a
#      file that exists but failed its own local validation, are both treated as "could not be
#      resolved" and cause the WHOLE REFERENCING playbook to be dropped — same granularity as
#      every other check in this script (a chain with a broken link is not a usable chain).
#
#   2. CYCLE DETECTION — resolution is a depth-first walk of each playbook's composition graph
#      (its `playbook`-type steps, transitively). If a step's target id is already on the CURRENT
#      resolution path (the chain of playbook ids being resolved to reach this point, including
#      direct self-reference — a playbook composing itself), that is a cycle: the referencing
#      playbook is dropped with a stderr warning naming the cycle path. Because every playbook file
#      is independently resolved as its own top-level entry point (in addition to being resolved
#      as a nested reference wherever else it's composed), a cycle is caught and reported
#      regardless of which playbook in the cycle happens to be read first.
#
#   3. CONFIGURABLE DEPTH LIMIT — nesting depth is tracked as it already is for
#      `_origin_depth` (below): a playbook's own steps are depth 1; a step spliced in from one
#      level of composition is depth 2; two levels is depth 3; and so on. The maximum allowed
#      depth is read from `project/configs/playbook-config.json`'s `max_composition_depth` field
#      (a NEW, DEDICATED config file — kept separate from `project/configs/scope-thresholds.json`,
#      since that file's own fields are specifically `/jenga`/`/do` task execution-scope
#      thresholds, a different concern from playbook nesting-depth safety), defaulting to **3**
#      when the file/field is absent or invalid. This is an explicitly TUNABLE SAFETY DEFAULT, not
#      an architectural ceiling — raise it in `playbook-config.json` if a legitimate composition
#      chain needs to nest deeper. A composition step whose target would be nested past the
#      configured limit is dropped (with a stderr warning) before that target is even resolved.
#      Project-root resolution for this config file mirrors `run-playbook-step.sh`'s own
#      `resolve_project_dir` probing order (`JENGA_PROJECT_DIR` -> `CLAUDE_PROJECT_DIR` -> `git
#      rev-parse --show-toplevel` -> `pwd`), and reuses this script's own existing
#      `JENGA_PLAYBOOKS_TEST_ROOT` fixture override for the same purpose (a fixture wanting a
#      non-default depth limit places its own `project/configs/playbook-config.json` under that
#      same override root — no second test-only variable is introduced).
#
#   4. RECURSIVE FLATTENING — once a `{"playbook": "<id>"}` step passes existence/cycle/depth
#      checks, the referenced playbook's OWN already-resolved (recursively flattened) step
#      sequence is spliced into the parent's `steps` array at that position, in original order.
#      The catalog's emitted `steps` array for any playbook therefore never contains a raw
#      `playbook`-type entry — only flattened skill-only steps (bare strings or `{"skill": ...}`
#      StepObjects, the latter possibly carrying the origin annotation below).
#
#   5. ORIGIN ANNOTATION — a step that came from an actual nested inclusion (composition depth >
#      1) carries two new passthrough-only fields once it is spliced into a parent: `_origin_playbook`
#      (the id of the playbook file the step was originally written in) and `_origin_depth` (2 for
#      a step from one level of composition, 3 for two levels, and so on). Needed by `E53_S05_T02`
#      (forward_from/conditional boundary transparency — origin is never consulted, but the field
#      exists for observability), `E53_S05_T03` (nested confirmation display), and `E53_S05_T04`
#      (traceable reporting). **A playbook's own depth-1 steps (its own, un-composed steps) are
#      NEVER annotated and are emitted byte-for-byte exactly as before this story** — this
#      preserves the pre-existing bare-string backward-compatibility guarantee (see STEP SHAPES
#      above) for the common case of a playbook that uses no composition at all: such a playbook's
#      catalog entry is completely unaffected by this story. Only a step that is actually spliced
#      in from a nested playbook (depth > 1) is guaranteed to appear as an object carrying these
#      two fields (a bare string at that depth is converted to `{"skill": "<name>", ...}` to carry
#      them — there is no way to attach fields to a bare string).
#
#   6. DUPLICATE-NAME COLLISION CHECK — every downstream script in this chain (`forward_from`,
#      `conditional`, `captured_outputs`, `get-output`) addresses a step purely by its resolved
#      skill name (`step_skill_name`). Once a playbook's own steps are combined with any spliced-in
#      nested content, two or more steps resolving to the SAME skill name would corrupt that
#      addressing. This check runs on every resolution's own flattened result (not just the
#      top-level's) immediately before it is returned — so a collision is caught and reported at
#      the lowest level it first occurs, and a nested playbook is never spliced into a parent
#      unless it is already known to be collision-free on its own. A collision drops the whole
#      playbook being resolved at that point, with a stderr warning naming the duplicate.
#
# A playbook that is itself invalid at composition time (cycle, depth limit, unresolved reference,
# or a duplicate-name collision after flattening) is dropped from the catalog exactly like every
# other validation failure in this script — a stderr warning, never a hard crash, and no other
# playbook is affected merely because it happens to reference the dropped one (the REFERENCING
# playbook is dropped too, but only that one, unless it is in turn referenced by yet another
# playbook, which cascades the same way).
#
# ---------------------------------------------------------------------------
# CONFIRMATION-GATE CONVENTION (E53_S03_T03 — Blocker 2 v1 scope cut, load-time half)
# ---------------------------------------------------------------------------
# The design's Blocker 2 (see the plan doc's Open Decisions) splits `resolve` into two stories:
# this one ships `resolve` for reshaping/filtering/type-bridging a forwarded value ONLY, never for
# pre-authorizing a downstream confirmation gate — that combination is explicitly out of scope and
# rejected here, at load time (in `normalize_step()`, as of E53_S05_T01 — see STEP SHAPES above).
# `E53_S06` owns `resolve`'s own runtime behavior; this is only the load-time rejection rule.
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
# No arguments (full-catalog mode, unchanged since before E53_S06). Emits the full JSON playbook
# catalog array to stdout, exactly as documented in "OUTPUT SCHEMA" below.
#
#   skills/jenga/scripts/load-playbooks.sh lookup <id>
#
# Additive sibling mode (E53_S06_T02), for direct-by-id lookup (`j.playbook <id>`,
# `skills/j-playbook/SKILL.md`, E53_S06_T03) — runs the SAME PASS 1-3 pipeline as the no-argument
# mode above (never a separate implementation), then emits exactly ONE JSON object to stdout
# (never the full catalog, never warnings about OTHER playbooks) and exits 0:
#
#   {"status": "valid", "playbook": {...}}    -- <id> resolved to a real file and passed every
#                                                 validation pass; `playbook` has the same field
#                                                 shape as one full-catalog entry.
#   {"status": "invalid", "reason": "..."}    -- a file `<id>.json` exists under
#                                                 skills/jenga/playbooks/ but failed validation at
#                                                 some pass; `reason` is the SAME specific,
#                                                 human-readable message this script would already
#                                                 print to stderr for that failure in full-catalog
#                                                 mode -- never a generic message.
#   {"status": "not_found"}                   -- no `<id>.json` file exists under
#                                                 skills/jenga/playbooks/ (excluding schema.json)
#                                                 at all.
#
# Usage errors (`lookup` given with no `<id>`, or an unrecognized first argument) print a usage
# message to stderr and exit 2 -- the same setup-error exit code documented in "EXIT CODES" below.
# stderr warnings about OTHER (non-looked-up) playbooks may still be emitted for consistency with
# the full-catalog mode's existing behavior; only stdout is constrained to exactly one JSON object.
#
# TESTING OVERRIDE — JENGA_PLAYBOOKS_TEST_ROOT (E53_S03_T05): when this environment variable is
# set, it overrides the monorepo/node_modules PKG_ROOT auto-detection below, pointing
# PLAYBOOKS_DIR/SKILLS_DIR at `<value>/skills/jenga/playbooks` and `<value>/skills` respectively,
# AND (as of E53_S05_T01) overrides the PROJECT root used to locate
# `project/configs/playbook-config.json`, so a fixture wanting a non-default composition depth
# limit places one at `<value>/project/configs/playbook-config.json`. This exists exclusively so
# `tests/load-playbooks-stepobject.bats` and `tests/load-playbooks-composition.bats` can point this
# loader at a synthetic, throwaway fixture tree under `$BATS_TEST_TMPDIR` instead of this
# repository's own `skills/`/`project/` — per this repo's fixture-tree testing convention, a test
# asserting on candidate sets never targets the repository root. Never set this variable in a real
# invocation.
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
# `steps` entries are emitted exactly as validated/resolved: a depth-1 bare string stays a bare
# string; a depth-1 StepObject is emitted as an object carrying only its recognized fields (`skill`
# XOR `playbook` — though by the time this is emitted, a `playbook`-type step has already been
# replaced by its resolved contents — plus whichever of `instruction`/`forward_from`/`resolve`/
# `conditional`/`version`/`schema_version` were present on the source step); a step spliced in from
# a nested (composed) playbook (depth > 1) additionally carries `_origin_playbook`/`_origin_depth`
# (see "COMPOSITION RESOLUTION" above).
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
#   - A StepObject carries BOTH `resolve` and `playbook`                   -> skipped
#     (resolve targeting a downstream confirmation gate — Blocker 2 v1 scope cut, E53_S03_T03;
#     checked in `normalize_step()` as of E53_S05_T01, before composition can splice the
#     `playbook` field away)
#   - Any `skill`-type step (bare string or StepObject) has no
#     corresponding `skills/<name>/SKILL.md` on disk                       -> skipped
#   - A `{"playbook": "<id>"}` step's `<id>` does not resolve to an
#     existing, locally-valid playbook file                     (E53_S05_T01) -> skipped
#   - A playbook's composition graph contains a cycle (including direct
#     self-reference)                                            (E53_S05_T01) -> skipped
#   - A composition's nesting depth exceeds the configured/default
#     `max_composition_depth`                                    (E53_S05_T01) -> skipped
#   - A flattened composition result contains two or more steps
#     resolving to the same skill name                           (E53_S05_T01) -> skipped
#   - A `forward_from` names a step that is not an EARLIER step in the
#     final flattened step list                                              -> skipped
#   - A `forward_from` names a source step whose skill has no declared
#     `output_types` in its own `SKILL.md` frontmatter                     -> skipped
#   - A `forward_from` source's `output_types` list has a `{when, type}`
#     entry missing `when`/`type`, or a classifier-script `when` with no
#     matching `skills/<name>/scripts/<when>.sh` on disk (Blocker 1,
#     E53_S03_T04)                                                         -> skipped
#   - A `conditional` field is present but not an object with exactly
#     `depends_on` and `predicate` (both non-empty strings)  (E53_S04_T02) -> skipped
#   - A `conditional`'s `depends_on` names a step that is not an EARLIER
#     step in the final flattened step list                  (E53_S04_T02) -> skipped
#   - A `conditional`'s `predicate` does not match the recognized grammar
#     (`non_empty`/`empty`/`equals:<value>`/`not_equals:<value>`, defined
#     in `run-playbook-step.sh`'s own header)                (E53_S04_T02) -> skipped
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

# --- E53_S06_T02: additive `lookup <id>` CLI mode ------------------------------------------------
# Backward compatible: no arguments at all reproduces the original, unchanged full-catalog mode.
# See header "USAGE" for the full contract.
MODE="catalog"
LOOKUP_ID=""
if [ $# -gt 0 ]; then
  case "$1" in
    lookup)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "Usage: $(basename "$0") lookup <id>" >&2
        exit 2
      fi
      MODE="lookup"
      LOOKUP_ID="$2"
      ;;
    *)
      echo "Error: unrecognized argument '$1' (usage: $(basename "$0") [lookup <id>])" >&2
      exit 2
      ;;
  esac
fi

if [ -n "${JENGA_PLAYBOOKS_TEST_ROOT:-}" ]; then
  # Test-only override — see "TESTING OVERRIDE" in the header above (E53_S03_T05, extended by
  # E53_S05_T01 to also cover playbook-config.json resolution). Never set in a real invocation.
  PKG_ROOT="$JENGA_PLAYBOOKS_TEST_ROOT"
  PROJECT_DIR="$JENGA_PLAYBOOKS_TEST_ROOT"
# Resolve the jenga-agent PACKAGE root (where the canonical skills/ tree actually lives) — same
# monorepo-checkout vs. installed-npm-package detection used by
# skills/jenga/scripts/load-nl-catalog.sh's PKG_ROOT resolution and skills/init/scripts/init.sh.
elif [ -d "$SCRIPT_DIR/../../../templates" ]; then
  PKG_ROOT="$SCRIPT_DIR/../../.."
  PROJECT_DIR="${JENGA_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)}}"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent/templates" ]; then
  PKG_ROOT="${CLAUDE_PROJECT_DIR}/node_modules/@jenga-ai/agent"
  PROJECT_DIR="${JENGA_PROJECT_DIR:-$CLAUDE_PROJECT_DIR}"
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
project_dir = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
# --- E53_S06_T02: additive `lookup <id>` CLI mode --------------------------------------------
mode = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else "catalog"
lookup_id = sys.argv[5] if len(sys.argv) > 5 else ""

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

# Recognized `conditional.predicate` grammar (E53_S04_T02). The single source of truth for this
# grammar is `run-playbook-step.sh`'s own header -- this regex is a load-time mirror of it, not a
# second, independent definition.
CONDITIONAL_PREDICATE_RE = re.compile(r'^(non_empty|empty|equals:.+|not_equals:.+)$')

# --- E53_S05_T01: configurable composition depth limit -----------------------------------------
DEFAULT_MAX_COMPOSITION_DEPTH = 3


def load_max_composition_depth(proj_dir):
    """Read `max_composition_depth` from project/configs/playbook-config.json. A missing file,
    missing field, or non-positive-integer value all fall back to the hardcoded default -- this
    is a tunable safety default, never a required setup file (see header 'COMPOSITION
    RESOLUTION')."""
    if not proj_dir:
        return DEFAULT_MAX_COMPOSITION_DEPTH
    config_path = os.path.join(proj_dir, "project", "configs", "playbook-config.json")
    if not os.path.isfile(config_path):
        return DEFAULT_MAX_COMPOSITION_DEPTH
    try:
        with open(config_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
        value = cfg.get("max_composition_depth", DEFAULT_MAX_COMPOSITION_DEPTH)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 1:
            return value
    except Exception:
        pass
    return DEFAULT_MAX_COMPOSITION_DEPTH


MAX_COMPOSITION_DEPTH = load_max_composition_depth(project_dir)

catalog = []
# --- E53_S06_T02: per-basename skip-reason capture -------------------------------------------
# Threaded through PASS 1, PASS 2 (resolve_playbook), and PASS 3 below -- whenever a playbook
# basename is dropped, at any point in the pipeline, the specific reason string already being
# printed to stderr is ALSO recorded here, against that basename. This is purely additive: it
# never changes any existing stderr warning text or the full-catalog mode's JSON output (see
# header "USAGE"). Powers `lookup <id>`'s "invalid" result (a known id that failed validation,
# with the SAME specific reason -- never a generic message).
skip_reasons = {}


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

    # --- E53_S05_T01: resolve/playbook conflict (Blocker 2 v1 scope cut, E53_S03_T03) -- must be
    # checked HERE, before composition resolution ever runs, since that pass later splices a
    # `playbook`-type step away entirely -- deferring this check until after flattening would
    # make the conflict unreachable.
    if has_playbook and "resolve" in entry:
        return None, (
            f"step {idx} has 'resolve' targeting a playbook-composition step "
            f"('{entry['playbook']}'), which is always a downstream confirmation gate "
            f"(see header 'CONFIRMATION-GATE CONVENTION') — 'resolve' may never target one"
        )

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

    # `conditional` (E53_S04_T02) -- shape check only here; cross-step existence + predicate
    # grammar checks happen in the forward_from/conditional validation loop below, once the full
    # FLATTENED steps list (E53_S05_T01/T02) is available.
    if "conditional" in entry:
        cond = entry["conditional"]
        if (
            not isinstance(cond, dict)
            or set(cond.keys()) != {"depends_on", "predicate"}
            or not isinstance(cond.get("depends_on"), str)
            or not cond.get("depends_on")
            or not isinstance(cond.get("predicate"), str)
            or not cond.get("predicate")
        ):
            return None, (
                f"step {idx} 'conditional' must be an object with exactly 'depends_on' and "
                f"'predicate' (both non-empty strings)"
            )
        out["conditional"] = {"depends_on": cond["depends_on"], "predicate": cond["predicate"]}

    for field in STEP_RESERVED_FIELDS:
        if field in entry:
            # Reserved, no-op: accepted and passed through verbatim, no type check.
            out[field] = entry[field]

    return out, None


def step_skill_name(step):
    """The skill name a step resolves to for forward_from-source/duplicate-collision matching, or
    None for a (pre-flatten) playbook-type step, which has no single skill name to match
    against."""
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

# --- PASS 1: local (non-composition) validation -------------------------------------------------
# Builds `raw[pid]` for every playbook that passes purely local validation (parse/shape/id-match/
# step-shape/skill-existence) -- independent of any OTHER playbook. Composition resolution (PASS
# 2, below) needs this map fully populated before it can recurse into a referenced playbook.
raw = {}
order = []  # preserves the original sorted-filename order for stable catalog/warning output

for filename in filenames:
    path = os.path.join(playbooks_dir, filename)
    basename = filename[: -len(".json")]

    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        reason = f"is not valid JSON ({e})"
        print(f"Warning: {path} {reason} — skipped", file=sys.stderr)
        skip_reasons[basename] = reason
        continue

    if not isinstance(data, dict):
        reason = "is not a JSON object"
        print(f"Warning: {path} {reason} — skipped", file=sys.stderr)
        skip_reasons[basename] = reason
        continue

    missing = [f for f in REQUIRED_FIELDS if f not in data]
    if missing:
        reason = f"missing required field(s) {missing}"
        print(f"Warning: {path} {reason} — skipped", file=sys.stderr)
        skip_reasons[basename] = reason
        continue

    bad_list = [
        f for f in LIST_FIELDS
        if not isinstance(data.get(f), list) or len(data.get(f)) == 0
    ]
    if bad_list:
        reason = f"field(s) {bad_list} must be non-empty lists"
        print(f"Warning: {path} {reason} — skipped", file=sys.stderr)
        skip_reasons[basename] = reason
        continue

    if data["id"] != basename:
        reason = (
            f"has id '{data['id']}' which does not match its filename '{basename}.json'"
        )
        print(f"Warning: {path} {reason} — skipped", file=sys.stderr)
        skip_reasons[basename] = reason
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
        skip_reasons[basename] = step_error
        continue

    # Existence check for skill-type steps only (bare string, or StepObject with `skill`).
    # `playbook`-type steps have no single skill name (step_skill_name returns None for them) and
    # are therefore naturally excluded here -- their existence is composition resolution's job
    # (PASS 2, E53_S05_T01).
    skill_names_to_check = [
        name for name in (step_skill_name(s) for s in normalized_steps)
        if name is not None
    ]
    missing_skills = [
        name for name in skill_names_to_check
        if not os.path.isfile(os.path.join(skills_dir, name, "SKILL.md"))
    ]
    if missing_skills:
        reason = (
            f"references nonexistent skill(s) {missing_skills} "
            f"(no skills/<name>/SKILL.md found)"
        )
        print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
        skip_reasons[basename] = reason
        continue

    raw[basename] = {
        "path": path,
        "name": data["name"],
        "description": data["description"],
        "keywords": data["keywords"],
        "examples": data["examples"],
        "normalized_steps": normalized_steps,
    }
    order.append(basename)

# --- PASS 2: composition resolution (E53_S05_T01) ------------------------------------------------
# Recursively resolves `{"playbook": "<id>"}` steps into a flat, fully-spliced step list. See
# header 'COMPOSITION RESOLUTION' for the full algorithm description; this is that algorithm.

# Deliberately NOT memoized across calls: the same playbook id can legitimately be composed at
# different depths by different composers (or resolved fresh as its own top-level catalog entry),
# and origin annotation/depth-limit checks are context-dependent on the CURRENT resolution path --
# a cached result from one context would be wrong to reuse in another. The playbook catalog is
# small, so re-resolving a shared sub-playbook on each reference is cheap.
def resolve_playbook(pid, depth, visiting_path):
    """Recursively resolve playbook `pid`'s flattened step list at composition `depth` (1 =
    top-level, this playbook's own steps; 2+ = spliced in from one or more levels of
    composition). `visiting_path` is the list of playbook ids on the CURRENT resolution path
    (used for cycle detection -- see header). Returns a `(flattened_step_list, reason)` tuple:
    on success, `(flattened_step_list, None)`; on failure, `(None, reason)` where `reason` is
    THIS call's own specific failure message (E53_S06_T02 -- a stderr warning has already been
    printed, by this call or a nested one, exactly as before this task; the returned `reason` is
    the SAME text as the warning printed by this call, never a nested call's own separate
    message, so a top-level `resolve_playbook(pid, 1, [pid])` call's returned reason is always
    the one specifically attributable to `pid` itself)."""
    entry = raw[pid]
    path = entry["path"]
    normalized_steps = entry["normalized_steps"]

    flattened = []
    for idx, step in enumerate(normalized_steps):
        if isinstance(step, dict) and "playbook" in step:
            target_id = step["playbook"]

            if target_id not in raw:
                target_file = os.path.join(playbooks_dir, f"{target_id}.json")
                if os.path.isfile(target_file):
                    detail = "exists but failed its own local validation (see earlier warning for that file)"
                else:
                    detail = f"does not exist (no {target_id}.json found under {playbooks_dir})"
                reason = f"step {idx} references playbook '{target_id}', which {detail}"
                print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
                return None, reason

            if target_id in visiting_path:
                cycle_desc = " -> ".join(visiting_path + [target_id])
                reason = (
                    f"step {idx} references playbook '{target_id}', which creates a cyclic "
                    f"composition reference ({cycle_desc})"
                )
                print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
                return None, reason

            if depth + 1 > MAX_COMPOSITION_DEPTH:
                reason = (
                    f"step {idx} references playbook '{target_id}' at nesting depth "
                    f"{depth + 1}, which exceeds the configured max composition depth "
                    f"({MAX_COMPOSITION_DEPTH})"
                )
                print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
                return None, reason

            sub_flattened, _sub_reason = resolve_playbook(target_id, depth + 1, visiting_path + [target_id])
            if sub_flattened is None:
                reason = (
                    f"step {idx} references playbook '{target_id}', which could not be resolved "
                    f"(see prior warning)"
                )
                print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
                return None, reason

            flattened.extend(sub_flattened)
        else:
            # A depth-1 step (this playbook's own, un-composed step) is appended completely
            # unchanged here. A step that arrived via `flattened.extend(sub_flattened)` above was
            # already annotated by the deeper call that produced it (see the `if depth > 1` block
            # below, evaluated on THAT call's own `depth`). Origin annotation for THIS playbook's
            # own local steps (if this call itself is depth > 1, i.e. THIS playbook is itself
            # being composed) happens uniformly below, after this loop.
            flattened.append(step)

    # --- Origin annotation (E53_S05_T01) ---------------------------------------------------------
    # Only applied when THIS resolution itself is nested (depth > 1) -- a top-level playbook's own
    # steps (depth == 1) are left completely untouched, preserving the pre-existing bare-string
    # backward-compatibility guarantee (see header 'ORIGIN ANNOTATION'). `setdefault` ensures a
    # step that was already annotated by a DEEPER call (its true origin) is never overwritten here.
    if depth > 1:
        annotated = []
        for step in flattened:
            new_step = dict(step) if isinstance(step, dict) else {"skill": step}
            new_step.setdefault("_origin_playbook", pid)
            new_step.setdefault("_origin_depth", depth)
            annotated.append(new_step)
        flattened = annotated

    # --- Duplicate-name collision check (E53_S05_T01 AC #6) --------------------------------------
    seen = {}
    for idx, step in enumerate(flattened):
        name = step_skill_name(step)
        if name is None:
            continue  # defensive -- should not happen post-flatten (every playbook-type step was
                       # already replaced by its resolved contents above)
        if name in seen:
            reason = (
                f"flattened composition has duplicate skill name '{name}' (steps at position "
                f"{seen[name]} and {idx} both resolve to it)"
            )
            print(f"Warning: {path} {reason} — playbook skipped", file=sys.stderr)
            return None, reason
        seen[name] = idx

    return flattened, None


# --- PASS 3: forward_from/conditional validation over the FLATTENED list, then catalog assembly -
# (E53_S03_T03/T04, E53_S04_T02 -- retargeted at the fully flattened, composition-resolved step
# list as of E53_S05_T01/T02; see header 'FORWARD_FROM RESOLUTION' / 'CONDITIONAL RESOLUTION'.)

for pid in order:
    entry = raw[pid]
    path = entry["path"]

    flattened_steps, composition_reason = resolve_playbook(pid, 1, [pid])
    if flattened_steps is None:
        # a stderr warning was already printed by resolve_playbook (or a nested call);
        # composition_reason is THIS pid's own specific reason (E53_S06_T02).
        if composition_reason:
            skip_reasons[pid] = composition_reason
        continue

    validation_error = None
    for idx, step in enumerate(flattened_steps):
        if not isinstance(step, dict):
            continue

        # --- E53_S04_T02: conditional resolution (independent of forward_from -- a step may
        # carry either, both, or neither) ---
        if "conditional" in step:
            cond = step["conditional"]
            depends_on = cond["depends_on"]
            predicate = cond["predicate"]
            earlier_names = [step_skill_name(s) for s in flattened_steps[:idx]]
            if depends_on not in earlier_names:
                validation_error = (
                    f"step {idx} 'conditional.depends_on' names '{depends_on}', which is not an "
                    f"earlier skill step in this playbook"
                )
                break
            if not CONDITIONAL_PREDICATE_RE.match(predicate):
                validation_error = (
                    f"step {idx} 'conditional.predicate' is '{predicate}', which does not match "
                    f"the recognized grammar (non_empty/empty/equals:<value>/not_equals:<value>)"
                )
                break

        if "forward_from" not in step:
            continue

        source_name = step["forward_from"]
        earlier_names = [step_skill_name(s) for s in flattened_steps[:idx]]
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
        skip_reasons[pid] = validation_error
        continue

    catalog.append({
        "id": pid,
        "name": entry["name"],
        "description": entry["description"],
        "keywords": entry["keywords"],
        "examples": entry["examples"],
        "steps": flattened_steps,
    })

# --- E53_S06_T02: `lookup <id>` mode output ------------------------------------------------------
# Additive sibling to the full-catalog mode below -- see header "USAGE". Reuses the SAME PASS
# 1-3 pipeline and catalog/skip_reasons results above; never a separate implementation.
if mode == "lookup":
    result = None
    for lookup_entry in catalog:
        if lookup_entry["id"] == lookup_id:
            result = {"status": "valid", "playbook": lookup_entry}
            break
    if result is None:
        if lookup_id in skip_reasons:
            result = {"status": "invalid", "reason": skip_reasons[lookup_id]}
        elif f"{lookup_id}.json" in filenames:
            # Defensive fallback -- should not normally happen, since every basename scanned
            # into `filenames` either lands in `catalog` (valid) or `skip_reasons` (invalid) by
            # this point. Guards against ever silently reporting `not_found` for a file that
            # does exist on disk.
            result = {
                "status": "invalid",
                "reason": "failed validation (no specific reason captured)",
            }
        else:
            result = {"status": "not_found"}
    print(json.dumps(result, indent=2))
    sys.exit(0)

print(json.dumps(catalog, indent=2))
PY

python3 "$PY_SCRIPT" "$PLAYBOOKS_DIR" "$SKILLS_DIR" "$PROJECT_DIR" "$MODE" "$LOOKUP_ID"
exit $?

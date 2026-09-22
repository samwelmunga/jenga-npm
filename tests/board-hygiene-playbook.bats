#!/usr/bin/env bats
#
# Coverage for the board-hygiene playbook (E53_S11_T02) -- the first PUBLIC playbook that uses
# `forward_from` and `conditional` rather than being a flat bare-string chain:
#
#   j-reconcile  ->  j-todo (forward_from: j-reconcile, conditional: non_empty)  ->  j-status
#
# Why this suite runs against the REAL committed playbook
# ------------------------------------------------------
# Most playbook coverage in this repo is fixture-based (see load-playbooks-stepobject.bats's
# JENGA_PLAYBOOKS_TEST_ROOT convention), and rightly so: the interesting VALIDATION cases cannot
# be expressed against the real catalog. This suite is the deliberate exception, the same one
# load-playbooks-stepobject.bats makes for brainstorm-to-mirror: the claim under test is not
# "does the loader validate X" but "does THIS committed playbook, as shipped, load and behave" --
# which a fixture copy cannot answer.
#
# Why the runner inputs are DERIVED, not hand-copied
# --------------------------------------------------
# The conditional tests below feed run-playbook-step.sh a step list and a conditionals map read
# out of skills/jenga/playbooks/board-hygiene.json at test time. Hand-copying that chain into the
# test would mean the suite keeps passing after someone edits the playbook out from under it --
# it would be testing a private copy of a chain, not the shipped one. Deriving it means an edit
# to the playbook's steps or predicate is immediately reflected here.
#
# Artifact containment: JENGA_PLAYBOOK_RUNS_TEST_ROOT is exported for the WHOLE file (not just
# the persistence-flavoured tests), matching run-playbook-step-conditionals.bats's own reasoning
# -- every `advance ... passed <value>` call may attempt to persist an artifact, so this is what
# keeps the suite from ever writing into this repository's real project/logs/.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LOADER="$REPO_ROOT/skills/jenga/scripts/load-playbooks.sh"
RPS="$REPO_ROOT/skills/jenga/scripts/run-playbook-step.sh"
GUARD="$REPO_ROOT/scripts/check-public-playbook-steps.sh"
MATCHER="$REPO_ROOT/scripts/check-publicignore-match.sh"
PLAYBOOK="$REPO_ROOT/skills/jenga/playbooks/board-hygiene.json"

setup() {
  export JENGA_PLAYBOOK_RUNS_TEST_ROOT="$BATS_TEST_TMPDIR/runs-root"
  mkdir -p "$JENGA_PLAYBOOK_RUNS_TEST_ROOT"
}

# Comma-separated resolved step names, read from the committed playbook (see header).
derive_steps() {
  python3 - "$PLAYBOOK" <<'PY'
import json, sys
pb = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(s if isinstance(s, str) else s["skill"] for s in pb["steps"]))
PY
}

# The conditionals map run-playbook-step.sh's `init` takes as its 4th argument, in the shape
# {"<step>": {"depends_on": "...", "predicate": "..."}}, read from the committed playbook.
derive_conditionals() {
  python3 - "$PLAYBOOK" <<'PY'
import json, sys
pb = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps({
    s["skill"]: s["conditional"]
    for s in pb["steps"]
    if isinstance(s, dict) and "conditional" in s
}))
PY
}

# Runs `init` outside bats' `run` (these tests don't need init's own $output/$status) and
# captures the STATE_FILE path from stderr into $STATE_FILE -- the same helper shape
# run-playbook-step-conditionals.bats uses.
init_board_hygiene() {
  local stderr_file="$BATS_TEST_TMPDIR/init_stderr_$$_$RANDOM"
  bash "$RPS" init "board-hygiene" "Board Hygiene" \
    "$(derive_steps)" "$(derive_conditionals)" >/dev/null 2>"$stderr_file"
  STATE_FILE="$(grep 'STATE_FILE:' "$stderr_file" | sed 's/STATE_FILE: //')"
}

# -----------------------------------------------------------------------------
# Catalog: the committed playbook loads, cleanly, with its StepObject intact
# -----------------------------------------------------------------------------

@test "board-hygiene loads from the real committed catalog with no warning about it" {
  run bash "$LOADER"
  [ "$status" -eq 0 ]
  assert_output_contains '"id": "board-hygiene"'
  # bats' `run` merges stderr into $output, so a loader warning naming this playbook would show
  # up here. Scoped to this playbook's own filename rather than a blanket "no Warning: anywhere",
  # which would couple this suite to every OTHER playbook's health.
  assert_output_not_contains 'board-hygiene.json'
}

@test "board-hygiene's id matches its filename basename" {
  run python3 - "$PLAYBOOK" <<'PY'
import json, os, sys
pb = json.load(open(sys.argv[1], encoding="utf-8"))
basename = os.path.basename(sys.argv[1])[: -len(".json")]
assert pb["id"] == basename, (pb["id"], basename)
print("id matches basename")
PY
  [ "$status" -eq 0 ]
  assert_output_contains "id matches basename"
}

@test "the j-todo step reaches the catalog carrying both forward_from and its conditional" {
  run bash "$LOADER"
  [ "$status" -eq 0 ]

  CATALOG_FILE="$BATS_TEST_TMPDIR/catalog_$$.json"
  printf '%s' "$output" > "$CATALOG_FILE"

  # Written to a temp file first rather than interpolated into a python -c string, avoiding any
  # shell/JSON quoting hazard (same approach as load-playbooks-stepobject.bats).
  run python3 - "$CATALOG_FILE" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1], encoding="utf-8"))
entry = next(pb for pb in catalog if pb["id"] == "board-hygiene")
names = [s if isinstance(s, str) else s["skill"] for s in entry["steps"]]
assert names == ["j-reconcile", "j-todo", "j-status"], names

todo = next(s for s in entry["steps"] if isinstance(s, dict) and s.get("skill") == "j-todo")
assert todo["forward_from"] == "j-reconcile", todo
assert todo["conditional"] == {"depends_on": "j-reconcile", "predicate": "non_empty"}, todo

# The chain's other two steps stay bare strings -- never rewritten into object form.
assert isinstance(entry["steps"][0], str), entry["steps"][0]
assert isinstance(entry["steps"][2], str), entry["steps"][2]
print("stepobject intact")
PY
  [ "$status" -eq 0 ]
  assert_output_contains "stepobject intact"
}

@test "board-hygiene's conditional predicate is one run-playbook-step.sh actually recognizes" {
  # Guards against an invented predicate that would load fine at the shape level but never
  # evaluate. The grammar's single source of truth is run-playbook-step.sh's own PREDICATE_RE,
  # so this reads the predicate out of that script rather than restating it.
  run python3 - "$PLAYBOOK" "$RPS" <<'PY'
import json, re, sys
pb = json.load(open(sys.argv[1], encoding="utf-8"))
script = open(sys.argv[2], encoding="utf-8").read()

m = re.search(r"PREDICATE_RE = re\.compile\(r'([^']+)'\)", script)
assert m, "could not locate PREDICATE_RE in run-playbook-step.sh"
grammar = re.compile(m.group(1))

predicates = [
    s["conditional"]["predicate"]
    for s in pb["steps"]
    if isinstance(s, dict) and "conditional" in s
]
assert predicates, "board-hygiene declares no conditional at all"
for p in predicates:
    assert grammar.match(p), (p, m.group(1))
print("predicates recognized:", ",".join(predicates))
PY
  [ "$status" -eq 0 ]
  assert_output_contains "predicates recognized: non_empty"
}

# -----------------------------------------------------------------------------
# Branch 1 (SKIP): j-reconcile found no drift -> j-todo is skipped, chain continues
# -----------------------------------------------------------------------------

@test "j-todo is SKIPPED when j-reconcile's captured output is empty" {
  init_board_hygiene

  # The first step carries no conditional, so it always runs.
  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
  assert_output_contains '"step": "j-reconcile"'

  # j-reconcile passes having captured NO value -- a clean board, no drift found.
  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": true'
  assert_output_contains '"step": "j-todo"'
  assert_output_contains '"depends_on": "j-reconcile"'
  assert_output_contains '"predicate": "non_empty"'
}

@test "a skipped j-todo does not halt the chain -- j-status still runs and the chain completes" {
  init_board_hygiene

  bash "$RPS" advance "$STATE_FILE" passed >/dev/null 2>&1

  run bash "$RPS" advance "$STATE_FILE" skipped
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "step_ready"'
  assert_output_contains '"step": "j-status"'

  run bash "$RPS" advance "$STATE_FILE" passed
  [ "$status" -eq 0 ]
  assert_output_not_contains '"status": "halted"'
}

# -----------------------------------------------------------------------------
# Branch 2 (RUN): j-reconcile found drift -> j-todo runs, and receives the forwarded value
# -----------------------------------------------------------------------------

@test "j-todo RUNS when j-reconcile's captured output is non-empty" {
  init_board_hygiene

  # j-reconcile passes having captured board ids -- drift was found. The value shape matches
  # j-reconcile's declared output_types (id_list, landed by E53_S11_T01).
  bash "$RPS" advance "$STATE_FILE" passed "E53_S11_T01,E53_S11_T02" >/dev/null 2>&1

  run bash "$RPS" should-skip "$STATE_FILE"
  [ "$status" -eq 0 ]
  assert_output_contains '"skip": false'
  assert_output_contains '"step": "j-todo"'
}

@test "a running j-todo can resolve its forward_from source via get-output" {
  init_board_hygiene

  bash "$RPS" advance "$STATE_FILE" passed "E53_S11_T01,E53_S11_T02" >/dev/null 2>&1

  # This is the value the forward_from step is invoked WITH -- the conditional deciding to run
  # and the forwarded value actually being retrievable are two separate claims.
  #
  # E62_S02_T01: j-reconcile declares `output_types: id_list`, and this raw comma-joined value is
  # ONE line, so id_list's `per_line` rule does not match it as given -- it only conforms after
  # the type's own `normalize` ([split_on_comma, trim, drop_empty]) splits it into two lines.
  # get-output therefore now (correctly) returns the NORMALIZED value that was actually stored,
  # not the raw pre-normalization string -- this is runtime type verification doing exactly what
  # it is for, not a regression in what forward_from resolves.
  run bash "$RPS" get-output "$STATE_FILE" "j-reconcile"
  [ "$status" -eq 0 ]
  assert_output_contains '"status": "found"'
  assert_output_contains "$(printf 'E53_S11_T01\\nE53_S11_T02')"
}

# -----------------------------------------------------------------------------
# Public-playbook compliance
# -----------------------------------------------------------------------------

@test "board-hygiene is public -- .publicignore does not block it" {
  run bash "$MATCHER" "skills/jenga/playbooks/board-hygiene.json"
  [ "$status" -eq 0 ]
  assert_output_contains "PUBLIC"
  assert_output_not_contains "BLOCKED"
}

@test "the public-playbook guard passes with board-hygiene in the catalog" {
  # Deliberately asserts exit status and the absence of a violation, never the playbook COUNTS --
  # those legitimately differ between this private repo and the public mirror (brainstorm-to-mirror
  # and project/.playbooks/ are both absent there). Same reasoning as the real-repo test at the
  # bottom of check-public-playbook-steps.bats.
  run bash "$GUARD" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_output_not_contains "VIOLATION"
  assert_output_not_contains "board-hygiene"
}

@test "none of board-hygiene's steps is on the guard's terminal-step deny-list" {
  # Terminating at j-status rather than j-commit is intentional and compliant: E53_S10's rule
  # forbids publish/mirror STEPS, and this is a read/triage chain producing no commit of its own
  # (see docs/skill-authoring.md, "Public Playbooks Terminate at j-commit", consequence 3).
  # This asserts the mechanical half of that claim against the guard's own DATA block.
  run python3 - "$PLAYBOOK" "$GUARD" <<'PY'
import json, re, sys
pb = json.load(open(sys.argv[1], encoding="utf-8"))
guard = open(sys.argv[2], encoding="utf-8").read()

block = re.search(r"DENYLISTED_STEPS=\(([^)]*)\)", guard)
assert block, "could not locate DENYLISTED_STEPS in check-public-playbook-steps.sh"
denylisted = set(block.group(1).split())
assert denylisted, "DENYLISTED_STEPS parsed empty -- the assertion below would be vacuous"

names = [s if isinstance(s, str) else s.get("skill") for s in pb["steps"]]
offenders = [n for n in names if n in denylisted]
assert not offenders, offenders
print("no denylisted steps; chain =", ",".join(names))
PY
  [ "$status" -eq 0 ]
  assert_output_contains "no denylisted steps; chain = j-reconcile,j-todo,j-status"
}

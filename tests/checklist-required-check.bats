#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for E99_S04_T03: the required checklist id declaration (templates/checklist-required-ids.json), the check
# script that compares it with the effective registry (scripts/checklist-required-check.sh), the read-only
# `checklist.sh registry` sub-command it selects the registry through, and the `jenga doctor` warning.
#
# Why it matters. scripts/foreground-preflight.sh hard-requires two checklist ids and exits 12 when the registry a
# consumer reads lacks them; nothing reported that before a /jenga run hit it (E99_S04). The declaration is the one
# list of such ids, so the drift cases below fail when it and the script disagree.
#
# Isolation. Every registry used here is a fixture under $BATS_TEST_TMPDIR, reached through checklist.sh's seams
# (JENGA_CHECKLISTS_FILE, JENGA_CHECKLISTS_DEFAULT_FILE) or, for jenga doctor, through a consumer fixture directory
# used as the working directory with those seams unset. The repository's own project/configs/checklists.json is never
# read as a fixture and never written. Every invocation has stdin from /dev/null (E43 rule).
#
# Written without being executed by its author; the tester runs it.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/checklist-required-check.sh"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
DECLARATION="$REPO_ROOT/templates/checklist-required-ids.json"
SHIPPED="$REPO_ROOT/templates/checklists.json"
FG="$REPO_ROOT/scripts/foreground-preflight.sh"

setup() {
  unset JENGA_PROJECT_ROOT JENGA_CHECKLISTS_FILE JENGA_CHECKLISTS_DEFAULT_FILE JENGA_CHECKLIST_REQUIRED_FILE
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  NO_INSTANCE="$TMP/no-instance/checklists.json"   # never created: "the project has no instance"
}

# without_ids <out> <id>...: the shipped default with the named items removed.
without_ids() {
  local out="$1"
  shift
  python3 - "$SHIPPED" "$out" "$@" <<'PY'
import json, sys
src, out, drop = sys.argv[1], sys.argv[2], set(sys.argv[3:])
data = json.load(open(src, encoding="utf-8"))
data["items"] = [i for i in data["items"] if i.get("id") not in drop]
json.dump(data, open(out, "w", encoding="utf-8"), indent=2)
PY
}

# declared_ids_for <script>: the declared ids required by <script>, sorted, one per line.
declared_ids_for() {
  python3 - "$DECLARATION" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(sorted(e["id"] for e in data["required"] if e["required_by"] == sys.argv[2])))
PY
}

# ---------------------------------------------------------------------------------------------- the declaration

@test "declaration: valid JSON that lists both foreground ids, each required by scripts/foreground-preflight.sh" {
  run --separate-stderr declared_ids_for scripts/foreground-preflight.sh </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'checkin-run-before-dispatch\ndispatch-cost-and-cadence')" ]
}

@test "declaration ships: templates/ is in package.json files and the file is not in .publicignore" {
  run python3 -c 'import json,sys; sys.exit(0 if "templates/" in json.load(open(sys.argv[1]))["files"] else 1)' \
    "$REPO_ROOT/package.json" </dev/null
  [ "$status" -eq 0 ]
  run grep -nE '^[+-]? *(templates/?(\*\*)?$|templates/checklist-required-ids\.json)' "$REPO_ROOT/.publicignore"
  [ "$status" -eq 1 ]
}

@test "drift: the ids foreground-preflight.sh hard-codes are exactly the ids declared for it" {
  # The script keeps its own constants (see the doc, "Required checklist ids"); this case is what stops them drifting.
  local in_script
  in_script="$(sed -nE 's/^(CHECKIN_ITEM|COST_ITEM)="([^"]+)"$/\2/p' "$FG" | sort)"
  [ "$(printf '%s\n' "$in_script" | grep -c .)" -eq 2 ]
  run --separate-stderr declared_ids_for scripts/foreground-preflight.sh </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$in_script" ]
}

@test "drift: every declared script exists and every declared id is an item of the shipped default" {
  run python3 - "$DECLARATION" "$SHIPPED" "$REPO_ROOT" <<'PY'
import json, os, sys
decl = json.load(open(sys.argv[1], encoding="utf-8"))
shipped = {i["id"] for i in json.load(open(sys.argv[2], encoding="utf-8"))["items"]}
bad = []
for e in decl["required"]:
    if not os.path.isfile(os.path.join(sys.argv[3], e["required_by"])):
        bad.append("no such script: " + e["required_by"])
    if e["id"] not in shipped:
        bad.append("not in templates/checklists.json: " + e["id"])
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------------------------- checklist.sh registry

@test "checklist.sh registry: names the project instance when it exists" {
  without_ids "$TMP/instance.json"
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$TMP/instance.json" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    bash "$CHECKLIST" registry </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/instance.json" ]
}

@test "checklist.sh registry: falls back to the shipped default, and prints nothing when neither exists" {
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$NO_INSTANCE" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    bash "$CHECKLIST" registry </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "$SHIPPED" ]
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$NO_INSTANCE" JENGA_CHECKLISTS_DEFAULT_FILE="$TMP/nope.json" \
    bash "$CHECKLIST" registry </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "checklist.sh registry: takes no arguments (exit 2)" {
  run --separate-stderr bash "$CHECKLIST" registry extra </dev/null
  [ "$status" -eq 2 ]
}

@test "the check script selects the registry through checklist.sh, not a copy of select_registry" {
  run grep -c '"$CHECKLIST_SH" registry' "$CHECK"
  [ "$output" -ge 1 ]
  # No second resolver of its own: no resolve-root.sh call and no checklists.json path outside comments.
  run bash -c "grep -v '^[[:space:]]*#' '$CHECK' | grep -nE 'resolve-root\\.sh|checklists\\.json'"
  [ "$status" -eq 1 ]
}

# ----------------------------------------------------------------------------------------------- the check

@test "check: shipped default only (no project instance) reports nothing and exits 0" {
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$NO_INSTANCE" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    bash "$CHECK" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check: a project instance without checkin-run-before-dispatch is reported (exit 10)" {
  without_ids "$TMP/instance.json" checkin-run-before-dispatch
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$TMP/instance.json" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    bash "$CHECK" </dev/null
  [ "$status" -eq 10 ]
  [ "$output" = "$(printf 'missing\tcheckin-run-before-dispatch\tscripts/foreground-preflight.sh\t%s' "$TMP/instance.json")" ]
}

@test "check: the instance wins over the shipped default (whole file): both ids missing are both reported" {
  without_ids "$TMP/instance.json" checkin-run-before-dispatch dispatch-cost-and-cadence
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$TMP/instance.json" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    bash "$CHECK" </dev/null
  [ "$status" -eq 10 ]
  [ "${#lines[@]}" -eq 2 ]
  assert_output_contains "checkin-run-before-dispatch"
  assert_output_contains "dispatch-cost-and-cadence"
}

@test "check: no registry at all reports every required id with registry 'none'" {
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$NO_INSTANCE" JENGA_CHECKLISTS_DEFAULT_FILE="$TMP/nope.json" \
    bash "$CHECK" </dev/null
  [ "$status" -eq 10 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *$'\t'none ]]
}

@test "check: an unreadable registry or declaration exits 1 and prints nothing on stdout" {
  printf '{ not json' > "$TMP/broken.json"
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$TMP/broken.json" bash "$CHECK" </dev/null
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run --separate-stderr env JENGA_CHECKLISTS_FILE="$NO_INSTANCE" JENGA_CHECKLISTS_DEFAULT_FILE="$SHIPPED" \
    JENGA_CHECKLIST_REQUIRED_FILE="$TMP/broken.json" bash "$CHECK" </dev/null
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "check: --help prints usage and exits 0; an unknown argument exits 2" {
  run --separate-stderr bash "$CHECK" --help </dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "usage:"
  run --separate-stderr bash "$CHECK" --bogus </dev/null
  [ "$status" -eq 2 ]
}

# ------------------------------------------------------------------------------------------------ jenga doctor

# doctor_in <dir>: `jenga doctor --dry-run` from consumer directory <dir>, non-interactive, with no checklist seam set.
doctor_in() {
  cd "$1" && node "$REPO_ROOT/bin/jenga.js" doctor --dry-run </dev/null
}

@test "doctor: warns about a project instance that lacks a required id, names the file and the remedy" {
  mkdir -p "$TMP/consumer/project/configs"
  without_ids "$TMP/consumer/project/configs/checklists.json" checkin-run-before-dispatch
  local before
  before="$(shasum "$TMP/consumer/project/configs/checklists.json")"
  run doctor_in "$TMP/consumer"
  [ "$status" -eq 0 ]
  assert_output_contains "$TMP/consumer/project/configs/checklists.json lacks 1 item id(s)"
  assert_output_contains "checkin-run-before-dispatch (required by scripts/foreground-preflight.sh)"
  assert_output_contains "Remedy:"
  assert_output_contains "j.checklist"
  # Warning only: the registry is not written.
  [ "$(shasum "$TMP/consumer/project/configs/checklists.json")" = "$before" ]
}

@test "doctor: prints nothing for this check when no required id is missing, and exits the same" {
  mkdir -p "$TMP/consumer-ok"
  run doctor_in "$TMP/consumer-ok"
  [ "$status" -eq 0 ]
  assert_output_not_contains "item id(s) a shipped script requires"
  assert_output_not_contains "Could not check the checklist registry"
}

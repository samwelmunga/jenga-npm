#!/usr/bin/env bats
#
# Coverage for the suggestion flow of scripts/checklist.sh -- suggest, pending, rejected, resolve (E67_S05_T04).
#
# Contract under test: the "SUGGESTIONS" section and the "EXIT CODES" table in the header comment of
# scripts/checklist.sh, plus the provenance rules of scripts/validate-checklists.sh (check_provenance) that the Scrum
# Master relies on when it turns an accepted suggestion into a registry item. The Scrum Master's review flow itself
# (agents/scrum-master.md) is agent prose and not testable here; this file tests the deterministic pieces it calls.
#
# Isolation. Every fixture (registry, rapports directory, rapports, candidate registries) is generated at test time
# into $BATS_TEST_TMPDIR. setup() points every seam of the checker into the temp dir, so the real rapports directory
# (project/rapports/) and the real registry (project/configs/checklists.json) are never read or written; one test
# proves it by snapshotting both around a full flow:
#   JENGA_CHECKLISTS_FILE          the project instance            -> $F (does not exist until a test writes it)
#   JENGA_CHECKLISTS_DEFAULT_FILE  the shipped default             -> a path that does not exist
#   JENGA_CHECKLIST_STATE_DIR      the tick store                  -> $STATE (unused here, pinned for safety)
#   JENGA_CHECKLIST_RAPPORTS_DIR   where suggestion rapports live  -> $RAP (created by the first suggest)
#   JENGA_CHECKLIST_NOW            the clock for stamps and ages   -> a fixed UTC instant
#   JENGA_PROJECT_ROOT             the resolved root               -> $PROJ (temp tree with a stub workflow.json)
#
# Streams. stdout carries the result, stderr every diagnostic. Tests use `run --separate-stderr` (helper `ck`), so
# $output is stdout only and $stderr is stderr only. Every refusal test asserts the exit code, that stdout is empty,
# that stderr carries the specific reason, AND that nothing was written (a before/after snapshot of the rapports
# directory, lock directories and temp files included).
#
# Concurrency tests really run parallel writers (8 to 10 background processes against one rapports directory or one
# rapport), `wait`, then assert on the outcome. They are bounded: two rounds each, with with-lock.sh's poll interval
# lowered and its timeout raised (never lowered) so a slow machine cannot make them flaky.
#
# Exit codes pinned here: 0, 2, 20, 21, 22, 23, 24, 25, 26, 27, 28. Not tested, on purpose:
#   5  "internal error": a bug-only branch that no input reaches by design; there is nothing deterministic to feed it.
#   1  for these subcommands means "rapports directory cannot be resolved" (and invalid registry for list/check): the
#      seam makes the directory always resolvable, and list/check are covered by tests/checklist-sh.bats.
#   25 is tested through its one deterministic cause, a rapports directory that cannot be created (its parent is a
#      regular file). A write failing mid-rename is not reproducible; the unwritable-directory variant is not used
#      because it does not fail when the suite runs as root.
#   28 (lock timeout) is tested with a real holder process taking the rapport's lock through scripts/with-lock.sh's
#      public interface, so the test does not depend on with-lock.sh's internal lock-directory naming. (The exit 8
#      case in tests/checklist-sh.bats instead pre-creates "$STATE/persistent.json.lock.d", a deliberate coupling to
#      that naming; it is the stand-in this test deliberately does NOT copy.)
#
# Known behaviours deliberately NOT asserted either way (a test here would fail the day someone changes them):
#   (a) two PENDING suggestions may share an item id under different slugs -- only an id that was rejected, or that is
#       already in the registry, is refused;
#   (b) a broken registry makes `suggest` warn and validate the item against the base situations only, unlike
#       list/check/tick, which exit 1;
#   (c) the exact result of transliterating non-ASCII slug characters: they are documented as dropped (never
#       transliterated), so tests assert only that the file name is plain [a-z0-9-] and stays inside the directory.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECKLIST="$REPO_ROOT/scripts/checklist.sh"
VALIDATE="$REPO_ROOT/scripts/validate-checklists.sh"

NOW0="2026-10-03T12:00:00Z"
OMIT="__omit__" # sentinel: leave the flag out entirely (as opposed to passing an empty value)
DEF_EVID="Developer ran the pre-commit hook twice and the lockfile changed without a matching manifest change."

setup() {
  T="$BATS_TEST_TMPDIR"
  F="$T/checklists.json"
  DEFAULT="$T/default-checklists.json"
  STATE="$T/state"
  RAP="$T/rapports"
  PROJ="$T/proj"
  mkdir -p "$PROJ/project/configs"
  echo '{}' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  export JENGA_CHECKLISTS_FILE="$F"
  export JENGA_CHECKLISTS_DEFAULT_FILE="$DEFAULT"
  export JENGA_CHECKLIST_STATE_DIR="$STATE"
  export JENGA_CHECKLIST_RAPPORTS_DIR="$RAP"
  export JENGA_CHECKLIST_NOW="$NOW0"
  unset JENGA_CHECKLIST_RUN_ID JENGA_CHECKLIST_ACTOR
  unset WITH_LOCK_TIMEOUT_SECONDS WITH_LOCK_POLL_SECONDS WITH_LOCK_STALE_SECONDS
}

# -----------------------------------------------------------------------------
# Runners
# -----------------------------------------------------------------------------

# ck <args...>: run the checker; $output is stdout, $stderr is stderr, $status the exit code.
ck() { run --separate-stderr bash "$CHECKLIST" "$@"; }

# opt <flag> <value>: append "<flag> <value>" to ARGS unless the value is the OMIT sentinel.
opt() { if [ "$2" != "$OMIT" ]; then ARGS+=("$1" "$2"); fi; }

# build_sug <origin>: fill ARGS with a complete, valid `suggest` command line. Every field has a default that a test
# overrides through its S_* variable (set to $OMIT to drop the flag, to "" to pass an empty value).
build_sug() {
  ARGS=(suggest)
  opt --origin "$1"
  opt --evidence "${S_EVID-$DEF_EVID}"
  opt --id "${S_ID-skip-lockfile-drift}"
  opt --text "${S_TEXT-Confirm the lockfile only changed together with its manifest.}"
  opt --situation "${S_SIT-pre-commit}"
  opt --kind "${S_KIND-judgment}"
  opt --enforcement "${S_ENF-confirm}"
  opt --tick-scope "${S_SCOPE-persistent}"
  opt --by "${S_BY-agent:developer}"
}

# sug <origin> [extra flags...]: run `suggest` with the defaults above; extra flags are appended verbatim.
sug() {
  local origin="$1"
  shift
  build_sug "$origin"
  ck "${ARGS[@]}" "$@"
}

# sug_ok <origin> [extra flags...]: sug, asserted successful; leaves the new rapport's path in $RPT.
sug_ok() {
  sug "$@"
  [ "$status" -eq 0 ] || { echo "suggest failed ($status): $stderr" >&2; return 1; }
  RPT="$output"
  [ -f "$RPT" ]
}

# sug_bg <out-file> <status-file> <origin> [extra flags...]: one `suggest` as a background-safe writer.
sug_bg() {
  local out="$1" st="$2" origin="$3" rc=0
  shift 3
  build_sug "$origin"
  bash "$CHECKLIST" "${ARGS[@]}" "$@" >"$out" 2>"$out.err" || rc=$?
  echo "$rc" > "$st"
}

# res_bg <out-file> <status-file> <rapport> <outcome> <actor>: one `resolve` as a background-safe writer.
res_bg() {
  local out="$1" st="$2" rc=0
  bash "$CHECKLIST" resolve "$3" "$4" --by "$5" >"$out" 2>"$out.err" || rc=$?
  echo "$rc" > "$st"
}

# -----------------------------------------------------------------------------
# Fixtures and readers
# -----------------------------------------------------------------------------

# snap <dir>: a listing of every entry under <dir> (lock directories and temp files included) with a checksum of every
# file, so "nothing was written" is a before/after equality. An absent directory snapshots as "(absent)".
snap() {
  [ -e "$1" ] || { echo "(absent)"; return 0; }
  (
    cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
      if [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi
    done
  )
}

# registry_with <item-json>...: a valid project instance at $F declaring the extra situation "pre-deploy".
registry_with() {
  printf '%s\n' "$@" | jq -s '{checklist_version: 1, situations: ["pre-deploy"], items: .}' > "$F"
}

# reg_item <id>: a minimal valid registry item.
reg_item() {
  jq -n --arg id "$1" '{id: $id, text: "Existing item.", situations: ["pre-commit"], kind: "judgment",
                        enforcement: "confirm", tick_scope: "persistent"}'
}

# make_plain_rapport <name>: an ordinary (non-suggestion) problem rapport directly inside $RAP.
make_plain_rapport() {
  mkdir -p "$RAP"
  printf '# Rapport: plain\n\n**Type:** `blocking_issue`\n\n---\n\n## Ignore Log\n_placeholder_\n' > "$RAP/$1"
}

# section <file> <heading>: the lines under "## <heading>" up to the next "## " heading.
section() { awk -v h="## $2" '$0 == h {f = 1; next} /^## / {f = 0} f' "$1"; }

# proposed_item <file>: the fenced JSON under "## Proposed Item".
proposed_item() { awk '/^## Proposed Item$/ {s = 1; next} s && /^```json$/ {f = 1; next} f && /^```$/ {exit} f' "$1"; }

# count_outcome_headings <file>: how many "## Suggestion Outcome" headings the rapport has.
count_outcome_headings() { grep -c '^## Suggestion Outcome$' "$1" || true; }

# assert_prefix_preserved <before-copy> <after-file>: every byte of <before-copy> is still the start of <after-file>.
assert_prefix_preserved() {
  local n
  n="$(wc -c < "$1" | tr -d ' ')"
  head -c "$n" "$2" | cmp -s - "$1" || { echo "the first $n bytes of $2 changed" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# suggest: success paths
# -----------------------------------------------------------------------------

@test "suggest: a valid precautionary suggestion is filed, and stdout is only the rapport path" {
  sug precautionary
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(dirname "$output")" = "$RAP" ]
  [ "$(basename "$output")" = "skip-lockfile-drift-checklist-suggestion.md" ]
  [ -f "$output" ]
  [ "$(ls -A "$RAP" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "suggest: the rapport is well-formed (header, fenced item JSON, evidence, untouched Ignore Log placeholder)" {
  sug_ok precautionary
  local r="$RPT"
  assert_starts_with "$(head -1 "$r")" "# Rapport: "
  grep -qF '**Type:** `checklist_suggestion`' "$r"
  grep -qF '**Origin:** `precautionary`' "$r"
  grep -qF '**Proposed Item ID:** `skip-lockfile-drift`' "$r"
  grep -qF '**Suggested By:** agent:developer' "$r"
  grep -qF "**Suggested At:** $NOW0" "$r"
  grep -qF '**Date:** 2026-10-03 (UTC)' "$r"
  grep -qF '**Related Task:** N/A' "$r"

  # the proposed item is exactly the one given, as parseable JSON
  [ "$(proposed_item "$r" | jq -c -S .)" = "$(jq -c -S -n '{id: "skip-lockfile-drift",
      text: "Confirm the lockfile only changed together with its manifest.", situations: ["pre-commit"],
      kind: "judgment", enforcement: "confirm", tick_scope: "persistent"}')" ]

  # the evidence is present, quoted
  [ "$(section "$r" Evidence | grep -v '^$' | grep -v '^---$')" = "> $DEF_EVID" ]
  # a precautionary suggestion names no incident
  [ "$(grep -c '^## Originating Incident$' "$r" || true)" -eq 0 ]
  # no outcome yet, and the Ignore Log is the template's, byte for byte
  [ "$(count_outcome_headings "$r")" -eq 0 ]
  # (trailing whitespace is ignored: the template's last line ends in a space and has no newline)
  [ "$(section "$r" "Ignore Log" | sed 's/[[:space:]]*$//')" = "$(awk '/^## Ignore Log$/ {f = 1; next} /^## / {f = 0} f' "$REPO_ROOT/templates/PROBLEM_RAPPORT_TEMPLATE.md" | sed 's/[[:space:]]*$//')" ]
  assert_contains "$(section "$r" "Ignore Log")" '**Ignored by:** Developer'
  assert_contains "$(section "$r" "Ignore Log")" '**Date:** YYYY-MM-DD (UTC)'
}

@test "suggest: --task fills the Related fields of the rapport header" {
  sug_ok precautionary --task E67_S05_T04
  grep -qF '**Related Task:** E67_S05_T04' "$RPT"
}

@test "suggest: a machine item carries its --verify command into the proposed item" {
  S_KIND=machine sug_ok precautionary --verify "bash scripts/validate-checklists.sh"
  [ "$(proposed_item "$RPT" | jq -r .kind)" = "machine" ]
  [ "$(proposed_item "$RPT" | jq -r .verify)" = "bash scripts/validate-checklists.sh" ]
}

@test "suggest: several --situation flags, including one the loaded registry declares, are all accepted" {
  registry_with "$(reg_item existing-item)"
  sug_ok precautionary --situation pre-deploy
  [ "$(proposed_item "$RPT" | jq -c .situations)" = '["pre-commit","pre-deploy"]' ]
}

@test "suggest: a valid recurrence naming a rapport path as the incident is filed with that incident" {
  sug_ok recurrence --incident "rapports/problems/lockfile-drift.md"
  grep -qF '**Origin:** `recurrence`' "$RPT"
  assert_contains "$(section "$RPT" "Originating Incident")" "> rapports/problems/lockfile-drift.md"
  [ "$(count_outcome_headings "$RPT")" -eq 0 ]
}

@test "suggest: a valid recurrence naming a commit SHA as the incident is filed with that incident" {
  sug_ok recurrence --incident "a1b2c3d4e5f"
  grep -qF '**Origin:** `recurrence`' "$RPT"
  assert_contains "$(section "$RPT" "Originating Incident")" "> a1b2c3d4e5f"
}

@test "suggest: a valid recurrence naming a task id as the incident is filed with that incident" {
  sug_ok recurrence --incident "E67_S05_T02"
  grep -qF '**Origin:** `recurrence`' "$RPT"
  assert_contains "$(section "$RPT" "Originating Incident")" "> E67_S05_T02"
}

@test "suggest: the actor falls back to JENGA_CHECKLIST_ACTOR when --by is not given" {
  S_BY="$OMIT" JENGA_CHECKLIST_ACTOR="agent:tester" sug_ok precautionary
  grep -qF '**Suggested By:** agent:tester' "$RPT"
}

# -----------------------------------------------------------------------------
# suggest: refusals (each its own exit code and message, and nothing written)
# -----------------------------------------------------------------------------

# assert_refused <exit-code> <stderr-substring>: the last `run` refused with that code and message, wrote nothing to
# stdout, and left the rapports directory exactly as it was before (compared against $BEFORE, taken by the caller).
assert_refused() {
  [ "$status" -eq "$1" ] || { echo "expected exit $1, got $status; stderr: $stderr" >&2; return 1; }
  [ -z "$output" ]
  assert_contains "$stderr" "$2"
  [ "$(snap "$RAP")" = "$BEFORE" ] || { echo "the refusal changed the rapports directory:" >&2; snap "$RAP" >&2; return 1; }
}

@test "exit 20: a precautionary suggestion with no --evidence is refused" {
  BEFORE="$(snap "$RAP")"
  S_EVID="$OMIT" sug precautionary
  assert_refused 20 "evidence"
}

@test "exit 20: an empty --evidence is refused" {
  BEFORE="$(snap "$RAP")"
  S_EVID="" sug precautionary
  assert_refused 20 "evidence"
}

@test "exit 20: a whitespace-only --evidence is refused" {
  BEFORE="$(snap "$RAP")"
  S_EVID="   " sug precautionary
  assert_refused 20 "evidence"
}

@test "exit 20: a recurrence with no evidence is refused for the evidence (checked before the incident)" {
  BEFORE="$(snap "$RAP")"
  S_EVID="$OMIT" sug recurrence
  assert_refused 20 "evidence"
}

@test "exit 21: a recurrence with no --incident is refused" {
  BEFORE="$(snap "$RAP")"
  sug recurrence
  assert_refused 21 "incident"
}

@test "exit 21: the incident requirement is specific to recurrence -- a precautionary suggestion with no --incident is filed" {
  sug_ok precautionary
}

@test "exit 22: an item missing a required field is refused with the validator's message" {
  BEFORE="$(snap "$RAP")"
  S_KIND="$OMIT" sug precautionary
  assert_refused 22 "kind"
}

@test "exit 22: an item naming an unknown situation is refused" {
  BEFORE="$(snap "$RAP")"
  S_SIT="pre-lunch" sug precautionary
  assert_refused 22 "pre-lunch"
}

@test "exit 22: a malformed (non kebab-case) item id is refused" {
  BEFORE="$(snap "$RAP")"
  S_ID="Not Kebab Case" sug precautionary
  assert_refused 22 "malformed id"
}

@test "exit 22: a machine item with no --verify is refused" {
  BEFORE="$(snap "$RAP")"
  S_KIND=machine sug precautionary
  assert_refused 22 "verify"
}

@test "exit 22: an item with an invalid enforcement value is refused" {
  BEFORE="$(snap "$RAP")"
  S_ENF="sometimes" sug precautionary
  assert_refused 22 "enforcement"
}

@test "exit 22: an item whose id is already in the registry is refused, naming the id" {
  registry_with "$(reg_item skip-lockfile-drift)"
  BEFORE="$(snap "$RAP")"
  sug precautionary
  assert_refused 22 "skip-lockfile-drift"
}

@test "exit 22: an id that is NOT in the registry is not refused (the refusal is specific to the duplicate)" {
  registry_with "$(reg_item some-other-item)"
  sug_ok precautionary
}

@test "exit 23: an --incident that names no incident is refused (recurrence)" {
  BEFORE="$(snap "$RAP")"
  sug recurrence --incident "it happened again last week"
  assert_refused 23 "incident"
}

@test "exit 23: an --incident that names no incident is refused for a precautionary suggestion too" {
  BEFORE="$(snap "$RAP")"
  sug precautionary --incident "somewhere, sometime"
  assert_refused 23 "incident"
}

@test "exit 24: an item id that was previously rejected is not re-proposed" {
  sug_ok precautionary
  ck resolve "$RPT" rejected --reason "too noisy"
  [ "$status" -eq 0 ]
  BEFORE="$(snap "$RAP")"
  sug precautionary
  assert_refused 24 "rejected"
  assert_contains "$stderr" "skip-lockfile-drift"
}

@test "exit 24: rejecting one id does not block a suggestion for a different id" {
  sug_ok precautionary
  ck resolve "$RPT" rejected --reason "too noisy"
  [ "$status" -eq 0 ]
  S_ID="another-item" sug_ok precautionary
}

@test "exit 2: a bad --origin is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  sug "sometimes"
  assert_refused 2 "origin"
}

@test "exit 2: a missing --origin is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  sug "$OMIT"
  assert_refused 2 "origin"
}

@test "exit 2: an unknown flag is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  sug precautionary --frobnicate yes
  assert_refused 2 "frobnicate"
}

@test "exit 2: a flag with no value is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  sug precautionary --slug
  assert_refused 2 "slug"
}

@test "exit 2: a bad --by actor is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  S_BY="not a valid actor!" sug precautionary
  assert_refused 2 "actor"
}

@test "exit 2: a bad --task id is a usage error and writes nothing" {
  BEFORE="$(snap "$RAP")"
  sug precautionary --task "not-a-task"
  assert_refused 2 "task"
}

@test "refusal order: evidence (20), then incident required (21), then item (22), then incident (23), then rejected (24)" {
  # evidence missing wins over a missing incident and an invalid item
  S_EVID="$OMIT" S_KIND="$OMIT" sug recurrence
  [ "$status" -eq 20 ]
  # incident required wins over an invalid item
  S_KIND="$OMIT" sug recurrence
  [ "$status" -eq 21 ]
  # an invalid item wins over a bad incident
  S_KIND="$OMIT" sug recurrence --incident "nothing to see"
  [ "$status" -eq 22 ]
  # a bad incident wins over a rejected id
  sug_ok precautionary
  ck resolve "$RPT" rejected
  [ "$status" -eq 0 ]
  sug recurrence --incident "nothing to see"
  [ "$status" -eq 23 ]
  # and the rejected id is refused once everything else is right
  sug recurrence --incident "E67_S05_T02"
  [ "$status" -eq 24 ]
}

@test "exit 25: a rapports directory that cannot be created is reported and nothing is written" {
  : > "$T/a-file"
  JENGA_CHECKLIST_RAPPORTS_DIR="$T/a-file/sub" sug precautionary
  [ "$status" -eq 25 ]
  [ -z "$output" ]
  assert_contains "$stderr" "could not write the suggestion rapport"
  [ -f "$T/a-file" ] && [ ! -s "$T/a-file" ]
}

# -----------------------------------------------------------------------------
# suggest: slug handling and name collisions
# -----------------------------------------------------------------------------

@test "slug: ../ traversal is sanitised and the file stays inside the rapports directory" {
  sug_ok precautionary --slug "../../escape"
  [ "$(dirname "$RPT")" = "$RAP" ]
  [ "$(basename "$RPT")" = "escape-checklist-suggestion.md" ]
  # nothing was created next to, or above, the rapports directory
  [ "$(find "$T" -name '*escape*' | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -e "$T/escape-checklist-suggestion.md" ]
  [ ! -e "$T/../escape-checklist-suggestion.md" ]
}

@test "slug: an absolute path as the slug is sanitised and the file stays inside the rapports directory" {
  sug_ok precautionary --slug "/tmp/abs/path"
  [ "$(dirname "$RPT")" = "$RAP" ]
  [ "$(basename "$RPT")" = "tmp-abs-path-checklist-suggestion.md" ]
}

@test "slug: odd and non-ASCII characters are sanitised to a plain [a-z0-9-] name inside the directory" {
  sug_ok precautionary --slug 'Ünï cödé!! Ω 日本語 $(touch pwned) `id` ; rm'
  [ "$(dirname "$RPT")" = "$RAP" ]
  local base
  base="$(basename "$RPT")"
  printf '%s' "$base" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*-checklist-suggestion\.md$' || { echo "unexpected name: $base" >&2; return 1; }
  [ ! -e "$T/pwned" ]
  [ ! -e "$PWD/pwned" ]
  [ "$(ls -A "$RAP" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "slug: a very long slug is capped so the file name stays bounded" {
  local long
  long="$(printf 'a%.0s' $(seq 1 200))"
  sug_ok precautionary --slug "$long"
  local base slug
  base="$(basename "$RPT")"
  slug="${base%-checklist-suggestion.md}"
  [ "${#slug}" -ge 1 ]
  [ "${#slug}" -le 64 ]
}

@test "collision: a second suggestion under the same slug gets a distinct file and the first is never clobbered" {
  S_ID=first-item sug_ok precautionary --slug shared
  local first="$RPT" first_sum
  first_sum="$(cksum < "$first")"
  S_ID=second-item sug_ok precautionary --slug shared
  local second="$RPT"
  [ "$first" != "$second" ]
  [ "$(dirname "$second")" = "$RAP" ]
  assert_starts_with "$(basename "$second")" "shared-checklist-suggestion"
  # the first rapport is byte-identical, and each file carries its own item
  [ "$(cksum < "$first")" = "$first_sum" ]
  [ "$(proposed_item "$first" | jq -r .id)" = "first-item" ]
  [ "$(proposed_item "$second" | jq -r .id)" = "second-item" ]
  [ "$(ls -A "$RAP" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "collision: a pre-existing file of the target name is never replaced" {
  mkdir -p "$RAP"
  printf 'precious hand-written content\n' > "$RAP/skip-lockfile-drift-checklist-suggestion.md"
  sug_ok precautionary
  [ "$RPT" != "$RAP/skip-lockfile-drift-checklist-suggestion.md" ]
  [ "$(cat "$RAP/skip-lockfile-drift-checklist-suggestion.md")" = "precious hand-written content" ]
  grep -qF '**Type:** `checklist_suggestion`' "$RPT"
}

# -----------------------------------------------------------------------------
# Concurrency: real parallel writers
# -----------------------------------------------------------------------------

@test "concurrency: 10 parallel suggests under the same slug all land with distinct files, none lost (2 rounds)" {
  local n=10 round i start=$SECONDS
  export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
  for round in 1 2; do
    local rd="$T/round-$round" slug="shared-r$round"
    mkdir -p "$rd"
    export JENGA_CHECKLIST_RAPPORTS_DIR="$rd/rapports"
    for i in $(seq 1 "$n"); do
      ( S_ID="item-r$round-$i"; sug_bg "$rd/out-$i" "$rd/st-$i" precautionary --slug "$slug" ) 3>&- &
    done
    wait

    # every writer succeeded, and each printed a distinct path
    [ "$(cat "$rd"/st-* | sort -u)" = "0" ] || { echo "round $round: a suggest failed" >&2; cat "$rd"/out-*.err >&2; return 1; }
    [ "$(cat "$rd"/out-? "$rd"/out-10 | sort -u | wc -l | tr -d ' ')" -eq "$n" ] || { echo "round $round: paths are not distinct" >&2; return 1; }
    # exactly $n rapports on disk and nothing else (no temp file, no lock directory left behind)
    [ "$(ls -A "$rd/rapports" | wc -l | tr -d ' ')" -eq "$n" ] || { echo "round $round: leftovers: $(ls -A "$rd/rapports")" >&2; return 1; }
    [ -f "$rd/rapports/$slug-checklist-suggestion.md" ]
    # none lost: every id is present exactly once, and every file is intact
    for i in $(seq 1 "$n"); do
      [ "$(grep -lF "\"id\": \"item-r$round-$i\"" "$rd"/rapports/*.md | wc -l | tr -d ' ')" -eq 1 ] || { echo "round $round: item $i lost or duplicated" >&2; return 1; }
    done
    for f in "$rd"/rapports/*.md; do
      grep -qF '**Type:** `checklist_suggestion`' "$f"
      proposed_item "$f" | jq -e .id >/dev/null
    done
  done
  [ $((SECONDS - start)) -lt 90 ]
}

@test "concurrency: 8 parallel resolves of one rapport yield exactly one success and the rest exit 27 (2 rounds)" {
  local n=8 round i start=$SECONDS
  export WITH_LOCK_TIMEOUT_SECONDS=45 WITH_LOCK_POLL_SECONDS=0.05
  for round in 1 2; do
    S_ID="racing-item-$round" sug_ok precautionary
    local rpt="$RPT" rd="$T/res-round-$round"
    mkdir -p "$rd"
    cp "$rpt" "$rd/before"
    for i in $(seq 1 "$n"); do
      res_bg "$rd/out-$i" "$rd/st-$i" "$rpt" accepted "agent:racer$i" 3>&- &
    done
    wait

    [ "$(grep -lx '0' "$rd"/st-* | wc -l | tr -d ' ')" -eq 1 ] || { echo "round $round: expected exactly one success: $(cat "$rd"/st-* | sort | uniq -c | tr '\n' ' ')" >&2; return 1; }
    [ "$(grep -lx '27' "$rd"/st-* | wc -l | tr -d ' ')" -eq $((n - 1)) ] || { echo "round $round: expected $((n - 1)) x exit 27: $(cat "$rd"/st-* | sort | uniq -c | tr '\n' ' ')" >&2; return 1; }
    # the outcome was written once, by the writer that won, and every earlier byte is intact
    [ "$(count_outcome_headings "$rpt")" -eq 1 ]
    [ "$(grep -c '^\*\*Outcome:\*\* ' "$rpt")" -eq 1 ]
    local winner
    winner="$(basename "$(grep -lx '0' "$rd"/st-*)" | sed 's/^st-//')"
    grep -qF "**Resolved By:** agent:racer$winner" "$rpt" || { echo "round $round: the file records a different winner than the one that exited 0" >&2; return 1; }
    assert_prefix_preserved "$rd/before" "$rpt"
    # no lock directory or temp file left behind
    [ "$(ls -A "$RAP" | grep -c 'lock\|tmp' || true)" -eq 0 ] || { echo "round $round: leftovers: $(ls -A "$RAP")" >&2; return 1; }
  done
  [ $((SECONDS - start)) -lt 90 ]
}

# -----------------------------------------------------------------------------
# pending
# -----------------------------------------------------------------------------

@test "pending: silent and exit 0 when the rapports directory does not exist" {
  ck pending
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -e "$RAP" ]
}

@test "pending: silent and exit 0 when the rapports directory is empty" {
  mkdir -p "$RAP"
  ck pending
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "pending: lists a suggestion in the documented 4-field TAB format" {
  S_ID=format-check sug_ok recurrence --incident "E67_S05_T02"
  JENGA_CHECKLIST_NOW="2026-10-03T12:12:30Z" ck pending
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{print NF}')" -eq 4 ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$RPT" ]
  [ "$(printf '%s\n' "$output" | cut -f2)" = "recurrence" ]
  [ "$(printf '%s\n' "$output" | cut -f3)" = "format-check" ]
  [ "$(printf '%s\n' "$output" | cut -f4)" = "12m" ]
}

@test "pending: the age uses the largest fitting unit (s, m, h, d)" {
  S_ID=age-check sug_ok precautionary
  JENGA_CHECKLIST_NOW="2026-10-03T12:00:45Z" ck pending
  [ "$(printf '%s\n' "$output" | cut -f4)" = "45s" ]
  JENGA_CHECKLIST_NOW="2026-10-03T17:00:00Z" ck pending
  [ "$(printf '%s\n' "$output" | cut -f4)" = "5h" ]
  JENGA_CHECKLIST_NOW="2026-10-06T12:00:00Z" ck pending
  [ "$(printf '%s\n' "$output" | cut -f4)" = "3d" ]
}

@test "pending: lists oldest first, independent of file name and creation order" {
  JENGA_CHECKLIST_NOW="2026-10-03T10:00:00Z" S_ID=oldest-item sug_ok precautionary --slug zzz-oldest
  local oldest="$RPT"
  JENGA_CHECKLIST_NOW="2026-10-03T12:00:00Z" S_ID=newest-item sug_ok precautionary --slug aaa-newest
  local newest="$RPT"
  JENGA_CHECKLIST_NOW="2026-10-03T11:00:00Z" S_ID=middle-item sug_ok precautionary --slug mmm-middle
  local middle="$RPT"
  JENGA_CHECKLIST_NOW="2026-10-03T13:00:00Z" ck pending
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | paste -sd' ' -)" = "$oldest $middle $newest" ]
  [ "$(printf '%s\n' "$output" | cut -f3 | paste -sd' ' -)" = "oldest-item middle-item newest-item" ]
}

@test "pending: lists only unresolved suggestions (a resolved one, accepted or rejected, drops out)" {
  S_ID=stays-pending sug_ok precautionary
  local stays="$RPT"
  S_ID=gets-accepted sug_ok precautionary
  local accepted="$RPT"
  S_ID=gets-rejected sug_ok precautionary
  local rejected="$RPT"
  ck pending
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]

  ck resolve "$accepted" accepted
  [ "$status" -eq 0 ]
  ck resolve "$rejected" rejected
  [ "$status" -eq 0 ]
  ck pending
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$stays" ]
  assert_output_not_contains "gets-accepted"
  assert_output_not_contains "gets-rejected"
}

@test "pending: skips *.IGNORE.md rapports" {
  S_ID=live-one sug_ok precautionary
  local live="$RPT"
  S_ID=ignored-one sug_ok precautionary
  mv "$RPT" "${RPT%.md}.IGNORE.md"
  ck pending
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$live" ]
  assert_output_not_contains "ignored-one"
}

@test "pending: does not list rapports that are not suggestions" {
  make_plain_rapport "E01_S01_T01-some-blocker.md"
  ck pending
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  S_ID=only-this sug_ok precautionary
  ck pending
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | cut -f3)" = "only-this" ]
}

@test "pending: is read-only (no file in the rapports directory changes)" {
  sug_ok precautionary
  local before
  before="$(snap "$RAP")"
  ck pending
  [ "$status" -eq 0 ]
  [ "$(snap "$RAP")" = "$before" ]
}

# -----------------------------------------------------------------------------
# resolve
# -----------------------------------------------------------------------------

# check_resolve <outcome>: file a suggestion, resolve it with a reason and actor, and assert the recorded outcome and
# that nothing before it (the Ignore Log included) moved by a byte.
check_resolve() {
  local outcome="$1"
  sug_ok precautionary
  cp "$RPT" "$T/before"
  local ignore_before
  ignore_before="$(section "$RPT" "Ignore Log")"

  ck resolve "$RPT" "$outcome" --reason "Reviewed with the user on 2026-10-03." --by agent:scrum-master
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$output" = "resolved $RPT as $outcome" ]

  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
  local out_section
  out_section="$(section "$RPT" "Suggestion Outcome")"
  assert_contains "$out_section" "**Outcome:** $outcome"
  assert_contains "$out_section" "**Resolved By:** agent:scrum-master"
  assert_contains "$out_section" "**Resolved At:** $NOW0"
  assert_contains "$out_section" "**Reason:** Reviewed with the user on 2026-10-03."

  # append-only: every earlier byte is intact, and the Ignore Log is exactly what it was
  assert_prefix_preserved "$T/before" "$RPT"
  [ "$(section "$RPT" "Ignore Log")" = "$ignore_before" ]
  # the outcome is NOT written into the Ignore Log
  assert_not_contains "$(section "$RPT" "Ignore Log")" "Suggestion Outcome"
  assert_not_contains "$(section "$RPT" "Ignore Log")" "$outcome"
}

@test "resolve: accepted records a Suggestion Outcome section and never modifies earlier bytes or the Ignore Log" {
  check_resolve accepted
}

@test "resolve: rejected records a Suggestion Outcome section and never modifies earlier bytes or the Ignore Log" {
  check_resolve rejected
}

@test "resolve: without --reason the outcome section has no Reason line" {
  sug_ok precautionary
  ck resolve "$RPT" accepted --by agent:scrum-master
  [ "$status" -eq 0 ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
  assert_contains "$(section "$RPT" "Suggestion Outcome")" "**Outcome:** accepted"
  assert_not_contains "$(section "$RPT" "Suggestion Outcome")" "**Reason:**"
}

@test "resolve: a bare file name inside the rapports directory is accepted" {
  sug_ok precautionary
  ck resolve "$(basename "$RPT")" accepted
  [ "$status" -eq 0 ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
}

@test "resolve: the actor falls back to JENGA_CHECKLIST_ACTOR when --by is not given" {
  sug_ok precautionary
  JENGA_CHECKLIST_ACTOR="agent:from-env" ck resolve "$RPT" accepted
  [ "$status" -eq 0 ]
  assert_contains "$(section "$RPT" "Suggestion Outcome")" "**Resolved By:** agent:from-env"
}

@test "exit 27: a second resolve with a different outcome is refused and the rapport is untouched" {
  sug_ok precautionary
  ck resolve "$RPT" accepted --reason "first"
  [ "$status" -eq 0 ]
  local before
  before="$(snap "$RAP")"
  ck resolve "$RPT" rejected --reason "second"
  [ "$status" -eq 27 ]
  [ -z "$output" ]
  assert_contains "$stderr" "accepted"
  [ "$(snap "$RAP")" = "$before" ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
  assert_not_contains "$(cat "$RPT")" "second"
}

@test "exit 27: a second resolve with the SAME outcome is refused too, and the rapport is untouched" {
  sug_ok precautionary
  ck resolve "$RPT" rejected --reason "first"
  [ "$status" -eq 0 ]
  local before
  before="$(snap "$RAP")"
  ck resolve "$RPT" rejected --reason "again"
  [ "$status" -eq 27 ]
  [ -z "$output" ]
  [ "$(snap "$RAP")" = "$before" ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
}

@test "exit 26: resolving a rapport that does not exist is refused" {
  mkdir -p "$RAP"
  local before
  before="$(snap "$RAP")"
  ck resolve "no-such-rapport.md" accepted
  [ "$status" -eq 26 ]
  [ -z "$output" ]
  assert_contains "$stderr" "no-such-rapport.md"
  [ "$(snap "$RAP")" = "$before" ]
}

@test "exit 26: resolving a path outside the rapports directory is refused and the file is untouched" {
  sug_ok precautionary
  cp "$RPT" "$T/elsewhere.md"
  local before_sum
  before_sum="$(cksum < "$T/elsewhere.md")"
  ck resolve "$T/elsewhere.md" accepted
  [ "$status" -eq 26 ]
  [ -z "$output" ]
  [ "$(cksum < "$T/elsewhere.md")" = "$before_sum" ]
  # a traversal that resolves to the same outside file is refused as well
  ck resolve "$RAP/../elsewhere.md" accepted
  [ "$status" -eq 26 ]
  [ "$(cksum < "$T/elsewhere.md")" = "$before_sum" ]
  # and the genuine rapport was not resolved by either attempt
  [ "$(count_outcome_headings "$RPT")" -eq 0 ]
}

@test "exit 26: resolving a rapport that is not a suggestion is refused and the file is untouched" {
  make_plain_rapport "E01_S01_T01-some-blocker.md"
  local before
  before="$(snap "$RAP")"
  ck resolve "$RAP/E01_S01_T01-some-blocker.md" accepted
  [ "$status" -eq 26 ]
  [ -z "$output" ]
  assert_contains "$stderr" "suggestion"
  [ "$(snap "$RAP")" = "$before" ]
}

@test "exit 26: resolving an .IGNORE.md rapport is refused and the file is untouched" {
  sug_ok precautionary
  mv "$RPT" "${RPT%.md}.IGNORE.md"
  local before
  before="$(snap "$RAP")"
  ck resolve "${RPT%.md}.IGNORE.md" accepted
  [ "$status" -eq 26 ]
  [ -z "$output" ]
  [ "$(snap "$RAP")" = "$before" ]
}

@test "exit 2: an outcome other than accepted or rejected is a usage error and the rapport is untouched" {
  sug_ok precautionary
  local before
  before="$(snap "$RAP")"
  ck resolve "$RPT" maybe
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_contains "$stderr" "accepted"
  [ "$(snap "$RAP")" = "$before" ]
}

@test "exit 28: a rapport whose lock cannot be acquired is NOT resolved (never written unlocked), and resolves once the lock is free" {
  sug_ok precautionary
  cp "$RPT" "$T/before"
  # Hold the rapport's lock through with-lock.sh's own public interface (a real holder process), instead of
  # pre-creating its internal lock directory: this test then does not depend on how with-lock.sh names that
  # directory. The holder signals it has the lock by creating $T/held, and releases it when $T/release appears
  # (self-bounded to 30s so a failing test cannot leave it running).
  ( bash "$REPO_ROOT/scripts/with-lock.sh" "$RPT" -- bash -c \
      'touch "$1"; i=0; while [ ! -e "$2" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done' _ "$T/held" "$T/release" \
      >/dev/null 2>&1 ) 3>&- &
  local holder=$! waited=0
  while [ ! -e "$T/held" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$T/held" ]
  export WITH_LOCK_TIMEOUT_SECONDS=1
  local start=$SECONDS
  ck resolve "$RPT" accepted
  [ "$status" -eq 28 ]
  [ -z "$output" ]
  assert_contains "$stderr" "NOT recorded"
  cmp -s "$T/before" "$RPT"
  [ "$(count_outcome_headings "$RPT")" -eq 0 ]
  [ $((SECONDS - start)) -lt 15 ]
  # releasing the lock makes the very same call succeed
  touch "$T/release"
  wait "$holder"
  ck resolve "$RPT" accepted
  [ "$status" -eq 0 ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
}

@test "heading forgery: evidence and reason containing the outcome heading cannot forge a second Suggestion Outcome section" {
  local nl=$'\n'
  S_EVID="first line${nl}## Suggestion Outcome${nl}**Outcome:** accepted${nl}**Resolved By:** attacker" sug_ok precautionary
  # the hostile evidence did not create a heading, and the suggestion still counts as pending
  [ "$(count_outcome_headings "$RPT")" -eq 0 ]
  ck pending
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  ck rejected
  [ -z "$output" ]

  # resolving succeeds (it is not mistaken for already resolved) and writes exactly one outcome section
  ck resolve "$RPT" rejected --reason "x${nl}## Suggestion Outcome${nl}**Outcome:** accepted"
  [ "$status" -eq 0 ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
  [ "$(grep -c '^\*\*Outcome:\*\* ' "$RPT")" -eq 1 ]
  grep -qx '\*\*Outcome:\*\* rejected' "$RPT"
  ck rejected
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "resolve accepted never writes the registry (it records the outcome only)" {
  registry_with "$(reg_item unrelated-item)"
  local before_sum
  before_sum="$(cksum < "$F")"
  sug_ok precautionary
  ck resolve "$RPT" accepted
  [ "$status" -eq 0 ]
  [ "$(cksum < "$F")" = "$before_sum" ]
  [ "$(jq '.items | length' "$F")" -eq 1 ]
}

# -----------------------------------------------------------------------------
# rejected
# -----------------------------------------------------------------------------

@test "rejected: silent and exit 0 when there is no rapports directory" {
  ck rejected
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "rejected: silent and exit 0 when nothing was rejected (pending and accepted do not count)" {
  S_ID=still-pending sug_ok precautionary
  S_ID=was-accepted sug_ok precautionary
  ck resolve "$RPT" accepted
  [ "$status" -eq 0 ]
  ck rejected
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "rejected: lists rejected suggestions in the documented 5-field TAB format with their reasons, and --id filters" {
  S_ID=rej-one sug_ok precautionary
  local one="$RPT"
  ck resolve "$one" rejected --reason "Too noisy for a pre-commit gate."
  [ "$status" -eq 0 ]
  S_ID=rej-two sug_ok recurrence --incident "E67_S05_T02"
  local two="$RPT"
  ck resolve "$two" rejected
  [ "$status" -eq 0 ]
  S_ID=accepted-one sug_ok precautionary
  ck resolve "$RPT" accepted
  [ "$status" -eq 0 ]
  S_ID=pending-one sug_ok precautionary

  ck rejected
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{print NF}' | sort -u)" = "5" ]
  assert_output_not_contains "accepted-one"
  assert_output_not_contains "pending-one"
  local row
  row="$(printf '%s\n' "$output" | awk -F'\t' '$3 == "rej-one"')"
  [ "$(printf '%s' "$row" | cut -f1)" = "$one" ]
  [ "$(printf '%s' "$row" | cut -f2)" = "precautionary" ]
  [ "$(printf '%s' "$row" | cut -f4)" = "$NOW0" ]
  [ "$(printf '%s' "$row" | cut -f5)" = "Too noisy for a pre-commit gate." ]
  # a rejection with no reason shows "-"
  row="$(printf '%s\n' "$output" | awk -F'\t' '$3 == "rej-two"')"
  [ "$(printf '%s' "$row" | cut -f2)" = "recurrence" ]
  [ "$(printf '%s' "$row" | cut -f5)" = "-" ]

  ck rejected --id rej-two
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | cut -f3)" = "rej-two" ]

  ck rejected --id never-suggested
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # --id for an id that exists but was not rejected is silent too
  ck rejected --id accepted-one
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# The accept path, end to end on the deterministic pieces
# -----------------------------------------------------------------------------

# accept_candidate <rapport> <origin> <evidence> [accepted_on]: write the registry the Scrum Master would write after the
# user confirms -- the rapport's proposed item plus its provenance block -- to $F.
accept_candidate() {
  local item
  item="$(proposed_item "$1" | jq -c --arg origin "$2" --arg evidence "$3" --arg on "${4-2026-10-03}" \
    '. + {provenance: ({source: "suggested", suggested_by: "agent:developer", origin: $origin, evidence: $evidence}
                       + (if $on == "" then {} else {accepted_on: $on} end))}')"
  jq -n --argjson item "$item" '{checklist_version: 1, situations: [], items: [$item]}' > "$F"
}

@test "accept path: suggest, accept into a candidate registry, validate clean with provenance, resolve accepted leaves the registry byte-identical" {
  sug_ok precautionary
  accept_candidate "$RPT" precautionary "$DEF_EVID"

  # the item landed in the registry with its provenance intact ...
  [ "$(jq -r '.items[0].id' "$F")" = "skip-lockfile-drift" ]
  [ "$(jq -r '.items[0].provenance.source' "$F")" = "suggested" ]
  [ "$(jq -r '.items[0].provenance.suggested_by' "$F")" = "agent:developer" ]
  [ "$(jq -r '.items[0].provenance.origin' "$F")" = "precautionary" ]
  [ "$(jq -r '.items[0].provenance.evidence' "$F")" = "$DEF_EVID" ]
  [ "$(jq -r '.items[0].provenance.accepted_on' "$F")" = "2026-10-03" ]

  # ... validates clean ...
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
  [ -z "$stderr" ]

  # ... and is a live item the checker lists
  ck list pre-commit
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = "skip-lockfile-drift" ]

  # resolving the suggestion as accepted records the outcome on the rapport and does not touch the registry
  local reg_before
  reg_before="$(cat "$F")"
  cp "$F" "$T/registry-before"
  ck resolve "$RPT" accepted --reason "Added to the registry." --by agent:scrum-master
  [ "$status" -eq 0 ]
  cmp -s "$T/registry-before" "$F"
  [ "$(cat "$F")" = "$reg_before" ]
  [ "$(count_outcome_headings "$RPT")" -eq 1 ]
  ck pending
  [ -z "$output" ]

  # once the item is in the registry, suggesting its id again is refused as a duplicate
  sug precautionary
  [ "$status" -eq 22 ]
  assert_contains "$stderr" "skip-lockfile-drift"
}

@test "accept path: a recurrence candidate whose evidence names the incident validates clean" {
  sug_ok recurrence --incident "E67_S05_T02"
  accept_candidate "$RPT" recurrence "Seen again in E67_S05_T02: $DEF_EVID"
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
  assert_output_contains "PASS $F"
}

@test "accept path: a recurrence candidate whose evidence names NO incident fails the validator (the rule the Scrum Master relies on)" {
  sug_ok precautionary
  accept_candidate "$RPT" recurrence "it happened again and again"
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_output_contains "FAIL $F"
  assert_contains "$stderr" "recurrence without incident"
}

@test "accept path: the same evidence is fine for a precautionary candidate (the incident rule is recurrence-only)" {
  sug_ok precautionary
  accept_candidate "$RPT" precautionary "it happened again and again"
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 0 ]
}

@test "accept path: a suggested item with no accepted_on fails the validator" {
  sug_ok precautionary
  accept_candidate "$RPT" precautionary "$DEF_EVID" ""
  run --separate-stderr bash "$VALIDATE" "$F"
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "accepted_on"
}

# -----------------------------------------------------------------------------
# Hygiene
# -----------------------------------------------------------------------------

@test "hygiene: a full suggest, pending, resolve, rejected flow leaves the real project/rapports and project/configs/checklists.json untouched" {
  local real_rapports="$REPO_ROOT/project/rapports" real_registry="$REPO_ROOT/project/configs/checklists.json"
  local rap_before reg_before status_before
  rap_before="$(snap "$real_rapports")"
  reg_before="$([ -e "$real_registry" ] && cksum < "$real_registry" || echo absent)"
  status_before="$(git -C "$REPO_ROOT" status --porcelain -- project/rapports project/configs 2>/dev/null || true)"

  S_ID=hygiene-one sug_ok precautionary
  S_ID=hygiene-two sug_ok recurrence --incident "E67_S05_T02"
  ck pending
  [ "$status" -eq 0 ]
  ck resolve "$RPT" rejected --reason "hygiene"
  [ "$status" -eq 0 ]
  ck rejected
  [ "$status" -eq 0 ]

  # everything the flow wrote is under the test's temp dir ...
  [ "$(dirname "$RPT")" = "$RAP" ]
  case "$RAP" in "$BATS_TEST_TMPDIR"/*) ;; *) echo "rapports dir escaped the temp dir: $RAP" >&2; return 1 ;; esac
  [ ! -e "$PROJ/project/rapports" ]
  # ... and the real locations are exactly as they were
  [ "$(snap "$real_rapports")" = "$rap_before" ]
  [ "$([ -e "$real_registry" ] && cksum < "$real_registry" || echo absent)" = "$reg_before" ]
  [ "$(git -C "$REPO_ROOT" status --porcelain -- project/rapports project/configs 2>/dev/null || true)" = "$status_before" ]
}

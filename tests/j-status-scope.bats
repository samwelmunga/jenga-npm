#!/usr/bin/env bats
#
# E92_S06_T15: skills/j-status/scripts/render-status-scope.sh - the extended `j.status <scope>` block: dependency tree,
# "Ready to take" and "X unlocked by Y", all taken from `board-progress.sh --graph --within <id>`.
#
# A stub board-progress.sh (JENGA_BOARD_PROGRESS test seam) supplies a fixed graph whose numbers are deliberately NOT
# derivable by counting or readiness logic, so a script that re-derived anything would disagree with the stub.
# The default label language is en.

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO/skills/j-status/scripts/render-status-scope.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_PROGRESS_LABELS
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
}

# mk_stub <variant>: "full" has edges, a ready task and two unlocked_by; "empty" has no edges and nothing ready;
# "notasks" has a story but no task at all (E92_S09_T01: only that one shows tree_empty).
mk_stub() {
  local variant="${1:-full}"
  {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$(dirname "$0")/args.txt"\ncat <<'"'"'JSON'"'"'\n'
    if [ "$variant" = "full" ]; then
      cat <<'JSON'
{"schema_version":1,"scope":{"type":"graph","within":"E07"},"external":[],"ready":["E07_S01_T02"],
 "epics":[{"id":"E07","title":"Epic seven","depends_on":[]}],
 "stories":[{"id":"E07_S01","epic_id":"E07","title":"Story one","depends_on":[],"complete":false,"stop":"in_progress"},
            {"id":"E07_S02","epic_id":"E07","title":"Story two","depends_on":["E07_S01"],"complete":false,"stop":"pending"}],
 "tasks":[{"id":"E07_S01_T01","story_id":"E07_S01","title":"First task","state":"done","depends_on":[],"unlocked_by":null},
          {"id":"E07_S01_T02","story_id":"E07_S01","title":"Second task","state":"ready","depends_on":["E07_S01_T01"],"unlocked_by":"E07_S01_T01"},
          {"id":"E07_S02_T01","story_id":"E07_S02","title":"Third task","state":"locked","depends_on":["E07_S01_T02"],"unlocked_by":null},
          {"id":"E07_S02_T02","story_id":"E07_S02","title":"Fourth task","state":"failed","depends_on":[],"unlocked_by":null},
          {"id":"E07_S02_T03","story_id":"E07_S02","title":"Fifth task","state":"in_progress","depends_on":["E07_S01_T01"],"unlocked_by":"E07_S01_T01"}],
 "warnings":[]}
JSON
    elif [ "$variant" = "notasks" ]; then
      cat <<'JSON'
{"schema_version":1,"scope":{"type":"graph","within":"E07"},"external":[],"ready":[],
 "epics":[{"id":"E07","title":"Epic seven","depends_on":[]}],
 "stories":[{"id":"E07_S01","epic_id":"E07","title":"Story one","depends_on":[],"complete":false,"stop":"pending"}],
 "tasks":[],
 "warnings":[]}
JSON
    else
      cat <<'JSON'
{"schema_version":1,"scope":{"type":"graph","within":"E07"},"external":[],"ready":[],
 "epics":[{"id":"E07","title":"Epic seven","depends_on":[]}],
 "stories":[{"id":"E07_S01","epic_id":"E07","title":"Story one","depends_on":[],"complete":false,"stop":"pending"}],
 "tasks":[{"id":"E07_S01_T01","story_id":"E07_S01","title":"First task","state":"locked","depends_on":[],"unlocked_by":null}],
 "warnings":[]}
JSON
    fi
    printf 'JSON\n'
  } > "$STUB_DIR/board-progress.sh"
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
}

@test "script has a bash shebang, parses under bash -n and is executable" {
  [ -x "$S" ]
  [ "$(head -n 1 "$S")" = "#!/usr/bin/env bash" ]
  run bash -n "$S"
  [ "$status" -eq 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$S" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"render-status-scope.sh <id>"* ]]
}

@test "epic id: tree, Ready to take and one unlocked-by line per unlocked_by, all from the stub" {
  mk_stub full
  run bash "$S" E7 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dependency tree"* ]]
  [[ "$output" == *"Story one"* ]]
  [[ "$output" == *"Story two"* ]]
  [[ "$output" == *"E07_S02_T01"*"Locked"*"Third task"* ]]
  [[ "$output" == *"E07_S01_T02"*"Ready"*"Second task"* ]]
  [[ "$output" == *"Ready to take"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'unlocked by')" -eq 2 ]
  [[ "$output" == *"E07_S01_T02 unlocked by E07_S01_T01"* ]]
  [[ "$output" == *"E07_S02_T03 unlocked by E07_S01_T01"* ]]
  [[ "$output" == *"●"* && "$output" == *"◉"* && "$output" == *"○"* && "$output" == *"⚑"* ]]
  [[ "$output" == *"━"* && "$output" == *"╌"* ]]
  [[ "$output" == *"○ E07_S01_T02 · Second task"* ]]
}

@test "board-progress is called with --graph --within <normalised id> (and --root when given)" {
  mk_stub full
  run bash "$S" e07_s01 --color never --root /some/root
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/args.txt")" = "--graph --within E07_S01 --root /some/root" ]
}

@test "story id: same block from the stub" {
  mk_stub full
  run bash "$S" E07_S01 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ready to take"* ]]
  [[ "$output" == *"unlocked by"* ]]
}

@test "stub proves no counting or readiness logic: states and ready are shown as given" {
  mk_stub full
  sed -i.bak 's/"state":"locked"/"state":"ready"/' "$STUB_DIR/board-progress.sh"
  run bash "$S" E07 --color never
  [[ "$output" == *"E07_S02_T01"*"Ready"*"Third task"* ]]
  # the ready list is the stub's ready array only; Third task has state ready but is not in .ready
  ready_block="$(printf '%s\n' "$output" | sed -n '/^Ready to take/,/^$/p')"
  [[ "$ready_block" != *"E07_S02_T01"* ]]
  [[ "$ready_block" == *"E07_S01_T02"* ]]
}

@test "JENGA_PROGRESS_LANG=sv gives the Swedish labels" {
  mk_stub full
  JENGA_PROGRESS_LANG=sv run bash "$S" E07 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"Beroendeträd"* ]]
  [[ "$output" == *"Redo att ta"* ]]
  [[ "$output" == *"E07_S01_T02 upplåst av E07_S01_T01"* ]]
  [[ "$output" == *"Låst"* && "$output" == *"Klar"* ]]
}

@test "NO_COLOR and a non-TTY give no ESC byte; --color always adds colour" {
  mk_stub full
  NO_COLOR=1 run bash "$S" E07
  [[ "$output" != *"$ESC"* ]]
  run bash "$S" E07
  [[ "$output" != *"$ESC"* ]]
  run bash "$S" E07 --color always
  [[ "$output" == *"$ESC["* ]]
}

@test "a non-UTF-8 locale gives only ASCII" {
  mk_stub full
  LC_ALL=C run bash "$S" E07 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"E07_S01_T02"* ]]
  [ -z "$(printf '%s' "$output" | LC_ALL=C tr -d '\011\012\015\040-\176')" ]
}

@test "a narrow --cols gives the flat fallback: no story titles or connectors, one node per line" {
  mk_stub full
  run bash "$S" E07 --cols 40 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"● E07_S01_T01 Done"* ]]
  [[ "$output" != *"Story one"* ]]
  [[ "$output" != *"━"* && "$output" != *"╌"* ]]
}

@test "no dependency edge still draws the tree (E92_S09_T01); nothing ready shows nothing_ready" {
  mk_stub empty
  run bash "$S" E07 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"Story one"* ]]
  [[ "$output" == *"E07_S01_T01"*"Locked"*"First task"* ]]
  [[ "$output" != *"No tasks in this scope"* ]]
  [[ "$output" != *"No dependencies"* ]]
  [[ "$output" == *"Nothing is ready to take right now"* ]]
  [[ "$output" != *"unlocked by"* ]]
}

@test "only a scope with no tasks shows tree_empty, in English and Swedish (E92_S09_T01)" {
  mk_stub notasks
  run bash "$S" E07 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tasks in this scope"* ]]
  [[ "$output" != *"Story one"* ]]
  JENGA_PROGRESS_LANG=sv run bash "$S" E07 --color never
  [ "$status" -eq 0 ]
  [[ "$output" == *"Inga uppgifter i detta omfång"* ]]
}

@test "failing board-progress.sh: one stderr warning, empty stdout, exit 0" {
  printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB_DIR/board-progress.sh"; chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
  run --separate-stderr bash "$S" E07
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == *"warning"* ]]
}

@test "missing board-progress.sh and malformed JSON: warning, empty stdout, exit 0" {
  JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/nope.sh" run --separate-stderr bash "$S" E07
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"* ]]
  printf '#!/usr/bin/env bash\necho "not json"\n' > "$STUB_DIR/board-progress.sh"; chmod +x "$STUB_DIR/board-progress.sh"
  JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh" run --separate-stderr bash "$S" E07
  [ "$status" -eq 0 ]; [ -z "$output" ]; [[ "$stderr" == *"warning"* ]]
}

@test "usage errors exit 2: missing id, malformed id, task id, unknown flag, bad colour" {
  mk_stub full
  run bash "$S";                      [ "$status" -eq 2 ]
  run bash "$S" banana;               [ "$status" -eq 2 ]
  run bash "$S" E07_S01_T01;          [ "$status" -eq 2 ]
  run bash "$S" E07 --bogus;          [ "$status" -eq 2 ]
  run bash "$S" E07 --color purple;   [ "$status" -eq 2 ]
}

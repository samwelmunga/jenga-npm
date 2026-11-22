#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S05_T04: skills/j-status/scripts/render-status-bars.sh - one `<id><TAB><bar>` line per epic and per story, made by
# piping `board-progress.sh --by-parent` into `render-progress-bar.sh --each epics|stories` (one board read, no counting
# or drawing in the script itself).
#
# Two kinds of fixture: the throwaway board of tests/helpers/progress-fixture.bash (passed as --root, the live
# project/board/ is never read) and a stub board-progress.sh / renderer reached through the documented test seam
# JENGA_BOARD_PROGRESS / JENGA_RENDER_PROGRESS_BAR. The default label language is en; bats' stdout is not a TTY, so colour
# is off unless a test asks for it.

bats_require_minimum_version 1.5.0

load helpers/progress-fixture

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO/skills/j-status/scripts/render-status-bars.sh"
  R="$REPO/scripts/render-progress-bar.sh"
  unset NO_COLOR JENGA_PROGRESS_LANG LC_CTYPE COLUMNS JENGA_BOARD_PROGRESS JENGA_RENDER_PROGRESS_BAR
  export LANG="en_US.UTF-8"
  unset LC_ALL
  ESC=$'\033'
  TAB=$'\t'
}

# mk_stub: a stub board-progress.sh that prints a fixed --by-parent document and records its arguments.
# Epic E07 is 3/4 with one in progress, story E07_S01 is 0/2 pending, so the lines are recognisably the stub's.
mk_stub() {
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/board-progress.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/args.txt"
cat <<'JSON'
{"schema_version":1,"scope":{"type":"by-parent"},
 "epics":[{"id":"E07","level":"stories","totals":{"done":3,"in_progress":1,"failed":0,"pending":0,"rejected":0,"unknown":0,"denominator":4}}],
 "stories":[{"id":"E07_S01","level":"tasks","totals":{"done":0,"in_progress":0,"failed":0,"pending":2,"rejected":0,"unknown":0,"denominator":2}},
            {"id":"E07_S02","level":"tasks","totals":{"done":2,"in_progress":0,"failed":1,"pending":0,"rejected":1,"unknown":0,"denominator":3}}],
 "warnings":[]}
JSON
STUB
  chmod +x "$STUB_DIR/board-progress.sh"
  export JENGA_BOARD_PROGRESS="$STUB_DIR/board-progress.sh"
}

# single <done> <in_progress> <failed> <pending> <rejected> <unknown> <denominator> [renderer options]: the single-bar
# renderer's line for those totals.
single() {
  local d="$1" ip="$2" f="$3" p="$4" r="$5" u="$6" den="$7"; shift 7
  printf '{"schema_version":1,"scope":{"type":"story","ids":["X"]},"levels":{"tasks":{"counts":{},"totals":{"done":%s,"in_progress":%s,"failed":%s,"pending":%s,"rejected":%s,"unknown":%s,"denominator":%s}}},"warnings":[]}\n' \
    "$d" "$ip" "$f" "$p" "$r" "$u" "$den" | bash "$R" "$@"
}

strip_ansi() { printf '%s' "$1" | sed "s/${ESC}\[[0-9;]*m//g"; }

@test "script has a bash shebang, parses under bash -n and is executable" {
  [ -x "$S" ]
  [ "$(head -n 1 "$S")" = "#!/usr/bin/env bash" ]
  run bash -n "$S"
  [ "$status" -eq 0 ]
}

@test "--help prints the usage and exits 0" {
  run bash "$S" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"render-status-bars.sh [--cols N]"* ]]
}

@test "unknown argument is a usage error, exit 2, nothing on stdout" {
  run --separate-stderr bash "$S" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "fixture board: one id<TAB>bar line per epic and per story, epics first, each equal to the single-bar renderer" {
  pf_setup
  JENGA_TODO_FILE="$PF_TODO" bash "$PF_SCRIPT" --root "$PF_ROOT" --by-parent > "$PF_OUT"
  # Expected rows, read from the --by-parent JSON by python: "<kind> <id> <done> <ip> <failed> <pending> <rej> <unk> <den>".
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for kind in ("epics", "stories"):
    for e in d[kind]:
        t = e["totals"]
        print(kind, e["id"], *[t[k] for k in ("done", "in_progress", "failed", "pending", "rejected", "unknown", "denominator")])
' "$PF_OUT" > "$BATS_TEST_TMPDIR/rows.txt"
  n_epics=$(grep -c '^epics ' "$BATS_TEST_TMPDIR/rows.txt")
  n_stories=$(grep -c '^stories ' "$BATS_TEST_TMPDIR/rows.txt")
  [ "$n_epics" -ge 5 ]
  [ "$n_stories" -ge 20 ]

  JENGA_TODO_FILE="$PF_TODO" run --separate-stderr bash "$S" --root "$PF_ROOT" --cols 80
  [ "$status" -eq 0 ]
  # Rebuild the expected output with the single-bar renderer, one call per row.
  : > "$BATS_TEST_TMPDIR/expected.txt"
  while read -r kind id d ip f p r u den; do
    line="$(single "$d" "$ip" "$f" "$p" "$r" "$u" "$den" --cols 80)"
    printf '%s\t%s\n' "$id" "$line" >> "$BATS_TEST_TMPDIR/expected.txt"
  done < "$BATS_TEST_TMPDIR/rows.txt"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq $((n_epics + n_stories)) ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/expected.txt")" ]
  # epics come before stories
  first_story_line=$(printf '%s\n' "$output" | grep -n '^E[0-9]*_S[0-9]' | head -n 1 | cut -d: -f1)
  [ "$first_story_line" -eq $((n_epics + 1)) ]
}

@test "the output derives only from the stub board-progress.sh JSON" {
  mk_stub
  run --separate-stderr bash "$S" --cols 80
  [ "$status" -eq 0 ]
  expected="E07${TAB}$(single 3 1 0 0 0 0 4 --cols 80)
E07_S01${TAB}$(single 0 0 0 2 0 0 2 --cols 80)
E07_S02${TAB}$(single 2 0 1 0 1 0 3 --cols 80)"
  [ "$output" = "$expected" ]
  # the script asked the stub for exactly the one --by-parent read
  [ "$(cat "$STUB_DIR/args.txt")" = "--by-parent" ]
}

@test "--root is forwarded to board-progress.sh" {
  mk_stub
  run --separate-stderr bash "$S" --root /some/where
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/args.txt")" = "--by-parent --root /some/where" ]
}

@test "a failing board-progress.sh gives a stderr warning, empty stdout and exit 0" {
  printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 3\n' > "$BATS_TEST_TMPDIR/fail.sh"
  chmod +x "$BATS_TEST_TMPDIR/fail.sh"
  export JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/fail.sh"
  run --separate-stderr bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"* ]]
}

@test "a missing board-progress.sh gives a stderr warning, empty stdout and exit 0" {
  export JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/does-not-exist.sh"
  run --separate-stderr bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"* ]]
}

@test "a failing renderer gives a stderr warning, empty stdout (nothing partial) and exit 0" {
  mk_stub
  # fails on the second call (--each stories) after succeeding on the first: no epic line may leak out
  cat > "$BATS_TEST_TMPDIR/flaky.sh" <<FLAKY
#!/usr/bin/env bash
case "\$*" in
  *"--each stories"*) echo "renderer boom" >&2; exit 2 ;;
  *) exec bash "$R" "\$@" ;;
esac
FLAKY
  chmod +x "$BATS_TEST_TMPDIR/flaky.sh"
  export JENGA_RENDER_PROGRESS_BAR="$BATS_TEST_TMPDIR/flaky.sh"
  run --separate-stderr bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"* ]]
}

@test "malformed JSON from board-progress.sh gives a warning, empty stdout and exit 0" {
  printf '#!/usr/bin/env bash\necho "not json"\n' > "$BATS_TEST_TMPDIR/bad.sh"
  chmod +x "$BATS_TEST_TMPDIR/bad.sh"
  export JENGA_BOARD_PROGRESS="$BATS_TEST_TMPDIR/bad.sh"
  run --separate-stderr bash "$S"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"warning"* ]]
}

@test "NO_COLOR: no escape bytes in the lines, same as the renderer" {
  mk_stub
  export NO_COLOR=1
  run --separate-stderr bash "$S" --cols 80
  [ "$status" -eq 0 ]
  [[ "$output" != *"$ESC"* ]]
  first="$(printf '%s\n' "$output" | head -n 1 | cut -f2)"
  [ "$first" = "$(single 3 1 0 0 0 0 4 --cols 80)" ]
  # --color always still forces colour over NO_COLOR, exactly as in the renderer
  run --separate-stderr bash "$S" --cols 80 --color always
  [[ "$output" == *"$ESC["* ]]
  first="$(printf '%s\n' "$output" | head -n 1 | cut -f2)"
  [ "$first" = "$(single 3 1 0 0 0 0 4 --cols 80 --color always)" ]
}

@test "non-TTY stdout: --color auto prints no escape bytes; --color always does" {
  mk_stub
  run --separate-stderr bash "$S" --cols 80
  [[ "$output" != *"$ESC"* ]]
  run --separate-stderr bash "$S" --cols 80 --color always
  [[ "$output" == *"$ESC["* ]]
  [ "$(strip_ansi "$(printf '%s\n' "$output" | head -n 1 | cut -f2)")" = "$(single 3 1 0 0 0 0 4 --cols 80)" ]
}

@test "narrow width: lines are fitted by the renderer (never wider than the width)" {
  mk_stub
  run --separate-stderr bash "$S" --cols 20
  [ "$status" -eq 0 ]
  expected="E07${TAB}$(single 3 1 0 0 0 0 4 --cols 20)
E07_S01${TAB}$(single 0 0 0 2 0 0 2 --cols 20)
E07_S02${TAB}$(single 2 0 1 0 1 0 3 --cols 20)"
  [ "$output" = "$expected" ]
  while IFS="$TAB" read -r id line; do
    [ "$(printf '%s' "$line" | wc -m | tr -d ' ')" -le 20 ]
  done <<LINES
$output
LINES
  # the width really is forwarded: at 80 columns the same totals do get a bar
  run --separate-stderr bash "$S" --cols 80
  [[ "$output" == *"["* ]]
  [[ "$output" == *"━"* ]]
  [ "$output" != "$expected" ]
}

# pty_run [options]: runs the script with stdout on a pseudo-terminal and prints what it wrote. 77 = no pty here.
pty_run() {
  python3 - "$S" "$@" <<'PY'
import os, pty, sys, select
script, extra = sys.argv[1], sys.argv[2:]
try:
    master, slave = pty.openpty()
except OSError:
    sys.exit(77)
pid = os.fork()
if pid == 0:
    os.dup2(slave, 1)
    os.execvp("bash", ["bash", script, "--cols", "80"] + extra)
os.close(slave)
out = b""
while True:
    r, _, _ = select.select([master], [], [], 5)
    if not r:
        break
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
PY
}

@test "a real pseudo-terminal: --color auto colours, NO_COLOR and --color never do not" {
  mk_stub
  run pty_run
  [ "$status" -ne 77 ] || skip "no pseudo-terminal available"
  [[ "$output" == *"$ESC["* ]]
  NO_COLOR=1 run pty_run
  [[ "$output" != *"$ESC"* ]]
  run pty_run --color never
  [[ "$output" != *"$ESC"* ]]
}

@test "the script does no counting or drawing: its code (comments aside) names no status and draws no glyph" {
  run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -Eq "Passed|Pending|In Progress|█|░|━|╌|⚑|#####"' _ "$S"
  [ "$status" -eq 1 ]
}

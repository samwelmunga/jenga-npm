#!/usr/bin/env bats
#
# Structure and registration coverage for the j.conventions skill (E69_S04_T06): skills/j-conventions/SKILL.md, its
# allow-list and CLAUDE.md registration, its script contract against `conventions-entry.sh --help`, its numbered-choice
# rule and its project-layer-only rule.
#
# Pure text and tree checks over this repository's committed files, plus scratch copies for the parity self-tests. Each
# case runs against a scratch project under $BATS_TEST_TMPDIR (a project/configs/workflow.json, selected with
# JENGA_PROJECT_ROOT); nothing here writes this repository, and the teardown proves its project/configs/ is untouched.
#
# Deliberately NOT asserted: that .claude/ and .agents/ lack j-conventions. That is true until the mirror resync in
# E69_S06_T03 and false afterwards, so asserting it would be a time bomb. The T04 "nothing created under .claude/ or
# .agents/" criterion is checked in that task's review of the diff, not here.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/j-conventions"
SKILL="$SKILL_DIR/SKILL.md"
ENTRY="$SKILL_DIR/scripts/conventions-entry.sh"
ALLOW_LIST="$REPO_ROOT/lib/skill-allow-list.json"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
HELP_SCAN="$REPO_ROOT/tests/helpers/help-scan.mjs"
REAL_CONFIGS="$REPO_ROOT/project/configs"

setup() {
  REAL_SUM="$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/project/configs"
  printf '{}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
}

teardown() {
  [ "$(find "$REAL_CONFIGS" -type f -exec cksum {} + | sort | cksum)" = "$REAL_SUM" ]
}

# --- helpers ---------------------------------------------------------------------------------------------------

# frontmatter <file>: the lines between the first two `---` lines.
frontmatter() {
  awk '/^---[[:space:]]*$/ { n++; next } n == 1 { print } n >= 2 { exit }' "$1"
}

# fm_scalar <file> <key>: the value of a top-level scalar key in the frontmatter.
fm_scalar() {
  frontmatter "$1" | sed -n -E "s/^$2:[[:space:]]*(.*)$/\1/p" | head -1
}

# fm_list_count <file> <key>: number of "  - item" lines under a top-level list key.
fm_list_count() {
  frontmatter "$1" | awk -v key="$2" '
    $0 ~ "^" key ":" { inlist = 1; next }
    /^[A-Za-z_]+:/ { inlist = 0 }
    inlist && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ { n++ }
    END { print n + 0 }'
}

# skill_subcommands <SKILL.md>: subcommands named in the Script contract table, one per line, sorted.
skill_subcommands() {
  grep -E '^\| `conventions-entry.sh ' "$1" | sed -E 's/^\| `conventions-entry.sh ([a-z-]+).*/\1/' | sort -u
}

# help_subcommands <script>: subcommands listed in the script's --help usage block, one per line, sorted.
help_subcommands() {
  bash "$1" --help | grep -E '^  conventions-entry.sh ' | awk '{ print $2 }' | grep -v '^-' | sort -u
}

# parity <SKILL.md> <script>: succeeds only when both sides name exactly the same subcommands.
parity() {
  local a b
  a="$(skill_subcommands "$1")"
  b="$(help_subcommands "$2")"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# last_numbered_lines <file>: for each fenced code block that contains numbered lines ("1. ..."), print that block's
# LAST numbered line, one per line.
last_numbered_lines() {
  awk '
    /^[[:space:]]*```/ { if (inblock) { if (last != "") print last; last = ""; inblock = 0 } else { inblock = 1; last = "" } next }
    inblock && /^[[:space:]]*[0-9]+\.[[:space:]]/ { last = $0 }
  ' "$1"
}

# --- frontmatter and location ----------------------------------------------------------------------------------

@test "SKILL.md exists in the canonical skills/j-conventions/ directory with name j.conventions" {
  [ -f "$SKILL" ]
  [ "$(fm_scalar "$SKILL" name)" = "j.conventions" ]
}

@test "the directory name and the frontmatter name satisfy the skills/j-<name>/ <-> name: j.<name> mapping" {
  dir="$(basename "$SKILL_DIR")"
  name="$(fm_scalar "$SKILL" name)"
  [ "$dir" = "j-${name#j.}" ]
}

@test "frontmatter carries a non-empty description, keywords and examples" {
  [ -n "$(fm_scalar "$SKILL" description)" ]
  [ "$(fm_list_count "$SKILL" keywords)" -ge 3 ]
  [ "$(fm_list_count "$SKILL" examples)" -ge 3 ]
}

@test "keywords are short phrases of 1 to 3 words" {
  long="$(frontmatter "$SKILL" | awk '
    /^keywords:/ { inlist = 1; next }
    /^[A-Za-z_]+:/ { inlist = 0 }
    inlist && /^[[:space:]]+-[[:space:]]/ { sub(/^[[:space:]]+-[[:space:]]+/, ""); if (split($0, w, " ") > 3) print $0 }')"
  [ -z "$long" ]
}

# --- registration ----------------------------------------------------------------------------------------------

@test "the skill allow-list lists conventions and its skill_count equals the length of its skills array" {
  [ "$(jq -r '.skills | index("conventions") != null' "$ALLOW_LIST")" = "true" ]
  [ "$(jq -r '.skill_count' "$ALLOW_LIST")" = "$(jq -r '.skills | length' "$ALLOW_LIST")" ]
}

@test "CLAUDE.md's skills table has a j.conventions row" {
  grep -qE '^\| `j\.conventions` \|' "$CLAUDE_MD"
}

@test "the help directory scan lists j-conventions for the canonical skills/ tree" {
  run node "$HELP_SCAN" list "$REPO_ROOT/skills"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'index("j-conventions") != null')" = "true" ]
}

# --- script contract parity ------------------------------------------------------------------------------------

@test "every subcommand in the SKILL.md script contract table is in conventions-entry.sh --help, and vice versa" {
  [ -n "$(skill_subcommands "$SKILL")" ]
  parity "$SKILL" "$ENTRY"
  [ "$(skill_subcommands "$SKILL")" = "$(help_subcommands "$ENTRY")" ]
}

@test "the parity check fails when a subcommand exists on only one side" {
  # a row only in SKILL.md
  cp "$SKILL" "$BATS_TEST_TMPDIR/SKILL.md"
  printf '| `conventions-entry.sh frobnicate` | Not a real subcommand |\n' >> "$BATS_TEST_TMPDIR/SKILL.md"
  run parity "$BATS_TEST_TMPDIR/SKILL.md" "$ENTRY"
  [ "$status" -ne 0 ]
  # a row removed from SKILL.md
  grep -vE '^\| `conventions-entry.sh draft-diff' "$SKILL" > "$BATS_TEST_TMPDIR/SKILL.md"
  run parity "$BATS_TEST_TMPDIR/SKILL.md" "$ENTRY"
  [ "$status" -ne 0 ]
  # a usage line removed from --help (script copy)
  grep -vE '^#   conventions-entry.sh commit ' "$ENTRY" > "$BATS_TEST_TMPDIR/conventions-entry.sh"
  run parity "$SKILL" "$BATS_TEST_TMPDIR/conventions-entry.sh"
  [ "$status" -ne 0 ]
  # a usage line added to --help (script copy)
  sed 's/^#   conventions-entry.sh commit .*/&\n#   conventions-entry.sh frobnicate   Not a real subcommand/' "$ENTRY" > "$BATS_TEST_TMPDIR/conventions-entry.sh"
  run parity "$SKILL" "$BATS_TEST_TMPDIR/conventions-entry.sh"
  [ "$status" -ne 0 ]
  # the untouched pair still passes
  parity "$SKILL" "$ENTRY"
}

@test "every script path SKILL.md names exists in the repository" {
  paths="$(grep -oE '[A-Za-z0-9_./-]*[A-Za-z0-9_-]+\.sh' "$SKILL" | sort -u)"
  [ -n "$paths" ]
  for p in $paths; do
    base="$(basename "$p")"
    if [ -f "$REPO_ROOT/$p" ] || [ -f "$REPO_ROOT/scripts/$base" ] || [ -f "$SKILL_DIR/scripts/$base" ]; then
      continue
    fi
    printf 'SKILL.md names a script that does not exist: %s\n' "$p" >&2
    false
  done
}

# --- numbered choices ------------------------------------------------------------------------------------------

@test "every numbered choice in SKILL.md ends with the free-text Other option" {
  lines="$(last_numbered_lines "$SKILL")"
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge 2 ]
  printf '%s\n' "$lines" > "$BATS_TEST_TMPDIR/last-lines.txt"
  while IFS= read -r line; do
    case "$line" in
      *"Other (describe below)"*) ;;
      *)
        printf 'a numbered choice does not end with the free-text option: %s\n' "$line" >&2
        false
        ;;
    esac
  done < "$BATS_TEST_TMPDIR/last-lines.txt"
}

@test "the per-category choice offers detected, presets, skip and custom, with skip before Other" {
  block="$(awk '/how does this project do it\?/ { grab = 1 } grab { print } grab && /Other \(describe below\)/ { exit }' "$SKILL")"
  [ -n "$block" ]
  assert_contains "$block" "Detected:"
  assert_contains "$block" "Preset label"
  assert_contains "$block" "Skip (record nothing)"
  skip_line="$(printf '%s\n' "$block" | grep -n 'Skip (record nothing)' | head -1 | cut -d: -f1)"
  other_line="$(printf '%s\n' "$block" | grep -n 'Other (describe below)' | head -1 | cut -d: -f1)"
  [ "$skip_line" -lt "$other_line" ]
}

@test "the review step offers go-back to every category before writing, and a cancel" {
  text="$(cat "$SKILL")"
  assert_contains "$text" "Looks good, write it"
  assert_contains "$text" "Cancel (write nothing)"
  assert_contains "$text" "draft-diff"
}

# --- required statements ---------------------------------------------------------------------------------------

@test "SKILL.md states the project-layer-only scope, the EST board-commit exception and the re-run pre-selection" {
  text="$(cat "$SKILL")"
  assert_contains "$text" "Project layer only"
  assert_contains "$text" "EST commit naming stays"
  assert_contains "$text" "mandatory for board commits"
  assert_contains "$text" "commits that are not board commits"
  assert_contains "$text" "seeded from conventions already recorded"
  assert_contains "$text" "never blocking"
}

@test "SKILL.md validates every input with check and writes only through commit, reporting success only after validation" {
  text="$(cat "$SKILL")"
  assert_contains "$text" "conventions-entry.sh check"
  assert_contains "$text" "conventions-entry.sh commit --draft"
  assert_contains "$text" "scripts/validate-conventions.sh"
  assert_contains "$text" "scripts/validate-checklists.sh"
  assert_contains "$text" "Under no circumstances report success"
}

@test "SKILL.md asks for a real command when a preset carries a placeholder and never passes placeholder text" {
  text="$(cat "$SKILL")"
  assert_contains "$text" "placeholder_fields"
  assert_contains "$text" "--unset"
  assert_contains "$text" "Never pass placeholder text"
}

# --- project layer only ----------------------------------------------------------------------------------------

@test "SKILL.md offers no layer choice: no --layer option and no user-layer option" {
  run grep -n -i -E -e '--layer|user layer|user-layer|layer user' "$SKILL"
  [ "$status" -ne 0 ]
  usage="$(bash "$ENTRY" --help | grep -E '^  conventions-entry.sh ')"
  assert_not_contains "$usage" "--layer"
}

# --- scripts over inline logic ---------------------------------------------------------------------------------

@test "SKILL.md performs no deterministic work inline: no jq, mv, redirect-into-file or direct write of conventions.json" {
  run grep -n -E '(^|[^A-Za-z])jq([^A-Za-z]|$)' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -n -E '(^|[[:space:]`])(mv|cp|rm|tee|sed|awk)[[:space:]]' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -n -E 'cat[[:space:]]*>|>>?[[:space:]]*[^[:space:]]*conventions\.json|echo .*>' "$SKILL"
  [ "$status" -ne 0 ]
}

@test "SKILL.md has no command that targets conventions.json directly" {
  run grep -n -E '`[^`]*(>|>>|tee|mv|cp)[^`]*conventions\.json[^`]*`' "$SKILL"
  [ "$status" -ne 0 ]
}

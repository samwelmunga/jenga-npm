#!/usr/bin/env bats
#
# Coverage for scripts/scan-credential-patterns.sh (E85_S02_T01).
#
# Every case builds a throwaway tree under $BATS_TEST_TMPDIR and points the scanner at it with --root, so the
# real skills/ and scripts/ are only read by the two "real tree" cases at the end (determinism and JSON shape).
# The fixtures carry credential-looking TEXT only; nothing here reads, writes or needs a real credential.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/scan-credential-patterns.sh"
REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/skills/demo" "$TREE/scripts"
}

# One line of every class, plus one clean file. Line numbers are asserted below.
write_all_classes() {
  printf '%s\n' \
    'gh auth login' \
    'echo "$AWS_SECRET_ACCESS_KEY"' \
    'cat ~/.config/tool/settings' \
    'cd "$HOME"' \
    'cat .netrc' >"$TREE/skills/demo/all.sh"
  printf '%s\n' 'echo hello' 'process.env.PORT' 'valid_deployment() { :; }' >"$TREE/scripts/clean.sh"
}

@test "reports exactly one row per class with the right class id" {
  write_all_classes
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' \
    "skills/demo/all.sh	1	gh-auth	gh auth login" \
    "skills/demo/all.sh	2	aws-env	echo \"\$AWS_SECRET_ACCESS_KEY\"" \
    "skills/demo/all.sh	3	dotfile-path	cat ~/.config/tool/settings" \
    "skills/demo/all.sh	4	home-ref	cd \"\$HOME\"" \
    "skills/demo/all.sh	5	credential-file	cat .netrc")"
  [ "$output" = "$expected" ]
}

@test "scans the default directories only and reports nothing for a clean tree" {
  printf '%s\n' 'echo hello' >"$TREE/scripts/clean.sh"
  mkdir -p "$TREE/other"
  printf '%s\n' 'gh auth login' >"$TREE/other/outside.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an explicit path is scanned in addition to nothing else" {
  mkdir -p "$TREE/other"
  printf '%s\n' 'gh auth status' >"$TREE/other/outside.sh"
  run bash "$SCRIPT" --root "$TREE" other
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'other/outside.sh\t1\tgh-auth\tgh auth status')" ]
}

@test "a line matching two classes yields one row per class in class order" {
  printf '%s\n' 'gh secret set K < ~/.ssh/id_deploy' >"$TREE/skills/demo/two.md"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f3 | paste -sd, -)" = "dotfile-path,credential-file" ]
}

@test "a dotfile path is not also reported as a bare home reference" {
  printf '%s\n' 'x="$HOME/.cache/y"' 'y=${HOME}/.cache/z' 'z=~/.cache/w' >"$TREE/scripts/d.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f3 | sort -u)" = "dotfile-path" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "bare home references are home-ref: \$HOME, \${HOME:-x}, ~/ path" {
  printf '%s\n' 'a="$HOME"' 'b="${HOME:-/tmp}"' 'c=~/Documents' 'd="$HOME/bin"' >"$TREE/scripts/h.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f3 | sort -u)" = "home-ref" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 4 ]
}

@test "credential file names match, words that merely contain them do not" {
  printf '%s\n' \
    'cat .aws/credentials' \
    'ls .ssh/' \
    'echo .npmrc' \
    'echo id_rsa' \
    'echo id_deploy' \
    'source .env' \
    'x=process.env.A' \
    'valid_deployment' \
    'import.meta.env.B' >"$TREE/scripts/c.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2 | paste -sd, -)" = "1,2,3,4,5,6" ]
  [ "$(printf '%s\n' "$output" | cut -f3 | sort -u)" = "credential-file" ]
}

@test "an AWS_ name is aws-env but a word ending in AWS_ is not" {
  printf '%s\n' 'export AWS_PROFILE=x' 'echo ${AWS_REGION}' 'echo LAWS_FOO' >"$TREE/scripts/a.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2 | paste -sd, -)" = "1,2" ]
  [ "$(printf '%s\n' "$output" | cut -f3 | sort -u)" = "aws-env" ]
}

@test "gh auth is matched for any subcommand but not for gh authority-like words" {
  printf '%s\n' 'gh auth token' 'gh auth status >/dev/null' 'gh authx' 'ghauth' >"$TREE/scripts/g.sh"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f2 | paste -sd, -)" = "1,2" ]
}

@test "the scanner never scans its own source, .git or node_modules" {
  mkdir -p "$TREE/scripts/node_modules/p" "$TREE/scripts/.git"
  printf '%s\n' 'gh auth login' >"$TREE/scripts/scan-credential-patterns.sh"
  printf '%s\n' 'gh auth login' >"$TREE/scripts/node_modules/p/x.js"
  printf '%s\n' 'gh auth login' >"$TREE/scripts/.git/config"
  run bash "$SCRIPT" --root "$TREE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "output is sorted by file then numeric line, and is byte-identical across runs" {
  mkdir -p "$TREE/skills/b" "$TREE/skills/a"
  : >"$TREE/f10.txt"
  {
    for _ in 1 2 3 4 5 6 7 8 9; do printf '%s\n' 'filler'; done
    printf '%s\n' 'gh auth login' 'gh auth status'
  } >"$TREE/skills/b/z.md"
  printf '%s\n' 'gh auth login' >"$TREE/skills/a/y.md"
  printf '%s\n' 'filler' 'gh auth login' >"$TREE/scripts/s.sh"
  bash "$SCRIPT" --root "$TREE" >"$BATS_TEST_TMPDIR/one"
  bash "$SCRIPT" --root "$TREE" >"$BATS_TEST_TMPDIR/two"
  cmp "$BATS_TEST_TMPDIR/one" "$BATS_TEST_TMPDIR/two"
  [ "$(cut -f1,2 "$BATS_TEST_TMPDIR/one" | tr '\t' ':' | paste -sd, -)" = "scripts/s.sh:2,skills/a/y.md:1,skills/b/z.md:10,skills/b/z.md:11" ]
}

@test "json output has the documented keys and parses with jq" {
  write_all_classes
  printf '%s\n' 'say "quoted" and back\slash	tabbed' | sed 's/^/gh auth /' >"$TREE/scripts/esc.sh"
  run bash "$SCRIPT" --root "$TREE" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.schema_version == 1 and (.root | type == "string") and (.matches | type == "array")' >/dev/null
  printf '%s' "$output" | jq -e '[.matches[] | keys | join(",")] | unique == ["class,file,line,text"]' >/dev/null
  printf '%s' "$output" | jq -e '[.matches[].class] | unique - ["gh-auth","aws-env","dotfile-path","home-ref","credential-file"] == []' >/dev/null
  printf '%s' "$output" | jq -e '[.matches[] | select(.file == "scripts/esc.sh")][0].text == "gh auth say \"quoted\" and back\\slash tabbed"' >/dev/null
  printf '%s' "$output" | jq -e '[.matches[].line | type] | unique == ["number"]' >/dev/null
}

@test "json rows are the tsv rows, in the same order" {
  write_all_classes
  bash "$SCRIPT" --root "$TREE" >"$BATS_TEST_TMPDIR/t.tsv"
  bash "$SCRIPT" --root "$TREE" --format json | jq -r '.matches[] | [.file, (.line | tostring), .class, .text] | @tsv' >"$BATS_TEST_TMPDIR/j.tsv"
  # @tsv escapes backslashes and quotes differently from the raw text, so compare file, line and class only
  [ "$(cut -f1-3 "$BATS_TEST_TMPDIR/t.tsv")" = "$(cut -f1-3 "$BATS_TEST_TMPDIR/j.tsv")" ]
}

@test "json for an empty tree is a valid object with an empty matches array" {
  run bash "$SCRIPT" --root "$TREE" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.matches == [] and .schema_version == 1' >/dev/null
}

@test "usage errors exit 2: unknown flag, bad format, missing value, bad root, missing path, outside path" {
  run bash "$SCRIPT" --nope
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$TREE" --format xml
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$TREE/does-not-exist"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$TREE" no-such-dir
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --root "$TREE" /etc
  [ "$status" -eq 2 ]
}

@test "--help prints the header usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'USAGE'
  printf '%s' "$output" | grep -q 'EXIT CODES'
}

@test "real tree: two runs are byte-identical and the json parses" {
  bash "$SCRIPT" --root "$REPO_ROOT" >"$BATS_TEST_TMPDIR/r1"
  bash "$SCRIPT" --root "$REPO_ROOT" >"$BATS_TEST_TMPDIR/r2"
  cmp "$BATS_TEST_TMPDIR/r1" "$BATS_TEST_TMPDIR/r2"
  bash "$SCRIPT" --root "$REPO_ROOT" --format json | jq -e '.schema_version == 1 and (.matches | length) > 0' >/dev/null
}

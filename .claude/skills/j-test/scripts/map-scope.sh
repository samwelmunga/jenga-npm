#!/usr/bin/env bash
################################################################################
# map-scope.sh — changed files to the test suites that cover them (E72_S03_T02)
#
# The deterministic script `j.commit` (E72_S04) calls to learn which discovered
# suites cover the files in a commit. It reads a scope-map file, runs `git` and
# `discover-tests.sh`, and prints one JSON object. It writes nothing to the
# repository (no file, no index update, nothing under .git) and never runs a suite
# command or any project code. Its one write is a scratch directory under
# ${TMPDIR:-/tmp}, used by --working only (see "Index protection" below) and removed
# on every exit path.
#
# Usage:
#   map-scope.sh [--root <dir>] [--map <file>] [--suites <file|->]
#                [--rev <commit> | --range <a..b> | --staged | --working
#                 | --files-from <file>]
#   map-scope.sh --help
#
#   --root <dir>      project root; every git call runs against it. Default: the
#                     root resolved through scripts/resolve-root.sh.
#   --suites <f|->    use this discovery JSON (a file, or - for stdin) instead of
#                     running `discover-tests.sh --root <root>`. Only `suites[]`
#                     is required; a suite without `paths` reads as `paths: []`,
#                     and unknown keys are ignored. Without --suites, discovery's
#                     own warnings are carried into the output, each prefixed
#                     `discovery: `.
#   --map <file>      scope-map file (see "Mapping file" below).
#
# Change source (at most one; default --working):
#   --rev <commit>    that commit against its first parent (a root commit against
#                     the empty tree)
#   --range <a..b>    passed to `git diff` (`a..b` or `a...b`)
#   --staged          the index against HEAD
#   --working         everything differing from HEAD: staged, unstaged and
#                     untracked-not-ignored files
#   --files-from <f>  (E72_S06_T03) the changed files are exactly the names listed
#                     in <f>: one root-relative path per line, blank lines ignored,
#                     no git diff is run. For callers that already derived a file
#                     list from several commits (scope-test-gate.sh unions the
#                     commits of a story or an epic). Names are used verbatim; a
#                     missing or unreadable <f> is exit 3. An empty list is the
#                     `No changed files` result, as for any other empty source.
#   In a repository with no commit yet, --staged and --working diff against the
#   empty tree. Names come from `git diff --name-only -z --no-renames` (a rename
#   is a delete plus an add, so both names count) with core.quotepath=off. Paths
#   are relative to the project root. A name that contains a newline cannot be
#   carried and is skipped with a warning.
#
# INDEX PROTECTION
#   A plain `git diff` against the working tree (HEAD or no HEAD) refreshes the stat
#   data cached in .git/index and takes .git/index.lock, even with
#   GIT_OPTIONAL_LOCKS=0 or `git --no-optional-locks` (git 2.39.5 verified; those
#   only silence the opportunistic refresh of `git status`). An index write in the
#   user's repository can collide with their own git commands, so:
#     --working   both of its working-tree diffs run with GIT_INDEX_FILE pointing at
#                 a throwaway copy of the index, made with `cp -p` so the copy keeps
#                 the original's mtime (git's racy-timestamp check compares entry
#                 times against the index file's mtime; a fresher copy would trust
#                 same-second edits). The copy lives in a private `mktemp -d`
#                 directory under ${TMPDIR:-/tmp}, never inside the repository, and
#                 its path is never printed. With no index file yet (a repository
#                 with no commit and nothing staged) the diff runs against an absent
#                 index inside that directory, which git reads as empty, so nothing
#                 is created under .git. The directory is removed on success, on
#                 every `die`, and on INT/TERM/HUP.
#     other sources   --staged, --rev and --range (and `ls-files --others`) do not
#                 write the index, so they run against the real one unchanged;
#                 GIT_OPTIONAL_LOCKS=0 stays exported as a belt for those calls.
#
# ---------------------------------------------------------------------------
# MAPPING FILE
#   Resolved first hit wins:
#     1. --map <file>
#     2. the flat key `commit_scope_map_file` in test-config.json (configs dir
#        resolved as in discover-tests.sh). The value must be a path relative to
#        the root, free of `..` segments, ending in `.json`; it resolves against
#        the root. A configured file that does not exist is exit 3: an explicit
#        setting pointing nowhere is a misconfiguration, never a silent fallback.
#        An absent/null key, or an absent test-config.json, falls through. An
#        unreadable or invalid test-config.json is treated as "key absent" plus
#        the warning `test-config.json could not be read; using the default scope map`.
#     3. templates/test-scope-map.json: the root's own copy when it has one, else
#        the shipped copy (checkout, then node_modules/@jenga-ai/agent/templates/).
#
#   Format (normative, fixed by templates/test-scope-map.json):
#     {"map_version":1,"_comment":"...","rules":[{"source":<glob>,"tests":[<glob>,...]}]}
#   `_comment` and unknown top-level keys are ignored. Rules are ADDITIVE: every
#   rule whose `source` matches a changed file contributes; there is no first-match.
#   Validation (jq; exit 3, stderr names the file, the rule index (1-based) and
#   the problem): not valid JSON / not one object; `map_version` missing or not 1;
#   `rules` missing, not an array or empty; a rule that is not an object, has a
#   key other than `source`/`tests`, has a non-string or empty `source`, or a
#   `tests` that is not a non-empty array of non-empty strings; any glob outside
#   the dialect. A literal path with no wildcard is valid.
#   NEGATION IS NOT SUPPORTED in map_version 1: a glob beginning with `!` is a
#   validation error that says so (it is never matched literally).
#
# GLOB DIALECT (shared with discovery's per-suite `paths`)
#   Paths are root-relative, `/`-separated, matched against the whole path,
#   case-sensitive; dotfiles are not special.
#     *   any run of characters except `/`
#     ?   one character except `/`
#     **  only as a complete segment; zero or more segments (`src/**/*.js`
#         matches src/a.js and src/x/y/a.js; a trailing `src/**` matches
#         everything below src/)
#     every other character is literal.
#   Rejected: a leading `/` or `./`, a `..` segment, a `.` segment, an empty
#   segment (`a//b`, trailing `/`), any of `[ ] { } \`, a control character,
#   `**` inside a segment (`a**b`), and a leading `!`.
#
# ---------------------------------------------------------------------------
# ALGORITHM (normative)
#   1. changed    = changed names, unique, sorted (byte order).
#   2. candidates = files that exist in the working tree:
#                   git ls-files -z --cached --others --exclude-standard, filtered
#                   for existence. Tests run against the working tree, so this is
#                   the set for every --rev/--range too.
#   3. A TEST FILE is a path some suite's `paths` matches or some rule's `tests`
#      glob matches. For each changed file f the files to resolve are: f itself
#      when it exists and is a test file (editing a test runs it), plus, for every
#      rule whose `source` matches f, every candidate matching that rule's `tests`.
#   4. Resolve a test file t to suites: every suite whose (non-empty) `paths`
#      matches t. If none does, fall back by extension to the ecosystem and take
#      EVERY suite of it whose `paths` is empty: .js .jsx .ts .tsx .mjs .cjs ->
#      npm (an npm script is opaque, so over-selecting is the safe direction).
#      Other extensions have no fallback. A suite's own `paths` entries that are
#      outside the dialect are ignored with a warning; a suite left with none
#      counts as having empty `paths` (again the over-selecting direction).
#   5. A changed file with at least one resolved suite is mapped; otherwise it is
#      listed in `unmapped_files`.
#   6. Selected suites with an empty `command` cannot run: dropped with the
#      warning `suite <id> has no runnable command; skipped`. Selected suites
#      sharing an identical command collapse to the lowest id, which takes the
#      union of their test files (discovery emits config:bats:integration with
#      bats:tests's command; without this a run would execute it twice).
#
# ---------------------------------------------------------------------------
# OUTPUT (normative): one compact JSON object and a trailing newline on stdout
#
#   {"mapped_suites":["bats:tests","npm:test"],
#    "mapped_tests":{"bats:tests":["tests/a.bats"],"npm:test":["test/a.test.js"]},
#    "unmapped_files":["README.md"],"warnings":[]}
#
#   mapped_suites   suite ids from discovery, sorted, unique
#   mapped_tests    one key per mapped suite (same order), value the sorted unique
#                   test files that put it there; lets E72_S04 narrow a run when
#                   the runner takes file arguments (a whole-suite run stays valid)
#   unmapped_files  sorted
#   warnings        sorted, unique, always an array
#
#   ZERO MAPPED SUITES IS NEVER SILENT. With a non-empty change set and
#   `mapped_suites` empty the warnings contain `No tests found for the changed
#   files`, plus `No test suites discovered` when discovery returned none. The
#   caller reads this to offer the full suite instead of a vacuous green run.
#   Empty change set (e.g. `git commit --allow-empty`): empty arrays and the single
#   warning `No changed files`, exit 0 (discovery is not run).
#   Further warnings: `rule <n> (<source>): <k> changed file(s) matched but no
#   existing test file matched its tests globs` and `rule <n> (<source>): test
#   files matched but no discovered suite runs them` (<n> is the 1-based rule index).
#
#   Byte-identical for identical input: LC_ALL=C is forced, every array is sorted,
#   no timestamps or absolute paths in the output, git's core.quotepath is set per
#   call. (Paths that are not valid UTF-8 are not representable in JSON; jq
#   substitutes U+FFFD.)
#
# ---------------------------------------------------------------------------
# EXIT CODES
#   0  success, including zero mapped suites
#   1  internal failure (jq or git missing - named on stderr -, discovery failed
#      or produced unusable output, root unresolvable)
#   2  usage error (unknown flag, missing argument, more than one change source,
#      non-directory --root)
#   3  a mapping file, its configured path, the --suites input or the --files-from
#      file is missing, unreadable or invalid (stdout empty, a clear stderr message)
#   4  not a git repository, or an unknown revision
#   Callers treat any non-zero exit as "offer the full suite".
#
# macOS bash 3.2 compatible: no mapfile, associative arrays, globstar. One jq pass
# does all matching, so no process is forked per file.
################################################################################

set -euo pipefail

SCRIPT_NAME="map-scope.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# Locale must not influence sort order or tool output.
export LC_ALL=C
# Silences git's opportunistic index refresh for the calls that would otherwise do
# it (e.g. status). It does NOT stop `git diff` against the working tree, so --working
# diffs a throwaway index copy instead (see "INDEX PROTECTION" in the header).
export GIT_OPTIONAL_LOCKS=0

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'EOF'
Usage: map-scope.sh [--root <dir>] [--map <file>] [--suites <file|->]
                    [--rev <commit> | --range <a..b> | --staged | --working
                     | --files-from <file>]
       map-scope.sh --help

Map the files changed in a commit, range, the index or the working tree to the
discovered test suites that cover them, using a scope-map file.

  --root <dir>      project root (default: resolved via scripts/resolve-root.sh)
  --map <file>      scope-map file (else test-config.json's commit_scope_map_file,
                    else templates/test-scope-map.json)
  --suites <f|->    discovery JSON to use instead of running discover-tests.sh
  --rev <commit>    commit against its first parent
  --range <a..b>    a revision range (a..b or a...b)
  --staged          the index against HEAD
  --working         staged, unstaged and untracked files (default)
  --files-from <f>  the changed files are the root-relative paths listed in <f>,
                    one per line (no git diff is run)
  --help            show this help and exit 0

Output: {"mapped_suites":[],"mapped_tests":{},"unmapped_files":[],"warnings":[]}
Exit:   0 ok (also when nothing maps; see warnings), 1 internal failure,
        2 usage error, 3 invalid/missing map or suites input, 4 not a git repo
        or unknown revision
EOF
}

# Mirrors the resolve_helper pattern of discover-tests.sh: a checkout first, then
# the installed-package location.
resolve_helper() {
  local rel="$1" candidate
  for candidate in "$REPO_ROOT/$rel" "$REPO_ROOT/node_modules/@jenga-ai/agent/$rel"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---- jq programs ------------------------------------------------------------
# Shared glob definitions. globprob returns null for a valid glob and a message
# (quoting the glob) otherwise. glob_body translates a VALID glob to an
# unanchored regex; any_re combines globs into one anchored alternation.
glob_defs() {
  cat <<'EOF'
def globprob:
  . as $g
  | if ($g | type) != "string" then "glob is not a string"
    elif $g == "" then "glob is empty"
    elif ($g | startswith("!")) then "glob \($g | tojson) begins with \"!\": negation is not supported in map_version 1"
    elif ($g | test("[\\x00-\\x1f]")) then "glob \($g | tojson) contains a control character"
    elif ($g | startswith("/")) then "glob \($g | tojson) begins with \"/\"; globs are relative to the project root"
    elif ($g | startswith("./")) then "glob \($g | tojson) begins with \"./\"; write the path without it"
    elif ($g | test("[\\[\\]{}\\\\]")) then "glob \($g | tojson) uses one of [ ] { } \\, which the glob dialect does not support"
    else ($g | split("/")) as $s
      | if ($s | index("")) != null then "glob \($g | tojson) has an empty path segment"
        elif ($s | index("..")) != null then "glob \($g | tojson) has a \"..\" segment"
        elif ($s | index(".")) != null then "glob \($g | tojson) has a \".\" segment"
        elif ([ $s[] | select(contains("**") and . != "**") ] | length) > 0
          then "glob \($g | tojson) uses \"**\" inside a segment; it must be a whole segment"
        else null end
    end;

def seg_re:
  split("")
  | map(. as $c
        | if $c == "*" then "[^/]*"
          elif $c == "?" then "[^/]"
          elif (".+()|^$" | index($c)) != null then "\\" + $c
          else $c end)
  | join("");

def glob_body:
  split("/") as $s | ($s | length) as $n
  | [ range(0; $n) as $i | $s[$i] as $g
      | if $g == "**" then (if $i == $n - 1 then ".+" else "(?:[^/]+/)*" end)
        else (($g | seg_re) + (if $i == $n - 1 then "" else "/" end)) end ]
  | join("");

def any_re($globs):
  if ($globs | length) == 0 then null
  else "\\A(?:" + ($globs | map(glob_body) | join("|")) + ")\\z" end;

def matches($re): if $re == null then false else test($re) end;
EOF
}

# Mapping-file validation. Input: the file slurped (jq -s). Output: one problem
# per line, in rule order; nothing when the file is valid.
validate_map_program() {
  cat <<'EOF'
def rule_problems($n):
  . as $r
  | if ($r | type) != "object" then ["rule \($n): not an object"]
    else
      [ $r | keys[] | select(. != "source" and . != "tests") | "rule \($n): unknown key \(. | tojson)" ]
      + ( if ($r.source | type) != "string" or $r.source == ""
          then ["rule \($n): source must be a non-empty string"]
          else [ $r.source | globprob | select(. != null) | "rule \($n): source: " + . ] end )
      + ( if ($r.tests | type) != "array" or ($r.tests | length) == 0
             or ([ $r.tests[] | select(type != "string" or . == "") ] | length) > 0
          then ["rule \($n): tests must be a non-empty array of non-empty strings"]
          else [ $r.tests[] | globprob | select(. != null) | "rule \($n): tests: " + . ] end )
    end;

.[0] as $d
| if length != 1 then ["file must hold exactly one JSON value"]
  elif ($d | type) != "object" then ["top-level value is not an object"]
  else
    ( if $d.map_version != 1 then ["map_version is missing or not 1"] else [] end )
    + ( if ($d.rules | type) != "array" then ["rules is missing or not an array"]
        elif ($d.rules | length) == 0 then ["rules is empty"]
        else [ $d.rules | to_entries[] | .key as $i | .value | rule_problems($i + 1) ] | add end )
  end
| .[]
EOF
}

# --suites / discovery validation and normalisation. Input: one document.
# Output: {"problems":[...]} or {"problems":[],"warnings":[...],"suites":[...]}
# where every suite is {id, command, ecosystem, paths}.
normalize_suites_program() {
  cat <<'EOF'
. as $d
| if ($d | type) != "object" or ($d.suites | type) != "array"
  then {problems: ["expected a JSON object with a \"suites\" array"]}
  else
    ( [ $d.suites | to_entries[] | .key as $i | .value as $s
        | if ($s | type) != "object" then "suites[\($i)] is not an object"
          elif ($s.id | type) != "string" or $s.id == "" then "suites[\($i)] has no string id"
          elif $s.paths != null and (($s.paths | type) != "array"
                 or ([ $s.paths[] | select(type != "string") ] | length) > 0)
            then "suite \($s.id): paths must be an array of strings"
          else empty end ] ) as $p
    | if ($p | length) > 0 then {problems: $p}
      else
        { problems: [],
          warnings: [ $d.suites[] | .id as $id | (.paths // [])[] | globprob | select(. != null)
                      | "suite \($id): ignored invalid paths entry: " + . ],
          suites: [ $d.suites[]
                    | { id: .id,
                        command: (if (.command | type) == "string" then .command else "" end),
                        ecosystem: (if (.ecosystem | type) == "string" and .ecosystem != ""
                                    then .ecosystem else (.id | split(":") | .[0]) end),
                        paths: [ (.paths // [])[] | select(globprob == null) ] } ] }
      end
  end
EOF
}

# The matching pass. Input: the tagged line stream (raw), one record per line:
#   S<TAB><normalised suites JSON>   W<TAB><carried warning>
#   C<TAB><changed path>             F<TAB><candidate path>
#   X<TAB>1                          (a path skipped for containing a newline)
# Argument: $mapdoc, the validated mapping file slurped.
match_program() {
  cat <<'EOF'
def ext_eco:
  (split("/") | last) as $b
  | (if ($b | contains(".")) then ($b | split(".") | last) else "" end) as $e
  | if (["js", "jsx", "ts", "tsx", "mjs", "cjs"] | index($e)) != null then "npm" else null end;

[inputs] as $lines
| ($lines | map(select(startswith("S\t"))) | .[0][2:] | fromjson) as $suites
| ($lines | map(select(startswith("W\t")) | .[2:])) as $inw
| ($lines | map(select(startswith("C\t")) | .[2:]) | unique) as $changed
| ($lines | map(select(startswith("F\t")) | .[2:]) | unique) as $cands
| ($lines | map(select(startswith("X\t"))) | length) as $skipped
| (if $skipped > 0 then ["skipped \($skipped) path(s) whose name contains a newline"] else [] end) as $skw
| if ($changed | length) == 0
  then { mapped_suites: [], mapped_tests: {}, unmapped_files: [],
         warnings: ((["No changed files"] + $skw) | unique) }
  else
    $mapdoc[0].rules as $rules
    | ($cands | reduce .[] as $c ({}; .[$c] = true)) as $candset
    | ($suites | map(select((.paths | length) > 0) | . + {re: any_re(.paths)})) as $pathed
    | ($suites | map(select((.paths | length) == 0))) as $unpathed
    | any_re([ $suites[].paths[] ]) as $any_suite_paths
    | any_re([ $rules[].tests[] ]) as $any_rule_tests
    # Rules whose source matches at least one changed file ("triggered"), with the
    # existing test files matching their tests globs.
    | ( $rules | to_entries
        | map(.key as $k | .value as $v
              | { n: ($k + 1), source: $v.source, re: ($v.source | any_re([.])), tre: any_re($v.tests) })
        | map(. as $r | $r + { hit: [ $changed[] | select(matches($r.re)) ] }
              | select((.hit | length) > 0))
        | map(. as $r | $r + { tests: [ $cands[] | select(matches($r.tre)) ] }) ) as $trig
    | ( $changed | map(select($candset[.] == true and (matches($any_suite_paths) or matches($any_rule_tests))))
      ) as $own
    | ($own | reduce .[] as $t ({}; .[$t] = true)) as $ownset
    | ( ([ $trig[].tests[] ] + $own) | unique ) as $tfiles
    | def resolve($t):
        ( [ $pathed[] | select(. as $s | ($t | matches($s.re))) | .id ] ) as $hit
        | if ($hit | length) > 0 then $hit
          else ($t | ext_eco) as $eco
            | if $eco == null then []
              else [ $unpathed[] | select(.ecosystem == $eco) | .id ] end
          end;
      (reduce $tfiles[] as $t ({}; .[$t] = resolve($t))) as $res
    # A changed file f resolves files(f) = {f if it is an existing test file} plus the
    # tests of every rule whose source matches f. It is mapped when any of them
    # resolves to a suite. Evaluated per rule rather than per (file, test) pair, so a
    # large change set against a large test tree stays linear: a rule's hit set
    # answers "does this rule contribute to f", its `resolves` flag answers "do its
    # tests reach a suite".
    | ( $trig | map(. + { hitset: (reduce .hit[] as $h ({}; .[$h] = true)),
                          resolves: (([ .tests[] | $res[.][] ] | length) > 0) }) ) as $trig2
    | ( $changed
        | map(select(( ($ownset[.] == true and (($res[.] | length) > 0))
                       or (. as $f | ([ $trig2[] | select(.resolves and .hitset[$f] == true) ] | length) > 0)
                     ) | not))
        | sort ) as $unmapped
    # Every test file in $tfiles was contributed by some changed file, so the
    # (suite, test) pairs are just the resolution table.
    | [ $tfiles[] as $t | $res[$t][] as $s | { s: $s, t: $t } ] as $pairs
    | ($pairs | map(.s) | unique) as $sel
    | ($suites | map({ key: .id, value: . }) | from_entries) as $by
    | [ $sel[] | select(($by[.].command) | test("\\A\\s*\\z")) ] as $dropped
    | [ $sel[] | . as $i | select(($dropped | index($i)) == null) ] as $kept
    | ( reduce ($kept | group_by($by[.].command))[] as $g
          ({}; reduce $g[] as $i (.; .[$i] = $g[0])) ) as $win
    | ($win | [ .[] ] | unique) as $ms
    | ( reduce $pairs[] as $p ({}; ($win[$p.s]) as $w | if $w == null then . else .[$w] += [$p.t] end) ) as $mt0
    | ( reduce $ms[] as $w ({}; .[$w] = (($mt0[$w] // []) | unique)) ) as $mt
    | [ $trig[] | . as $r
        | ($r.hit | length) as $k
        | if ($r.tests | length) == 0
          then "rule \($r.n) (\($r.source)): \($k) changed file(s) matched but no existing test file matched its tests globs"
          elif ([ $r.tests[] | $res[.][] ] | length) == 0
          then "rule \($r.n) (\($r.source)): test files matched but no discovered suite runs them"
          else empty end ] as $rw
    | ($dropped | map("suite \(.) has no runnable command; skipped")) as $dw
    | ( if ($ms | length) == 0
        then ["No tests found for the changed files"]
             + (if ($suites | length) == 0 then ["No test suites discovered"] else [] end)
        else [] end ) as $zw
    | { mapped_suites: $ms, mapped_tests: $mt, unmapped_files: $unmapped,
        warnings: (($inw + $skw + $rw + $dw + $zw) | unique) }
  end
EOF
}

# ---- git ----------------------------------------------------------------------

git_q() { git -C "$ROOT" -c core.quotepath=off "$@"; }

# Changed names for one diff invocation, NUL separated.
diff_z() { git_q diff --name-only -z --no-renames --relative "$@" --; }

# ---- throwaway index (--working) ------------------------------------------------

SCRATCH_DIR=""
SCRATCH_INDEX=""

# Removes the scratch directory; safe to call twice and with nothing created.
cleanup_scratch() {
  if [ -n "$SCRATCH_DIR" ]; then
    rm -rf -- "$SCRATCH_DIR"
    SCRATCH_DIR=""
  fi
}

# Makes SCRATCH_INDEX: a copy of the real index (or, with none, a path inside the
# scratch directory that does not exist, which git reads as an empty index).
prepare_scratch_index() {
  local real
  trap cleanup_scratch EXIT
  trap 'cleanup_scratch; exit 130' INT
  trap 'cleanup_scratch; exit 143' TERM
  trap 'cleanup_scratch; exit 129' HUP
  SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/map-scope.XXXXXX")" \
    || die 1 "could not create a scratch directory under ${TMPDIR:-/tmp}"
  SCRATCH_INDEX="$SCRATCH_DIR/index"
  real="$(git_q rev-parse --git-path index)" || die 1 "git could not locate the index"
  case "$real" in /*) ;; *) real="$ROOT/$real" ;; esac
  if [ -f "$real" ]; then
    cp -p -- "$real" "$SCRATCH_INDEX" || die 1 "could not copy the index to the scratch directory"
  fi
}

# diff_z against the throwaway index; never touches the real one.
diff_z_scratch() { GIT_INDEX_FILE="$SCRATCH_INDEX" diff_z "$@"; }

# emit_tagged <tag> [exists]: NUL-separated paths on stdin -> "<tag><TAB><path>"
# lines. A changed path containing a newline cannot ride a line stream: it is
# replaced by a counted marker. With "exists", paths that are not regular files in the working
# tree are dropped (builtin test, no fork per path).
emit_tagged() {
  local tag="$1" check="${2:-}" p
  while IFS= read -r -d '' p; do
    case "$p" in
      *$'\n'*)
        # Only a changed name is worth reporting; a candidate that cannot be
        # carried simply cannot be a mapped test file.
        [ "$tag" != "C" ] || printf 'X\t1\n'
        continue ;;
    esac
    if [ -n "$check" ] && [ ! -f "$ROOT/$p" ]; then
      continue
    fi
    printf '%s\t%s\n' "$tag" "$p"
  done
}

head_exists() { git_q rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; }

verify_commit() { git_q rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# Sets CHANGED_TAGGED. Exits 4 for an unknown revision or a failed diff.
acquire_changes() {
  local empty base left right
  empty="$(git_q hash-object -t tree /dev/null)" || die 1 "git could not compute the empty tree"
  case "$MODE" in
    rev)
      verify_commit "$REV" || die 4 "unknown revision: $REV"
      if verify_commit "$REV^1"; then base="$REV^1"; else base="$empty"; fi
      CHANGED_TAGGED="$(diff_z "$base" "$REV" | emit_tagged C)" \
        || die 4 "git could not diff revision $REV"
      ;;
    range)
      case "$RANGE" in
        *...*) left="${RANGE%%...*}"; right="${RANGE#*...}" ;;
        *..*) left="${RANGE%%..*}"; right="${RANGE#*..}" ;;
        *) die 2 "--range expects <a>..<b> or <a>...<b>, got: $RANGE" ;;
      esac
      case "$left" in -*) die 2 "--range sides must not start with '-'" ;; esac
      case "$right" in -*) die 2 "--range sides must not start with '-'" ;; esac
      [ -n "$left" ] || left="HEAD"
      [ -n "$right" ] || right="HEAD"
      verify_commit "$left" || die 4 "unknown revision: $left"
      verify_commit "$right" || die 4 "unknown revision: $right"
      CHANGED_TAGGED="$(diff_z "$RANGE" | emit_tagged C)" \
        || die 4 "git could not diff range $RANGE"
      ;;
    staged)
      if head_exists; then
        CHANGED_TAGGED="$(diff_z --cached HEAD | emit_tagged C)" || die 1 "git diff --cached failed"
      else
        CHANGED_TAGGED="$(diff_z --cached "$empty" | emit_tagged C)" || die 1 "git diff --cached failed"
      fi
      ;;
    files)
      [ -f "$FILES_FROM" ] && [ -r "$FILES_FROM" ] \
        || die 3 "--files-from: $FILES_FROM is missing or unreadable"
      CHANGED_TAGGED="$(sed -e 's/\r$//' -e '/^$/d' "$FILES_FROM" | tr '\n' '\0' | emit_tagged C)" \
        || die 3 "--files-from: $FILES_FROM is unreadable"
      ;;
    working)
      prepare_scratch_index
      if head_exists; then
        CHANGED_TAGGED="$({ diff_z_scratch HEAD && git_q ls-files -z --others --exclude-standard; } \
          | emit_tagged C)" || die 1 "git could not list the working-tree changes"
      else
        CHANGED_TAGGED="$({ diff_z_scratch --cached "$empty" && diff_z_scratch \
          && git_q ls-files -z --others --exclude-standard; } | emit_tagged C)" \
          || die 1 "git could not list the working-tree changes"
      fi
      ;;
  esac
}

# ---- mapping file --------------------------------------------------------------

# Where the configs directory is; identical to discover-tests.sh's config_dir():
# with --root it is resolved against that root, falling back to the resolver's
# relative path joined onto the root.
config_dir() {
  local dir="" rel=""
  if [ -n "$RESOLVER" ]; then
    if [ -n "$ROOT_ARG" ]; then
      dir="$(JENGA_PROJECT_ROOT="$ROOT" bash "$RESOLVER" get configs 2>/dev/null)" || dir=""
      if [ -z "$dir" ]; then
        rel="$(cd "$ROOT" && JENGA_PROJECT_ROOT="" bash "$RESOLVER" --relative get configs 2>/dev/null)" || rel=""
        [ -z "$rel" ] || dir="$ROOT/$rel"
      fi
    else
      dir="$(cd "$ROOT" && bash "$RESOLVER" get configs 2>/dev/null)" || dir=""
    fi
  fi
  printf '%s' "$dir"
}

# Sets MAP_FILE (path to read) and MAP_DISPLAY (name used in messages), and may
# append to BASH_WARNINGS. Exits 3 when the chosen file is unusable.
resolve_map() {
  local cfg_dir cfg val rel shipped
  if [ -n "$MAP_ARG" ]; then
    MAP_FILE="$MAP_ARG"
    MAP_DISPLAY="$MAP_ARG"
    [ -f "$MAP_FILE" ] && [ -r "$MAP_FILE" ] || die 3 "$MAP_DISPLAY: scope map file is missing or unreadable"
    return 0
  fi

  val=""
  cfg_dir="$(config_dir)"
  cfg="$cfg_dir/test-config.json"
  if [ -n "$cfg_dir" ] && [ -e "$cfg" ]; then
    # "" key absent/null, "S<path>" a string value, "T" a non-string value.
    if [ ! -f "$cfg" ] || [ ! -r "$cfg" ] \
       || ! val="$(jq -r 'if type == "object"
                          then (.commit_scope_map_file
                                | if . == null then "" elif type == "string" then "S" + . else "T" end)
                          else error("not an object") end' "$cfg" 2>/dev/null)"; then
      BASH_WARNINGS="${BASH_WARNINGS}W"$'\t'"test-config.json could not be read; using the default scope map"$'\n'
      val=""
    fi
  fi

  if [ -n "$val" ]; then
    if [ "$val" = "T" ]; then
      die 3 "test-config.json: commit_scope_map_file must be a string path"
    fi
    rel="${val#S}"
    case "$rel" in
      ""|/*|*$'\n'*) die 3 "test-config.json: commit_scope_map_file must be a non-empty path relative to the root: $rel" ;;
    esac
    case "/$rel/" in
      */../*) die 3 "test-config.json: commit_scope_map_file must not contain '..' segments: $rel" ;;
    esac
    case "$rel" in
      *.json) ;;
      *) die 3 "test-config.json: commit_scope_map_file must end in .json: $rel" ;;
    esac
    MAP_FILE="$ROOT/$rel"
    MAP_DISPLAY="$rel"
    [ -f "$MAP_FILE" ] && [ -r "$MAP_FILE" ] \
      || die 3 "$MAP_DISPLAY: scope map file named by commit_scope_map_file does not exist or is unreadable"
    return 0
  fi

  if [ -f "$ROOT/templates/test-scope-map.json" ]; then
    MAP_FILE="$ROOT/templates/test-scope-map.json"
    MAP_DISPLAY="templates/test-scope-map.json"
  elif shipped="$(resolve_helper templates/test-scope-map.json)"; then
    MAP_FILE="$shipped"
    MAP_DISPLAY="templates/test-scope-map.json (shipped copy)"
  else
    die 3 "templates/test-scope-map.json: the default scope map could not be found"
  fi
  [ -r "$MAP_FILE" ] || die 3 "$MAP_DISPLAY: scope map file is unreadable"
}

# Validates MAP_FILE; prints each problem on stderr and exits 3 when there is one.
validate_map() {
  local problems line
  if ! jq -e . "$MAP_FILE" >/dev/null 2>&1; then
    die 3 "$MAP_DISPLAY: not valid JSON"
  fi
  problems="$(jq -rs "$(glob_defs)
$(validate_map_program)" "$MAP_FILE")" || die 1 "jq failed while validating $MAP_DISPLAY"
  [ -z "$problems" ] && return 0
  while IFS= read -r line; do
    err "$MAP_DISPLAY: $line"
  done <<EOF
$problems
EOF
  exit 3
}

# ---- suites --------------------------------------------------------------------

# normalise_suites <label> <raw json> <failure code>: sets SUITES_JSON and appends
# the normaliser's warnings to BASH_WARNINGS. A bad document exits with <code>.
normalise_suites() {
  local label="$1" raw="$2" code="$3" out problems line
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    die "$code" "$label: not valid JSON"
  fi
  out="$(printf '%s' "$raw" | jq -c "$(glob_defs)
$(normalize_suites_program)")" || die 1 "jq failed while reading $label"
  problems="$(printf '%s' "$out" | jq -r '.problems[]')"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do
      err "$label: $line"
    done <<EOF
$problems
EOF
    exit "$code"
  fi
  SUITES_JSON="$(printf '%s' "$out" | jq -c '.suites')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    BASH_WARNINGS="${BASH_WARNINGS}W"$'\t'"$line"$'\n'
  done <<EOF
$(printf '%s' "$out" | jq -r '.warnings[]')
EOF
}

# ---- main ----------------------------------------------------------------------

main() {
  local root_arg="" suites_arg="" have_suites=0 sources=0 discover raw rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--root requires a directory argument"; usage >&2; exit 2; }
        root_arg="$2"; shift 2 ;;
      --map)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--map requires a file argument"; usage >&2; exit 2; }
        MAP_ARG="$2"; shift 2 ;;
      --suites)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--suites requires a file argument (or - for stdin)"; usage >&2; exit 2; }
        suites_arg="$2"; have_suites=1; shift 2 ;;
      --rev)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--rev requires a commit argument"; usage >&2; exit 2; }
        case "$2" in -*) err "--rev argument must not start with '-'"; usage >&2; exit 2 ;; esac
        MODE="rev"; REV="$2"; sources=$((sources + 1)); shift 2 ;;
      --range)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--range requires a <a>..<b> argument"; usage >&2; exit 2; }
        MODE="range"; RANGE="$2"; sources=$((sources + 1)); shift 2 ;;
      --staged) MODE="staged"; sources=$((sources + 1)); shift ;;
      --working) MODE="working"; sources=$((sources + 1)); shift ;;
      --files-from)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { err "--files-from requires a file argument"; usage >&2; exit 2; }
        MODE="files"; FILES_FROM="$2"; sources=$((sources + 1)); shift 2 ;;
      -h|--help|help) usage; exit 0 ;;
      *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
  done
  if [ "$sources" -gt 1 ]; then
    err "at most one of --rev, --range, --staged, --working, --files-from may be given"
    usage >&2
    exit 2
  fi
  [ -n "$MODE" ] || MODE="working"

  command -v jq >/dev/null 2>&1 || die 1 "jq is required but was not found on PATH"
  command -v git >/dev/null 2>&1 || die 1 "git is required but was not found on PATH"

  ROOT_ARG="$root_arg"
  RESOLVER="$(resolve_helper scripts/resolve-root.sh)" || RESOLVER=""
  if [ -n "$root_arg" ]; then
    [ -d "$root_arg" ] || die 2 "--root is not a directory: $root_arg"
    ROOT="$(cd -- "$root_arg" && pwd)"
  else
    [ -n "$RESOLVER" ] || die 1 "could not locate scripts/resolve-root.sh"
    ROOT="$(bash "$RESOLVER" root)" || die 1 "could not resolve the working root"
    [ -d "$ROOT" ] || die 1 "the resolved root is not a directory: $ROOT"
  fi

  if [ "$(git_q rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
    die 4 "not a git repository: $ROOT"
  fi

  acquire_changes
  resolve_map
  validate_map

  if [ "$have_suites" -eq 1 ]; then
    if [ "$suites_arg" = "-" ]; then
      raw="$(cat)" || die 3 "--suites: could not read standard input"
    else
      [ -f "$suites_arg" ] && [ -r "$suites_arg" ] || die 3 "--suites: $suites_arg is missing or unreadable"
      raw="$(cat "$suites_arg")" || die 3 "--suites: $suites_arg is unreadable"
    fi
    normalise_suites "--suites input" "$raw" 3
  fi

  # No changes: nothing to map, and nothing to discover.
  if [ -z "$CHANGED_TAGGED" ]; then
    printf '%s\n' '{"mapped_suites":[],"mapped_tests":{},"unmapped_files":[],"warnings":["No changed files"]}'
    exit 0
  fi

  if [ "$have_suites" -eq 0 ]; then
    discover="$SCRIPT_DIR/discover-tests.sh"
    [ -f "$discover" ] || die 1 "could not locate discover-tests.sh next to $SCRIPT_NAME"
    rc=0
    raw="$(bash "$discover" --root "$ROOT")" || rc=$?
    [ "$rc" -eq 0 ] || die 1 "discover-tests.sh failed with exit status $rc"
    # Discovery's own warnings travel with the result, prefixed.
    BASH_WARNINGS="${BASH_WARNINGS}$(printf '%s' "$raw" | jq -r '.warnings[]? | "W\tdiscovery: " + .' 2>/dev/null || true)"$'\n'
    normalise_suites "discover-tests.sh output" "$raw" 1
  fi

  # One pass; the line stream is the only data channel (no argv size limit).
  { printf 'S\t%s\n' "$SUITES_JSON"
    printf '%s' "$BASH_WARNINGS"
    printf '%s\n' "$CHANGED_TAGGED"
    git_q ls-files -z --cached --others --exclude-standard | emit_tagged F exists
  } | jq -cnR --slurpfile mapdoc "$MAP_FILE" "$(glob_defs)
$(match_program)" || die 1 "the matching pass failed"
}

ROOT=""
ROOT_ARG=""
RESOLVER=""
MODE=""
REV=""
RANGE=""
FILES_FROM=""
MAP_ARG=""
MAP_FILE=""
MAP_DISPLAY=""
SUITES_JSON="[]"
CHANGED_TAGGED=""
BASH_WARNINGS=""
main "$@"

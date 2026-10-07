#!/usr/bin/env bash
# detect-conventions.sh - detect the conventions a project already follows (E69_S02).
#
# The deterministic first half of the j.conventions wizard: for each of the v1 convention categories it
# reports the standard the project appears to follow, with concrete evidence and a confidence, so the
# wizard can offer the project's own convention as the first option. Human-readable write-up of the
# output: project/documentation/project-conventions.md, section "Detection output".
#
# Usage:
#   detect-conventions.sh            inspect the project root and print the JSON document below
#   detect-conventions.sh --help     print this header
#
# Project root: scripts/resolve-root.sh (JENGA_PROJECT_ROOT is honoured, so tests can aim the script at a
# scratch tree). When no workflow.json registry can be found the directory itself (JENGA_PROJECT_ROOT, else
# $PWD) is inspected and one warning says so, so an empty directory still yields a valid document.
#
# Output contract (stdout, one JSON object):
#   {
#     "detect_version": 1,
#     "categories": {
#       "<category id>": {
#         "detected":     <object | null>,   the category's `values` shape from templates/conventions-schema.json
#         "preset_match": "<preset id>" | null,   id from templates/conventions-presets.json the value corresponds to
#         "evidence":     "<text>",          concrete and checkable ("41 of the last 50 ..."); "" when nothing found
#         "confidence":   "high" | "medium" | "low" | "none",   "none" exactly when detected is null
#         "preset_only":  <boolean>          true: no reliable detector exists, offer presets only
#       }, ...                               one entry for EVERY category id in the schema, in schema order
#     },
#     "warnings": [ "<text>", ... ]          sources that were skipped (malformed / unreadable) and other notes
#   }
# The category id list is read from the schema, never duplicated here. A category with no signal is
# {detected: null, preset_match: null, evidence: "", confidence: "none", preset_only: false}.
#
# Guarantees:
#   - Read-only: writes nothing inside the project (no temp file, no git write; `git status` is not used
#     because it refreshes the index). Detected commands (a package.json `lint` script ...) are reported,
#     never executed.
#   - Exit 0 for every project: empty directory, repository without commits, malformed source files (the
#     file is skipped and one line naming it is added to `warnings`).
#   - Environment failures are the only non-zero exits: 2 usage, 3 `jq` missing, 4 schema unreadable.
#
# Environment overrides (tests): JENGA_PROJECT_ROOT, JENGA_CONVENTIONS_SCHEMA, JENGA_CONVENTIONS_PRESETS.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).

set -u
export GIT_OPTIONAL_LOCKS=0

SELF="detect-conventions.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RESOLVE_ROOT="$PACKAGE_ROOT/scripts/resolve-root.sh"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$PACKAGE_ROOT/templates/conventions-schema.json}"
PRESETS="${JENGA_CONVENTIONS_PRESETS:-$PACKAGE_ROOT/templates/conventions-presets.json}"

# Detection thresholds (documented in project-conventions.md, "Detection output").
COMMIT_SAMPLE=50          # non-board commit subjects sampled
COMMIT_SCAN_LIMIT=200     # most recent non-merge commits looked at while filling the sample
# Board commits are mandatory EST subjects (epic E69 Decision 2) and say nothing about the project's own style.
EST_RE='^(task|story|epic)\(E[0-9]+(_S[0-9]+(_T[0-9]+)?)?\):'

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) printf '%s: unknown argument: %s\n' "$SELF" "$1" >&2; usage >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: jq is required but was not found on PATH\n' "$SELF" >&2
  exit 3
fi

# --- warnings --------------------------------------------------------------------------------------------
WARNINGS=""
warn() {
  local m
  m=$(printf '%s' "$*" | tr '\n\r' '  ')
  WARNINGS="$WARNINGS$m"$'\n'
}

# --- category ids from the schema ---------------------------------------------------------------------------
CATEGORY_IDS=$(jq -r '.categories | keys_unsorted[]' "$SCHEMA" 2>/dev/null)
if [ -z "$CATEGORY_IDS" ]; then
  printf '%s: cannot read the category list from %s\n' "$SELF" "$SCHEMA" >&2
  exit 4
fi

# --- project root ----------------------------------------------------------------------------------------
ROOT=""
HAVE_REGISTRY=0
if r=$(bash "$RESOLVE_ROOT" root 2>/dev/null) && [ -n "$r" ] && [ -d "$r" ]; then
  ROOT=$(cd "$r" && pwd -P)
  case "$(bash "$RESOLVE_ROOT" source 2>/dev/null)" in
    env|search) HAVE_REGISTRY=1 ;;
  esac
else
  if [ -n "${JENGA_PROJECT_ROOT:-}" ] && [ -d "${JENGA_PROJECT_ROOT}" ]; then
    ROOT=$(cd "$JENGA_PROJECT_ROOT" && pwd -P)
  else
    ROOT=$(pwd -P)
  fi
fi
[ "$HAVE_REGISTRY" = 1 ] || warn "no workflow.json registry found; inspecting $ROOT without one"

# resolve_dir <workflow.json paths key> <default path relative to ROOT>: sets RESOLVED_DIR (absolute, built on the
# physical ROOT) through scripts/resolve-root.sh --relative so a relocated path is honoured; a failed resolution
# falls back to the default (with a warning when a registry exists). Not run in a subshell, so the warning is kept.
RESOLVED_DIR=""
resolve_dir() {
  local out
  if [ "$HAVE_REGISTRY" = 1 ] && out=$(bash "$RESOLVE_ROOT" --relative get "$1" 2>/dev/null) && [ -n "$out" ]; then
    case "$out" in
      /*) RESOLVED_DIR="$out" ;;
      *) RESOLVED_DIR="$ROOT/${out#./}" ;;
    esac
    return 0
  fi
  RESOLVED_DIR="$ROOT/$2"
  if [ "$HAVE_REGISTRY" = 1 ]; then
    warn "workflow.json paths.$1 could not be resolved (registry unreadable?); using the default $2"
  fi
}

# --- git (read-only, only when ROOT is itself a repository root) ---------------------------------------------
IS_GIT=0
HAS_COMMITS=0
top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$ROOT" ]; then
  IS_GIT=1
  if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    HAS_COMMITS=1
  fi
fi

# --- JSON source files: parse once, warn once --------------------------------------------------------------
OK_JSON="|"
BAD_JSON="|"
# json_valid <path relative to ROOT, or absolute>: 0 when the file exists and parses; 1 when absent (silent) or when it is
# unreadable or malformed (one warning naming the file, then skipped by every detector).
json_valid() {
  local f="$1" rel
  case "$1" in
    /*) rel="${1#"$ROOT"/}" ;;
    *) f="$ROOT/$1"; rel="$1" ;;
  esac
  [ -f "$f" ] || return 1
  case "$BAD_JSON" in *"|$rel|"*) return 1 ;; esac
  case "$OK_JSON" in *"|$rel|"*) return 0 ;; esac
  if [ ! -r "$f" ]; then
    warn "$rel is unreadable; skipped"
    BAD_JSON="$BAD_JSON$rel|"
    return 1
  fi
  if jq empty "$f" >/dev/null 2>&1; then
    OK_JSON="$OK_JSON$rel|"
    return 0
  fi
  warn "$rel is not valid JSON; skipped"
  BAD_JSON="$BAD_JSON$rel|"
  return 1
}

# --- preset catalog access ----------------------------------------------------------------------------------
PRESETS_OK=1
if ! jq empty "$PRESETS" >/dev/null 2>&1; then
  PRESETS_OK=0
  warn "preset catalog ${PRESETS#"$PACKAGE_ROOT"/} is missing or malformed; preset_match left null"
fi
# preset_values <category> <preset id>: prints the preset's `values` object (compact JSON), nothing when the
# catalog or the preset is unavailable. Detected values are built from this so they cannot drift from the catalog.
# Runs inside command substitutions, so it never warns itself (the catalog is checked once, above).
preset_values() {
  [ "$PRESETS_OK" = 1 ] || return 1
  jq -c --arg c "$1" --arg i "$2" '.categories[$c] // [] | map(select(.id == $i)) | .[0].values // empty' "$PRESETS" 2>/dev/null
}

# --- per-category result ------------------------------------------------------------------------------------
D_DETECTED="" D_PRESET="" D_EVIDENCE="" D_CONF="none" D_PREONLY="false"
reset_result() {
  D_DETECTED=""
  D_PRESET=""
  D_EVIDENCE=""
  D_CONF="none"
  D_PREONLY="false"
}

# set_detected_from_preset <category> <preset id> [<extra JSON object merged over the preset values>]
# Sets D_DETECTED to the preset's values (plus the extras) and D_PRESET to the id.
set_detected_from_preset() {
  local pv extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  if pv=$(preset_values "$1" "$2") && [ -n "$pv" ]; then
    D_PRESET="$2"
    D_DETECTED=$(jq -nc --argjson a "$pv" --argjson b "$extra" '$a + $b')
  else
    D_PRESET=""
    D_DETECTED="$extra"
  fi
}

# set_detected <category> <preset id or ""> <detected JSON object>
# Sets D_DETECTED as given and D_PRESET to the id only when that preset exists in the catalog (the catalog's own
# values are NOT copied: some carry placeholder commands that must never appear as a detected value).
set_detected() {
  local pv
  D_DETECTED="$3"
  D_PRESET=""
  if [ -n "$2" ] && pv=$(preset_values "$1" "$2") && [ -n "$pv" ]; then
    D_PRESET="$2"
  fi
}

# --- small shared helpers -----------------------------------------------------------------------------------
# files_matching <glob>...: prints every regular file under ROOT matching a glob, relative to ROOT, one per line.
files_matching() {
  local g f
  for g in "$@"; do
    for f in "$ROOT"/$g; do
      [ -f "$f" ] && printf '%s\n' "${f#"$ROOT"/}"
    done
  done
}

# join_csv: stdin lines -> "a, b, c"
join_csv() {
  local out="" l
  while IFS= read -r l; do
    [ -n "$l" ] && out="${out:+$out, }$l"
  done
  printf '%s' "$out"
}

# pkg_jq <jq filter>: prints the filter's result over package.json; nothing when it is absent or malformed.
pkg_jq() {
  json_valid package.json || return 0
  jq -r "$1" "$ROOT/package.json" 2>/dev/null
}

# git_tracked <path relative to ROOT>: 0 when git tracks the file.
git_tracked() {
  [ "$IS_GIT" = 1 ] && git -C "$ROOT" ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

# scan_lockfiles: sets LOCK_FILES (comma list of lockfiles present), LOCK_FIRST (the first one, by precedence) and
# PKG_MANAGER (from the packageManager field of package.json when present, else from the first lockfile).
LOCKS_SCANNED=0
LOCK_FILES="" LOCK_FIRST="" PKG_MANAGER=""
scan_lockfiles() {
  [ "$LOCKS_SCANNED" = 0 ] || return 0
  LOCKS_SCANNED=1
  local pair f pm pmfield
  for pair in package-lock.json:npm yarn.lock:yarn pnpm-lock.yaml:pnpm bun.lockb:bun bun.lock:bun uv.lock:uv \
              poetry.lock:poetry Pipfile.lock:pipenv Cargo.lock:cargo go.sum:go; do
    f="${pair%%:*}"
    pm="${pair##*:}"
    if [ -f "$ROOT/$f" ]; then
      LOCK_FILES="${LOCK_FILES:+$LOCK_FILES, }$f"
      if [ -z "$LOCK_FIRST" ]; then
        LOCK_FIRST="$f"
        PKG_MANAGER="$pm"
      fi
    fi
  done
  pmfield=$(pkg_jq '.packageManager // empty | if type == "string" then . else empty end' | sed 's/@.*//')
  if [ -n "$pmfield" ]; then
    PKG_MANAGER="$pmfield"
  fi
}

ENTRIES=""
emit_category() {
  local id="$1" entry
  [ -n "$D_DETECTED" ] || D_DETECTED="null"
  if [ "$D_DETECTED" = "null" ]; then
    D_CONF="none"
    D_PRESET=""
  fi
  entry=$(jq -nc --argjson d "$D_DETECTED" --arg p "$D_PRESET" --arg e "$D_EVIDENCE" --arg c "$D_CONF" --argjson po "$D_PREONLY" \
    '{detected: $d, preset_match: (if $p == "" then null else $p end), evidence: $e, confidence: $c, preset_only: $po}')
  ENTRIES="$ENTRIES$(jq -nc --arg id "$id" --argjson e "$entry" '{id: $id, entry: $e}')"$'\n'
}

# --- detector: commit-format ------------------------------------------------------------------------------
# Sample = the last COMMIT_SAMPLE non-merge, non-board commit subjects (looking back at most
# COMMIT_SCAN_LIMIT commits). Conventional Commits when >= 20% match the preset regex:
# high >= 80%, medium 50-79%, low 20-49%; a commitlint config that extends a conventional preset sets high.
COMMITLINT_FILES=""
COMMITLINT_CONVENTIONAL=0
find_commitlint() {
  local n f first
  COMMITLINT_FILES=""
  COMMITLINT_CONVENTIONAL=0
  for n in commitlint.config.js commitlint.config.cjs commitlint.config.mjs commitlint.config.ts commitlint.config.cts commitlint.config.mts \
           .commitlintrc .commitlintrc.json .commitlintrc.yaml .commitlintrc.yml \
           .commitlintrc.js .commitlintrc.cjs .commitlintrc.mjs .commitlintrc.ts .commitlintrc.cts .commitlintrc.mts; do
    f="$ROOT/$n"
    [ -f "$f" ] || continue
    if [ ! -r "$f" ]; then
      warn "$n is unreadable; skipped"
      continue
    fi
    # Only JSON-shaped configs can be checked for syntax; JS/TS/YAML ones are presence-only signals.
    first=$(sed -e 's/^[[:space:]]*//' "$f" 2>/dev/null | head -c1)
    if [ "$n" = ".commitlintrc.json" ] || { [ "$n" = ".commitlintrc" ] && [ "$first" = "{" ]; }; then
      if ! jq empty "$f" >/dev/null 2>&1; then
        warn "$n is not valid JSON; skipped"
        continue
      fi
    fi
    COMMITLINT_FILES="${COMMITLINT_FILES:+$COMMITLINT_FILES, }$n"
    if grep -qi 'conventional' "$f" 2>/dev/null; then
      COMMITLINT_CONVENTIONAL=1
    fi
  done
  if json_valid package.json && jq -e 'has("commitlint")' "$ROOT/package.json" >/dev/null 2>&1; then
    COMMITLINT_FILES="${COMMITLINT_FILES:+$COMMITLINT_FILES, }package.json (commitlint key)"
    if jq -e '.commitlint | tostring | test("conventional"; "i")' "$ROOT/package.json" >/dev/null 2>&1; then
      COMMITLINT_CONVENTIONAL=1
    fi
  fi
}

detect_commit_format() {
  reset_result
  local cc_regex pv subj all total=0 match=0 excluded=0 ev="" conf="none" detect=0 sample_txt=""
  if pv=$(preset_values commit-format conventional-commits) && [ -n "$pv" ]; then
    cc_regex=$(printf '%s' "$pv" | jq -r '.message_regex // empty')
  fi
  [ -n "${cc_regex:-}" ] || cc_regex='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: .+'

  find_commitlint

  if [ "$HAS_COMMITS" = 1 ]; then
    all=$(git -C "$ROOT" log --no-merges -n "$COMMIT_SCAN_LIMIT" --format=%s 2>/dev/null)
    while IFS= read -r subj; do
      [ -n "$subj" ] || continue
      if [[ $subj =~ $EST_RE ]]; then
        excluded=$((excluded + 1))
        continue
      fi
      total=$((total + 1))
      if [[ $subj =~ $cc_regex ]]; then
        match=$((match + 1))
      fi
      [ "$total" -lt "$COMMIT_SAMPLE" ] || break
    done <<< "$all"
  fi

  if [ "$total" -gt 0 ]; then
    sample_txt="$match of the last $total commit subjects match type(scope): msg"
    if [ "$excluded" -gt 0 ]; then
      sample_txt="$sample_txt ($excluded EST board subjects excluded)"
    fi
    if [ $((match * 100)) -ge $((80 * total)) ]; then
      conf="high"; detect=1
    elif [ $((match * 100)) -ge $((50 * total)) ]; then
      conf="medium"; detect=1
    elif [ $((match * 100)) -ge $((20 * total)) ]; then
      conf="low"; detect=1
    fi
  elif [ "$excluded" -gt 0 ]; then
    sample_txt="no non-board commit subjects to sample ($excluded EST board subjects excluded)"
  fi

  if [ -n "$COMMITLINT_FILES" ]; then
    if [ "$COMMITLINT_CONVENTIONAL" = 1 ]; then
      detect=1
      conf="high"
    fi
    ev="${sample_txt:+$sample_txt; }commitlint config found: $COMMITLINT_FILES"
    [ "$COMMITLINT_CONVENTIONAL" = 1 ] && ev="$ev (extends a conventional preset)"
  else
    ev="$sample_txt"
    if [ "$detect" = 0 ] && [ -n "$sample_txt" ]; then
      ev="$sample_txt; below the 20% detection floor"
    fi
  fi

  D_EVIDENCE="$ev"
  if [ "$detect" = 1 ]; then
    D_CONF="$conf"
    set_detected_from_preset commit-format conventional-commits '{"style":"conventional-commits"}'
  fi
}

# --- detector: branching ------------------------------------------------------------------------------------
# Branch names (local and remote, deduplicated, remote prefix stripped). git-flow = develop plus release/ or
# hotfix/ (high with feature/ branches, else medium); github-flow = feature/ or feat/ branches (high from 3,
# else medium); trunk-based = only trunk-named branches (medium when a remote ref exists, else low); any other
# branch layout is reported as not detected.
detect_branching() {
  reset_result
  [ "$IS_GIT" = 1 ] || return 0
  local names total feat rel hot dev other trunkset has_remote default_branch="" model="" conf="none" ev="" db_json
  names=$(git -C "$ROOT" for-each-ref --format='%(refname)' refs/heads refs/remotes 2>/dev/null \
    | sed -e 's#^refs/heads/##' -e 's#^refs/remotes/[^/]*/##' | grep -v '^HEAD$' | sort -u)
  [ -n "$names" ] || return 0
  total=$(printf '%s\n' "$names" | grep -c .)
  feat=$(printf '%s\n' "$names" | grep -Ec '^(feature|feat)/')
  rel=$(printf '%s\n' "$names" | grep -Ec '^release/')
  hot=$(printf '%s\n' "$names" | grep -Ec '^hotfix/')
  dev=$(printf '%s\n' "$names" | grep -Ecx 'develop|development')
  trunkset=$(printf '%s\n' "$names" | grep -Ecx 'main|master|trunk|develop|development')
  other=$((total - trunkset - feat - rel - hot))
  has_remote=0
  git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null | grep -qv '/HEAD$' && has_remote=1

  default_branch=$(git -C "$ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  if [ -z "$default_branch" ]; then
    default_branch=$(printf '%s\n' "$names" | grep -Ex 'main|master|trunk' | head -n1)
  fi
  if [ -z "$default_branch" ]; then
    default_branch=$(git -C "$ROOT" symbolic-ref -q --short HEAD 2>/dev/null)
  fi

  if [ "$dev" -gt 0 ] && [ $((rel + hot)) -gt 0 ]; then
    model="git-flow"
    if [ "$feat" -gt 0 ]; then conf="high"; else conf="medium"; fi
  elif [ "$feat" -gt 0 ]; then
    model="github-flow"
    if [ "$feat" -ge 3 ]; then conf="high"; else conf="medium"; fi
  elif [ "$other" -le 0 ] && [ "$total" -eq "$trunkset" ]; then
    model="trunk-based"
    if [ "$has_remote" = 1 ]; then conf="medium"; else conf="low"; fi
  fi

  ev="$total branches (local and remote, deduplicated): $feat feature/, $rel release/, $hot hotfix/, $dev develop"
  if [ -n "$default_branch" ]; then
    ev="$ev; default branch $default_branch"
  fi
  if [ -z "$model" ]; then
    D_EVIDENCE="$ev; no recognised branching pattern ($other other branches)"
    return 0
  fi
  D_EVIDENCE="$ev"
  D_CONF="$conf"
  db_json='{}'
  if [ -n "$default_branch" ]; then
    db_json=$(jq -nc --arg d "$default_branch" '{default_branch: $d}')
  fi
  set_detected_from_preset branching "$model" "$(jq -nc --arg m "$model" --argjson d "$db_json" '{model: $m} + $d')"
}

# --- detector: formatting-linting -------------------------------------------------------------------------
# Tools: .editorconfig, eslint (eslint.config.*, .eslintrc*, package.json eslintConfig), prettier (.prettierrc*,
# prettier.config.*, package.json prettier), ruff (ruff.toml, .ruff.toml, [tool.ruff] in pyproject.toml), gofmt
# (go.mod). lint_command / format_command are `<package manager> run <script>` for package.json scripts `lint`
# and `format` (else `fmt`); the script body is quoted in evidence and never executed.
# Confidence: high = a tool config AND a runnable script, medium = a tool config alone, low = .editorconfig alone
# or a script alone. approach: formatter-and-linter when any tool config or script exists, else editorconfig-only.
detect_formatting_linting() {
  reset_result
  local ev="" tools="" f has_tool=0 has_ec=0 has_script=0 lint_cmd="" fmt_cmd="" lint_body="" fmt_body="" conf="none"
  local run="npm run" sname

  if [ -f "$ROOT/.editorconfig" ]; then
    has_ec=1
    tools=".editorconfig"
  fi

  f=$(files_matching 'eslint.config.*' '.eslintrc' '.eslintrc.*' | join_csv)
  if [ -z "$f" ] && [ -n "$(pkg_jq 'if has("eslintConfig") then "y" else empty end')" ]; then
    f="package.json (eslintConfig key)"
  fi
  if [ -n "$f" ]; then
    has_tool=1
    tools="${tools:+$tools; }eslint: $f"
  fi

  f=$(files_matching '.prettierrc' '.prettierrc.*' 'prettier.config.*' | join_csv)
  if [ -z "$f" ] && [ -n "$(pkg_jq 'if has("prettier") then "y" else empty end')" ]; then
    f="package.json (prettier key)"
  fi
  if [ -n "$f" ]; then
    has_tool=1
    tools="${tools:+$tools; }prettier: $f"
  fi

  f=$(files_matching 'ruff.toml' '.ruff.toml' | join_csv)
  if [ -z "$f" ] && [ -f "$ROOT/pyproject.toml" ] && grep -q '^\[tool\.ruff' "$ROOT/pyproject.toml" 2>/dev/null; then
    f="pyproject.toml ([tool.ruff])"
  fi
  if [ -n "$f" ]; then
    has_tool=1
    tools="${tools:+$tools; }ruff: $f"
  fi

  if [ -f "$ROOT/go.mod" ]; then
    has_tool=1
    tools="${tools:+$tools; }gofmt: go.mod"
  fi

  scan_lockfiles
  case "$PKG_MANAGER" in
    yarn|pnpm|bun) run="$PKG_MANAGER run" ;;
  esac
  lint_body=$(pkg_jq '.scripts.lint // empty | if type == "string" then . else empty end' | tr '\n\r' '  ' | sed -e 's/^ *//' -e 's/ *$//')
  for sname in format fmt; do
    fmt_body=$(pkg_jq ".scripts[\"$sname\"] // empty | if type == \"string\" then . else empty end" | tr '\n\r' '  ' | sed -e 's/^ *//' -e 's/ *$//')
    if [ -n "$fmt_body" ]; then
      fmt_cmd="$run $sname"
      break
    fi
  done
  [ -n "$lint_body" ] && lint_cmd="$run lint"
  [ -n "$lint_cmd$fmt_cmd" ] && has_script=1

  if [ "$has_tool" = 1 ] && [ "$has_script" = 1 ]; then
    conf="high"
  elif [ "$has_tool" = 1 ]; then
    conf="medium"
  elif [ "$has_ec" = 1 ] || [ "$has_script" = 1 ]; then
    conf="low"
  else
    return 0
  fi

  [ -n "$tools" ] && ev="found $tools"
  if [ "$has_script" = 1 ]; then
    ev="${ev:+$ev; }package.json scripts:"
    [ -n "$lint_cmd" ] && ev="$ev lint = \"$lint_body\""
    if [ -n "$fmt_cmd" ]; then
      [ -n "$lint_cmd" ] && ev="$ev,"
      ev="$ev ${fmt_cmd##* } = \"$fmt_body\""
    fi
  fi

  local detected preset
  if [ "$has_tool" = 1 ] || [ "$has_script" = 1 ]; then
    preset="formatter-and-linter"
    detected='{"approach":"formatter-and-linter"}'
  else
    preset="editorconfig-only"
    detected='{"approach":"editorconfig-only"}'
  fi
  [ -n "$fmt_cmd" ] && detected=$(printf '%s' "$detected" | jq -c --arg c "$fmt_cmd" '. + {format_command: $c}')
  [ -n "$lint_cmd" ] && detected=$(printf '%s' "$detected" | jq -c --arg c "$lint_cmd" '. + {lint_command: $c}')
  [ "$has_ec" = 1 ] && detected=$(printf '%s' "$detected" | jq -c '. + {editorconfig: true}')
  set_detected formatting-linting "$preset" "$detected"
  D_EVIDENCE="$ev"
  D_CONF="$conf"
}

# --- detector: language-tooling ---------------------------------------------------------------------------
# Languages come from manifests (package.json, tsconfig.json, pyproject.toml / requirements.txt, go.mod,
# Cargo.toml) and are listed in evidence only (the schema has no field for them). Package manager: the
# packageManager field, else the first lockfile (package-lock.json, yarn.lock, pnpm-lock.yaml, bun.lock[b],
# uv.lock, poetry.lock, Pipfile.lock, Cargo.lock, go.sum); requirements.txt alone means pip. Runtime pin, first
# match wins: .nvmrc, .node-version, .tool-versions, package.json engines.node, .python-version, pyproject
# requires-python, go.mod `go`, Cargo.toml rust-version, tsconfig compilerOptions.target; every source found is
# listed in evidence. lockfile_committed: git tracks a lockfile (false when none exists or none is tracked;
# omitted outside a git repository).
# version_policy: pinned-runtime-and-lockfile (pin + committed lockfile; preset pinned-runtime-with-lockfile),
# latest-stable (neither; preset latest-stable), else lockfile-committed or runtime-pinned (no preset).
# Confidence: high = pin + committed lockfile, medium = exactly one of them, low = neither.
detect_language_tooling() {
  reset_result
  local langs="" manifests="" pins="" runtime="" pin v f committed="" lock_tracked="" lf ev
  local ts=0 has_manifest=0 policy="" preset="" conf="none" detected

  if json_valid package.json; then
    has_manifest=1
    manifests="package.json"
    langs="JavaScript"
    if json_valid tsconfig.json || [ -n "$(pkg_jq '(.dependencies // {}) + (.devDependencies // {}) | if has("typescript") then "y" else empty end')" ]; then
      ts=1
    fi
  elif [ -f "$ROOT/tsconfig.json" ]; then
    json_valid tsconfig.json && ts=1
  fi
  if [ "$ts" = 1 ]; then
    langs="${langs:+$langs/}TypeScript"
    [ -f "$ROOT/tsconfig.json" ] && manifests="${manifests:+$manifests, }tsconfig.json"
  fi
  if [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/requirements.txt" ]; then
    has_manifest=1
    f=$(files_matching pyproject.toml requirements.txt | join_csv)
    manifests="${manifests:+$manifests, }$f"
    langs="${langs:+$langs, }Python"
  fi
  if [ -f "$ROOT/go.mod" ]; then
    has_manifest=1
    manifests="${manifests:+$manifests, }go.mod"
    langs="${langs:+$langs, }Go"
  fi
  if [ -f "$ROOT/Cargo.toml" ]; then
    has_manifest=1
    manifests="${manifests:+$manifests, }Cargo.toml"
    langs="${langs:+$langs, }Rust"
  fi
  [ "$has_manifest" = 1 ] || return 0

  scan_lockfiles
  if [ -z "$PKG_MANAGER" ] && [ -f "$ROOT/requirements.txt" ]; then
    PKG_MANAGER="pip"
  fi

  # runtime pins, in precedence order
  for f in .nvmrc .node-version; do
    if [ -f "$ROOT/$f" ] && [ -r "$ROOT/$f" ]; then
      v=$(head -n1 "$ROOT/$f" | tr -d '[:space:]')
      [ -n "$v" ] && pins="${pins}node ${v#v}|$f"$'\n'
    fi
  done
  if [ -f "$ROOT/.tool-versions" ] && [ -r "$ROOT/.tool-versions" ]; then
    v=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/.tool-versions" | head -n1 | tr -s '[:space:]' ' ' | sed 's/ *$//')
    [ -n "$v" ] && pins="${pins}${v}|.tool-versions"$'\n'
  fi
  v=$(pkg_jq '.engines.node // empty | if type == "string" then . else empty end')
  [ -n "$v" ] && pins="${pins}node $v|package.json engines.node"$'\n'
  if [ -f "$ROOT/.python-version" ] && [ -r "$ROOT/.python-version" ]; then
    v=$(head -n1 "$ROOT/.python-version" | tr -d '[:space:]')
    [ -n "$v" ] && pins="${pins}python $v|.python-version"$'\n'
  fi
  if [ -f "$ROOT/pyproject.toml" ]; then
    v=$(sed -n 's/^requires-python[[:space:]]*=[[:space:]]*["'"'"']\(.*\)["'"'"'].*/\1/p' "$ROOT/pyproject.toml" 2>/dev/null | head -n1)
    [ -n "$v" ] && pins="${pins}python $v|pyproject.toml requires-python"$'\n'
  fi
  if [ -f "$ROOT/go.mod" ]; then
    v=$(sed -n 's/^go[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$ROOT/go.mod" 2>/dev/null | head -n1)
    [ -n "$v" ] && pins="${pins}go $v|go.mod"$'\n'
  fi
  if [ -f "$ROOT/Cargo.toml" ]; then
    v=$(sed -n 's/^rust-version[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$ROOT/Cargo.toml" 2>/dev/null | head -n1)
    [ -n "$v" ] && pins="${pins}rust $v|Cargo.toml rust-version"$'\n'
  fi
  if json_valid tsconfig.json; then
    v=$(jq -r '.compilerOptions.target // empty | if type == "string" then . else empty end' "$ROOT/tsconfig.json" 2>/dev/null)
    [ -n "$v" ] && pins="${pins}${v}|tsconfig.json compilerOptions.target"$'\n'
  fi
  runtime=$(printf '%s' "$pins" | head -n1 | sed 's/|.*//')
  pin=$(printf '%s' "$pins" | sed '/^$/d' | sed 's/^\(.*\)|\(.*\)$/\1 (\2)/' | join_csv)

  # lockfile tracking
  if [ -n "$LOCK_FILES" ]; then
    if [ "$IS_GIT" = 1 ]; then
      committed="false"
      for lf in $(printf '%s' "$LOCK_FILES" | tr -d ','); do
        if git_tracked "$lf"; then
          committed="true"
          lock_tracked="${lock_tracked:+$lock_tracked, }$lf"
        fi
      done
    fi
  else
    [ "$IS_GIT" = 1 ] && committed="false"
  fi

  if [ -n "$runtime" ] && [ "$committed" = "true" ]; then
    policy="pinned-runtime-and-lockfile"; preset="pinned-runtime-with-lockfile"; conf="high"
  elif [ -z "$runtime" ] && [ "$committed" != "true" ] && [ -z "$lock_tracked" ]; then
    policy="latest-stable"; preset="latest-stable"; conf="low"
  elif [ -n "$runtime" ]; then
    policy="runtime-pinned"; conf="medium"
  else
    policy="lockfile-committed"; conf="medium"
  fi

  detected=$(jq -nc --arg p "$policy" '{version_policy: $p}')
  [ -n "$runtime" ] && detected=$(printf '%s' "$detected" | jq -c --arg r "$runtime" '. + {runtime: $r}')
  [ -n "$PKG_MANAGER" ] && detected=$(printf '%s' "$detected" | jq -c --arg m "$PKG_MANAGER" '. + {package_manager: $m}')
  [ -n "$committed" ] && detected=$(printf '%s' "$detected" | jq -c --argjson c "$committed" '. + {lockfile_committed: $c}')
  # latest-stable means no lockfile is committed; keep the preset only when that holds
  [ "$policy" = "latest-stable" ] && [ "$committed" = "true" ] && preset=""

  ev="languages: $langs (manifests: $manifests)"
  if [ -n "$LOCK_FILES" ]; then
    ev="$ev; lockfile: $LOCK_FILES"
    if [ "$IS_GIT" = 1 ]; then
      if [ -n "$lock_tracked" ]; then ev="$ev (tracked by git: $lock_tracked)"; else ev="$ev (not tracked by git)"; fi
    fi
  else
    ev="$ev; no lockfile found"
  fi
  [ -n "$PKG_MANAGER" ] && ev="$ev; package manager: $PKG_MANAGER"
  if [ -n "$pin" ]; then ev="$ev; runtime pin: $pin"; else ev="$ev; no runtime pin found"; fi

  set_detected language-tooling "$preset" "$detected"
  D_EVIDENCE="$ev"
  D_CONF="$conf"
}

# --- detector: testing ------------------------------------------------------------------------------------
# Signals: a top-level test directory (tests, test, __tests__, spec), <configs>/test-config.json `tools[]` entries
# with a real tool name (not "-"; <configs> resolved via workflow.json), a package.json `test` script (the
# `npm init` placeholder "no test specified" is ignored), and co-located test files (*.test.*, *.spec.*, *_test.*,
# test_*, *.bats outside a test directory; bounded find, depth 5).
# Confidence: high = a test directory and (a tool entry or a test script), or a tool entry and a test script;
# medium = a test directory or a tool entry alone; low = a test script or co-located test files alone.
# The schema's `expectation` cannot be measured from the tree, so detected.expectation is the descriptive
# value "tests-present" and preset_match stays null.
TEST_DIR_NAMES="tests test __tests__ spec"
detect_testing() {
  reset_result
  local d tdirs="" first_dir="" tool_ev="" body cmd="" colocated=0 cfg ev="" conf="none" run="npm run" detected
  local has_dir=0 has_tools=0 has_script=0

  for d in $TEST_DIR_NAMES; do
    if [ -d "$ROOT/$d" ]; then
      tdirs="${tdirs:+$tdirs, }$d/"
      [ -n "$first_dir" ] || first_dir="$d"
    fi
  done
  [ -n "$first_dir" ] && has_dir=1

  resolve_dir configs project/configs
  cfg="$RESOLVED_DIR/test-config.json"
  if json_valid "$cfg"; then
    tool_ev=$(jq -r '[.tools[]? | select((.tool_name // "-") != "-") | "\(.type // "?"): \(.tool_name)"] | unique | join(", ")' "$cfg" 2>/dev/null)
    [ -n "$tool_ev" ] && has_tools=1
  fi

  scan_lockfiles
  case "$PKG_MANAGER" in
    yarn|pnpm|bun) run="$PKG_MANAGER run" ;;
  esac
  body=$(pkg_jq '.scripts.test // empty | if type == "string" then . else empty end' | tr '\n\r' '  ' | sed -e 's/^ *//' -e 's/ *$//')
  case "$body" in *"no test specified"*) body="" ;; esac
  if [ -n "$body" ]; then
    has_script=1
    cmd="$run test"
  fi

  colocated=$(find "$ROOT" -maxdepth 5 \( -name node_modules -o -name .git -o -name .claude -o -name .agents -o -name dist -o -name build \) -prune -o \
    -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.*' -o -name 'test_*' -o -name '*.bats' \) -print 2>/dev/null | head -n 1000 | grep -c .)

  if [ "$has_dir" = 0 ] && [ "$has_tools" = 0 ] && [ "$has_script" = 0 ] && [ "$colocated" -eq 0 ]; then
    return 0
  fi
  if { [ "$has_dir" = 1 ] && { [ "$has_tools" = 1 ] || [ "$has_script" = 1 ]; }; } || { [ "$has_tools" = 1 ] && [ "$has_script" = 1 ]; }; then
    conf="high"
  elif [ "$has_dir" = 1 ] || [ "$has_tools" = 1 ]; then
    conf="medium"
  else
    conf="low"
  fi

  [ "$has_dir" = 1 ] && ev="test directories: $tdirs"
  [ "$has_tools" = 1 ] && ev="${ev:+$ev; }test-config.json tools: $tool_ev"
  [ "$has_script" = 1 ] && ev="${ev:+$ev; }package.json scripts.test = \"$body\""
  ev="${ev:+$ev; }$colocated test files found by name pattern"

  detected='{"expectation":"tests-present"}'
  [ -n "$first_dir" ] && detected=$(printf '%s' "$detected" | jq -c --arg d "$first_dir" '. + {test_dir: $d}')
  [ -n "$cmd" ] && detected=$(printf '%s' "$detected" | jq -c --arg c "$cmd" '. + {test_command: $c}')
  set_detected testing "" "$detected"
  D_EVIDENCE="$ev"
  D_CONF="$conf"
}

# --- detector: file-layout ----------------------------------------------------------------------------------
# Top-level directories, ignoring hidden ones, node_modules, dist, build, out, target, coverage, vendor, venv,
# __pycache__ and the Jenga working tree (project/ or .project/). First rule that applies wins:
#   monorepo         packages/ or apps/ (or a package.json `workspaces` key): layout monorepo-packages
#                    (high with workspaces, else medium; no preset)
#   src + tests      src/ and a top-level test directory: preset src-and-tests (high)
#   co-located tests src/ holding test files and no top-level test directory: preset co-located-tests (medium)
#   src only         src/ alone: layout src-directory (low; no preset)
#   flat             no src/ but source files at the top level: preset flat-modules (medium from 3 files, else low)
# Anything else (for example one directory per domain) is not detected.
detect_file_layout() {
  reset_result
  local tree e n tops="" ntops=0 tdir="" ws="" srcfiles=0 colocated=0 ev="" layout="" conf="" preset="" src_dir="" f x
  tree=$(bash "$RESOLVE_ROOT" tree 2>/dev/null)
  [ -n "$tree" ] || tree=project

  for e in "$ROOT"/*/; do
    [ -d "$e" ] || continue
    n=$(basename "$e")
    case "$n" in
      node_modules|dist|build|out|target|coverage|vendor|venv|__pycache__|"$tree") continue ;;
    esac
    tops="${tops:+$tops, }$n/"
    ntops=$((ntops + 1))
    case " $TEST_DIR_NAMES " in *" $n "*) [ -n "$tdir" ] || tdir="$n" ;; esac
  done
  [ "$ntops" -gt 0 ] || return 0

  for f in "$ROOT"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.py|*.go|*.rs|*.rb|*.java|*.kt|*.swift|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.php|*.sh|*.bash|*.vue|*.svelte)
        srcfiles=$((srcfiles + 1)) ;;
    esac
  done
  [ -n "$(pkg_jq 'if has("workspaces") then "y" else empty end')" ] && ws=1

  if [ -d "$ROOT/packages" ] || [ -d "$ROOT/apps" ]; then
    for x in packages apps; do
      if [ -d "$ROOT/$x" ] && [ -n "$(find "$ROOT/$x" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)" ]; then
        src_dir="$x"
        break
      fi
    done
  fi
  if [ -n "$src_dir" ] || [ -n "$ws" ]; then
    [ -n "$src_dir" ] || src_dir="packages"
    layout="monorepo-packages"
    if [ -n "$ws" ] && [ -d "$ROOT/$src_dir" ]; then conf="high"; else conf="medium"; fi
    ev="$src_dir/ holds sub-projects${ws:+ and package.json declares workspaces}"
  elif [ -d "$ROOT/src" ]; then
    src_dir="src"
    colocated=$(find "$ROOT/src" -maxdepth 6 -type f \( -name '*.test.*' -o -name '*.spec.*' -o -name '*_test.*' -o -name 'test_*' \) 2>/dev/null | head -n 1000 | grep -c .)
    if [ -n "$tdir" ]; then
      layout="src-and-tests"; preset="src-and-tests"; conf="high"
      ev="src/ with a top-level $tdir/ directory"
    elif [ "$colocated" -gt 0 ]; then
      layout="co-located-tests"; preset="co-located-tests"; conf="medium"
      ev="src/ holds $colocated test files next to its modules and no top-level test directory exists"
    else
      layout="src-directory"; conf="low"
      ev="src/ exists with no test directory or co-located test files"
    fi
  elif [ "$srcfiles" -gt 0 ]; then
    layout="flat-top-level-modules"; preset="flat-modules"
    if [ "$srcfiles" -ge 3 ]; then conf="medium"; else conf="low"; fi
    ev="$srcfiles source files at the top level and no src/ directory"
  else
    D_EVIDENCE="top-level directories ($ntops): $tops; no src/, packages/ or top-level modules to classify"
    return 0
  fi

  D_EVIDENCE="top-level directories ($ntops): $tops; $ev"
  D_CONF="$conf"
  local detected
  detected=$(jq -nc --arg l "$layout" '{layout: $l}')
  [ -n "$src_dir" ] && detected=$(printf '%s' "$detected" | jq -c --arg d "$src_dir" '. + {source_dir: $d}')
  [ -n "$tdir" ] && detected=$(printf '%s' "$detected" | jq -c --arg d "$tdir" '. + {test_dir: $d}')
  set_detected file-layout "$preset" "$detected"
}

# --- detector: documentation-placement ------------------------------------------------------------------------
# Compares docs/ with the internal documentation directory resolved from workflow.json paths.documentation
# (default project/documentation) by counting the non-hidden files in each.
#   both hold files, different directories  published-docs-in-docs-internal-elsewhere, high
#   docs/ holds files, the other is empty/absent (or is docs/ itself)  everything-in-docs, medium
#   only the internal directory holds files  internal-docs-only (no preset), medium
#   neither, but a README exists  readme-only, low        nothing  not detected
count_files() {
  [ -d "$1" ] || { printf '0'; return; }
  find "$1" -type f ! -name '.*' 2>/dev/null | head -n 100000 | grep -c .
}
detect_documentation_placement() {
  reset_result
  local docs_n=0 int_abs int_rel int_n=0 same=0 policy="" preset="" conf="" ev="" detected readme=""
  resolve_dir documentation project/documentation
  int_abs="${RESOLVED_DIR%/}"
  case "$int_abs" in
    "$ROOT"/*) int_rel="${int_abs#"$ROOT"/}" ;;
    *) int_rel="$int_abs" ;;
  esac
  docs_n=$(count_files "$ROOT/docs")
  [ "$int_abs" = "$ROOT/docs" ] && same=1
  int_n=$(count_files "$int_abs")
  ls "$ROOT"/README* >/dev/null 2>&1 && readme=1

  ev="docs/ holds $docs_n files; $int_rel/ holds $int_n files (resolved from workflow.json paths.documentation)"
  if [ "$docs_n" -gt 0 ] && [ "$int_n" -gt 0 ] && [ "$same" = 0 ]; then
    policy="published-docs-in-docs-internal-elsewhere"; preset="published-docs-in-docs"; conf="high"
    detected=$(jq -nc --arg p "$policy" --arg i "$int_rel" '{policy: $p, public_docs_dir: "docs", internal_docs_dir: $i}')
  elif [ "$docs_n" -gt 0 ]; then
    policy="everything-in-docs"; preset="everything-in-docs"; conf="medium"
    detected=$(jq -nc --arg p "$policy" '{policy: $p, public_docs_dir: "docs", internal_docs_dir: "docs"}')
  elif [ "$int_n" -gt 0 ]; then
    policy="internal-docs-only"; conf="medium"
    detected=$(jq -nc --arg p "$policy" --arg i "$int_rel" '{policy: $p, internal_docs_dir: $i}')
  elif [ -n "$readme" ]; then
    policy="readme-only"; preset="readme-only"; conf="low"
    detected=$(jq -nc --arg p "$policy" '{policy: $p}')
    ev="a README exists and neither docs/ nor $int_rel/ holds any file"
  else
    return 0
  fi
  set_detected documentation-placement "$preset" "$detected"
  D_EVIDENCE="$ev"
  D_CONF="$conf"
}

# --- detector: naming ---------------------------------------------------------------------------------------
# Sample: the first NAMING_SAMPLE (200) tracked source files from `git ls-files` (hidden directories, node_modules,
# vendor, dist, build and the Jenga working tree skipped). File case: the base name before the first dot is
# classified kebab-case, snake_case, camelCase or PascalCase; single lowercase words (index, main) are ambiguous
# and not counted. A case wins with more than 50% of >= 3 classified files. identifier_case is measured from
# function / variable definitions in the same files (snake_case vs camelCase, needs >= 5 definitions and a
# majority), otherwise inferred from the file case and flagged as inferred; type_case PascalCase is added when >= 3
# class/struct/interface/type/enum definitions use it. Confidence is medium at most: medium when the winning file
# case holds >= 80% of >= 10 classified files and identifier_case was measured, else low.
NAMING_SAMPLE=200
detect_naming() {
  reset_result
  [ "$IS_GIT" = 1 ] && [ "$HAS_COMMITS" = 1 ] || return 0
  local tree files nfiles kebab=0 snake=0 camel=0 pascal=0 base b total top topn=0 file_case="" ident="" ident_ev="" conf="low"
  local snake_def=0 camel_def=0 type_n=0 ev="" detected preset="" t tally
  tree=$(bash "$RESOLVE_ROOT" tree 2>/dev/null)
  [ -n "$tree" ] || tree=project
  files=$(git -C "$ROOT" ls-files 2>/dev/null \
    | grep -E '\.(js|jsx|ts|tsx|mjs|cjs|py|go|rs|rb|java|kt|swift|c|cc|cpp|h|hpp|cs|php|sh|bash|vue|svelte)$' \
    | grep -Ev "(^|/)(\.[^/]+|node_modules|vendor|dist|build|$tree)/" | head -n "$NAMING_SAMPLE")
  [ -n "$files" ] || return 0
  nfiles=$(printf '%s\n' "$files" | grep -c .)

  while IFS= read -r f; do
    base="${f##*/}"
    b="${base%%.*}"
    [ -n "$b" ] || continue
    if [[ $b =~ ^[a-z0-9]+(-[a-z0-9]+)+$ ]]; then kebab=$((kebab + 1))
    elif [[ $b =~ ^[a-z0-9]+(_[a-z0-9]+)+$ ]]; then snake=$((snake + 1))
    elif [[ $b =~ ^[a-z][a-z0-9]*([A-Z][a-z0-9]*)+$ ]]; then camel=$((camel + 1))
    elif [[ $b =~ ^([A-Z][a-z0-9]+)+$ ]]; then pascal=$((pascal + 1))
    fi
  done <<< "$files"
  total=$((kebab + snake + camel + pascal))

  for t in "kebab-case:$kebab" "snake_case:$snake" "camelCase:$camel" "PascalCase:$pascal"; do
    if [ "${t##*:}" -gt "$topn" ]; then
      topn="${t##*:}"
      top="${t%%:*}"
    fi
  done
  tally="$kebab kebab-case, $snake snake_case, $camel camelCase, $pascal PascalCase"
  if [ "$total" -lt 3 ] || [ $((topn * 2)) -le "$total" ]; then
    D_EVIDENCE="$nfiles source files sampled; file-name casing: $tally ($total classified); no majority"
    return 0
  fi
  file_case="$top"

  # identifier casing measured from definitions in the sampled files (read-only grep, run from ROOT)
  snake_def=$(printf '%s\n' "$files" | tr '\n' '\0' | (cd "$ROOT" && xargs -0 grep -EhoI \
    -e '(def|fn|func|function)[[:space:]]+[a-z][a-z0-9]*(_[a-z0-9]+)+[[:space:]]*\(' \
    -e '^[[:space:]]*(function[[:space:]]+)?[a-z][a-z0-9]*(_[a-z0-9]+)+[[:space:]]*\(\)' \
    -e '(const|let|var)[[:space:]]+[a-z][a-z0-9]*(_[a-z0-9]+)+[[:space:]]*[=:]' 2>/dev/null) | grep -c .)
  camel_def=$(printf '%s\n' "$files" | tr '\n' '\0' | (cd "$ROOT" && xargs -0 grep -EhoI \
    -e '(def|fn|func|function)[[:space:]]+[a-z][a-z0-9]*([A-Z][a-z0-9]*)+[[:space:]]*\(' \
    -e '(const|let|var)[[:space:]]+[a-z][a-z0-9]*([A-Z][a-z0-9]*)+[[:space:]]*[=:]' 2>/dev/null) | grep -c .)
  type_n=$(printf '%s\n' "$files" | tr '\n' '\0' | (cd "$ROOT" && xargs -0 grep -EhoI \
    -e '(class|struct|interface|enum|type)[[:space:]]+[A-Z][A-Za-z0-9]*' 2>/dev/null) | grep -c .)

  if [ $((snake_def + camel_def)) -ge 5 ] && [ $((snake_def * 2)) -ne $((snake_def + camel_def)) ]; then
    if [ "$snake_def" -gt "$camel_def" ]; then ident="snake_case"; else ident="camelCase"; fi
    ident_ev="identifier definitions: $snake_def snake_case, $camel_def camelCase (measured)"
  else
    case "$file_case" in
      snake_case) ident="snake_case" ;;
      *) ident="camelCase" ;;
    esac
    ident_ev="identifier_case inferred from the file case ($snake_def snake_case and $camel_def camelCase definitions found, too few to measure)"
  fi

  if [ "$total" -ge 10 ] && [ $((topn * 10)) -ge $((8 * total)) ] && [[ $ident_ev != *inferred* ]]; then
    conf="medium"
  fi

  detected=$(jq -nc --arg i "$ident" --arg f "$file_case" '{identifier_case: $i, file_case: $f}')
  if [ "$type_n" -ge 3 ]; then
    detected=$(printf '%s' "$detected" | jq -c '. + {type_case: "PascalCase"}')
    ident_ev="$ident_ev; $type_n PascalCase type definitions"
  fi
  if [ "$file_case" = "kebab-case" ] && [ "$ident" = "camelCase" ]; then
    preset="kebab-files-camel-identifiers"
  elif [ "$file_case" = "snake_case" ] && [ "$ident" = "snake_case" ]; then
    preset="snake-case-throughout"
  elif [ "$ident" = "camelCase" ] && [ "$type_n" -ge 3 ]; then
    preset="pascal-types-camel-values"
  fi
  set_detected naming "$preset" "$detected"
  D_EVIDENCE="$nfiles source files sampled; file-name casing: $tally ($total classified, $top wins); $ident_ev"
  D_CONF="$conf"
}

# --- detector: code-comments --------------------------------------------------------------------------------
# No reliable detector exists for comment policy: always null, flagged preset_only so the wizard offers presets.
detect_code_comments() {
  reset_result
  D_PREONLY="true"
}

# --- main ---------------------------------------------------------------------------------------------------
run_detector() {
  reset_result
  case "$1" in
    commit-format) detect_commit_format ;;
    branching) detect_branching ;;
    formatting-linting) detect_formatting_linting ;;
    language-tooling) detect_language_tooling ;;
    testing) detect_testing ;;
    file-layout) detect_file_layout ;;
    documentation-placement) detect_documentation_placement ;;
    naming) detect_naming ;;
    code-comments) detect_code_comments ;;
    *) ;;  # a category id added to the schema later: null / none / preset_only false until a detector exists
  esac
}

while IFS= read -r cid; do
  [ -n "$cid" ] || continue
  run_detector "$cid"
  emit_category "$cid"
done <<EOF
$CATEGORY_IDS
EOF

WARN_JSON=$(printf '%s' "$WARNINGS" | jq -R -s 'split("\n") | map(select(length > 0))')
printf '%s' "$ENTRIES" | jq -s --argjson w "$WARN_JSON" \
  '{detect_version: 1, categories: (map({(.id): .entry}) | add // {}), warnings: $w}'
exit 0

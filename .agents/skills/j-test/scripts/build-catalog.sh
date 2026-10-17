#!/usr/bin/env bash
################################################################################
# build-catalog.sh — deduplicated runnable catalog for j.test (E72_S02_T02)
#
# Turns discover-tests.sh's JSON into the catalog `j.test` presents and runs, and
# renders that catalog as the numbered list. E72_S02_T03 (selection parsing),
# E72_S02_T04 (execution) and E72_S02_T05 (SKILL.md) read the contract below, as
# does the scoped commit gate (E72_S04): a change here is a change to them.
#
# Usage:
#   build-catalog.sh [--root <dir>] [--discovery-file <file>]   print the catalog JSON
#   build-catalog.sh --render <catalog.json>                    print the numbered list
#   build-catalog.sh --help
#
#   --root <dir>             project root. Forwarded to discover-tests.sh, and the
#                            place package.json is read from for the npm alias.
#                            Defaults to the root scripts/resolve-root.sh resolves.
#   --discovery-file <file>  read discovery JSON from <file> instead of running
#                            discover-tests.sh (a real discovery run walks the
#                            tree, 25-35 s on this repo, so callers run it once
#                            and reuse the catalog).
#   --render <catalog.json>  render a saved catalog; never runs discovery. Cannot
#                            be combined with --root or --discovery-file.
#
# discover-tests.sh is located next to this script via BASH_SOURCE, so it works
# from a checkout and from node_modules/@jenga-ai/agent/.
#
# ---------------------------------------------------------------------------
# CATALOG JSON CONTRACT (normative)
#
#   {"runnable":[{"n":1,"id":"npm:test","name":"npm test","type":"unit",
#                 "ecosystem":"npm","command":"npm test",
#                 "also":[{"id":"bats:tests","name":"bats tests","type":"unit"}]}],
#    "not_runnable":[{"id":"config:semgrep:sast","name":"semgrep (sast)",
#                     "type":"sast","ecosystem":"config",
#                     "reason":"no command declared"}],
#    "warnings":["detected tool not listed in test-config.json: npm"]}
#
#   One compact single-line JSON object, key order fixed as above.
#   runnable      array. Only runnable entries carry `n`, contiguous 1..N, in the
#                 order of the surviving entries' `id` (byte order). Each entry is
#                 the survivor's own id/name/type/ecosystem/command, so `command`
#                 is exactly what to execute.
#   also          on every runnable entry; array, never absent, [] when nothing was
#                 folded. Lists every suite folded into the entry (id, name, type),
#                 sorted by `id`.
#   not_runnable  suites whose command is empty or absent (config-only suites,
#                 ecosystem `config`), sorted by id, each with the fixed reason
#                 "no command declared". Never numbered, never executed, never
#                 counted as pass or fail.
#   warnings      discovery's warnings, passed through (sorted, array, never null).
#   Unknown keys on discovery's suites (for example an additive `paths`) are
#   tolerated and not carried into the catalog. Absent name/type/ecosystem/
#   command fall back to the id / "unknown" / "" / "" (an absent command is not
#   runnable). Same discovery input gives byte-identical output.
#
# ---------------------------------------------------------------------------
# DEDUPLICATION (before numbering)
#   Suites that would run the same thing are folded into one entry.
#   1. Key = the exact `command` string. This repo's discovery reports both
#      `bats:tests` and `config:bats:integration` as `bats tests/*.bats`.
#   2. npm alias. `npm test` and `npm run <key>` are aliases for the body of that
#      script in <root>/package.json (read with jq, never executed). For an npm
#      suite (ecosystem `npm`, id `npm:<key>`) the key is that script body when
#      it is a non-empty string, else its command. Here scripts.test is
#      `bats tests/*.bats`, so `npm:test` shares a key with `bats:tests`; without
#      this a run-all would run the hour-long bats suite twice. A missing,
#      unreadable or unparseable package.json just means no alias (no error).
#   3. SURVIVOR of a group: the first `npm` entry (the project's own declared entry
#      point), else the first non-`config` entry, else the first `config` entry;
#      "first" is `id` order. Everyone else goes into the survivor's `also`. A
#      group of one is not folded. The npm entry wins because its command is how
#      the project itself says to run those tests; a config-only entry carries
#      no information the others lack.
#   4. Empty-command suites never join a group; they go straight to not_runnable.
#   Scripts that call other scripts (`npm run other`) are not resolved further.
#
# ---------------------------------------------------------------------------
# NUMBERED LIST (--render)
#   Blocks are separated by one blank line; the `Not runnable` and `Notes` blocks
#   are omitted when empty:
#
#     Choose which tests to run:
#     1. npm test (unit) [also covers: bats tests (unit), bats (integration)]
#     2. shellcheck (sast)
#
#     Not runnable (listed only, cannot be selected):
#     - semgrep (sast): no command declared
#
#     Notes:
#     - detected tool not listed in test-config.json: npm
#
#     Enter selection (comma-separated, or 'all' for all, or blank for 1 through 2):
#
#   `name (type)` is the label of every entry, except that when `name` already
#   ends in ` (<type>)` it is printed as is. discover-tests.sh names its
#   config-only suites that way (`semgrep (sast)`), and the doubled
#   `semgrep (sast) (sast)` would be noise.
#
#   With no runnable suite the first block is `No runnable test suites found.`,
#   there is NO prompt line, and the exit code is 0: an empty catalog is a valid
#   answer. `N` in the prompt is the runnable count.
#
# ---------------------------------------------------------------------------
# EXIT CODES
#   0  success, including the zero-suites case
#   1  internal failure: jq missing, discover-tests.sh failed, discovery or
#      catalog JSON unreadable or invalid (cause on stderr)
#   2  usage error (unknown flag, missing argument, bad --root, conflicting flags)
#
# Writes nothing to disk. macOS bash 3.2 compatible; safe under `set -euo pipefail`.
################################################################################

set -euo pipefail

SCRIPT_NAME="build-catalog.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# skills/j-test/scripts -> the checkout root, or node_modules/@jenga-ai/agent
# when installed as a dependency.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# Locale must not influence sort order or tool output.
export LC_ALL=C

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }
fail() { err "$1"; exit 1; }

usage() {
  cat <<'EOF'
Usage: build-catalog.sh [--root <dir>] [--discovery-file <file>]
       build-catalog.sh --render <catalog.json>
       build-catalog.sh --help

Print the deduplicated catalog of runnable test suites as JSON, or render a
saved catalog as the numbered list j.test presents.

  --root <dir>             project root (forwarded to discover-tests.sh)
  --discovery-file <file>  read discovery JSON from <file>; do not run discovery
  --render <catalog.json>  print the numbered list for a saved catalog
  --help                   show this help and exit 0

Output: {"runnable":[{"n","id","name","type","ecosystem","command","also"}...],
         "not_runnable":[{"id","name","type","ecosystem","reason"}...],"warnings":[]}
Exit:   0 ok (zero suites is valid), 1 internal failure, 2 usage error
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

# Catalog program. Input: discovery JSON. $scripts: package.json `scripts` strings.
read -r -d '' BUILD_PROGRAM <<'EOF' || true
def str(d): if type == "string" then . else d end;
def norm: {
  id: .id,
  name: ((.name | str("")) as $n | if $n != "" then $n else .id end),
  type: ((.type | str("")) as $t | if $t != "" then $t else "unknown" end),
  ecosystem: (.ecosystem | str("")),
  command: (.command | str(""))
};
(.suites | map(norm) | sort_by(.id)) as $all
| ($all | map(select(.command == ""))) as $nr
| ($all | map(select(.command != "")
    | . + {key: (
        if .ecosystem == "npm" and (.id | startswith("npm:"))
        then (($scripts[.id | ltrimstr("npm:")] // "") as $b
              | if ($b | type) == "string" and $b != "" then $b else .command end)
        else .command end)})) as $run
| ($run | group_by(.key) | map(
    (map(select(.ecosystem == "npm"))[0]
      // map(select(.ecosystem != "config"))[0]
      // .[0]) as $sv
    | {sv: $sv,
       also: (map(select(.id != $sv.id)) | map({id, name, type}) | sort_by(.id))}
  ) | sort_by(.sv.id) | to_entries
  | map({n: (.key + 1)} + (.value.sv | {id, name, type, ecosystem, command})
        + {also: .value.also})) as $runnable
| {runnable: $runnable,
   not_runnable: ($nr | map({id, name, type, ecosystem, reason: "no command declared"})),
   warnings: ((if (.warnings | type) == "array" then .warnings else [] end)
              | map(select(type == "string")) | sort)}
EOF

# Render program. Input: catalog JSON. Emits the whole list as one string.
read -r -d '' RENDER_PROGRAM <<'EOF' || true
def nametype: " (\(.type))" as $suffix
  | if (.name | endswith($suffix)) then .name else .name + $suffix end;
def alsotxt: if ((.also // []) | length) > 0
             then " [also covers: " + (.also | map(nametype) | join(", ")) + "]" else "" end;
(.runnable // []) as $r
| (.not_runnable // []) as $nr
| (if (.warnings | type) == "array" then .warnings else [] end) as $w
| [ (if ($r | length) == 0
     then "No runnable test suites found."
     else "Choose which tests to run:\n"
          + ($r | map("\(.n). " + nametype + alsotxt) | join("\n")) end),
    (if ($nr | length) > 0
     then "Not runnable (listed only, cannot be selected):\n"
          + ($nr | map("- " + nametype + ": " + (.reason // "no command declared")) | join("\n"))
     else empty end),
    (if ($w | length) > 0 then "Notes:\n" + ($w | map("- " + .) | join("\n")) else empty end),
    (if ($r | length) > 0
     then "Enter selection (comma-separated, or 'all' for all, or blank for 1 through \($r | length)):"
     else empty end)
  ] | join("\n\n")
EOF

# ---- helpers ----------------------------------------------------------------

# package.json `scripts` as a JSON object of string values, or {} on any problem.
read_scripts() {
  local root="$1" manifest
  manifest="$root/package.json"
  if [ -z "$root" ] || [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
    printf '{}'
    return 0
  fi
  jq -c 'if type == "object" and (.scripts | type) == "object"
         then .scripts | with_entries(select(.value | type == "string")) else {} end' \
    "$manifest" 2>/dev/null || printf '{}'
}

# The directory package.json is read from: --root, else the resolver's root, else
# empty (no alias; never an error).
alias_root() {
  local resolver
  if [ -n "$ROOT_ARG" ]; then
    (cd -- "$ROOT_ARG" && pwd)
    return 0
  fi
  resolver="$(resolve_helper scripts/resolve-root.sh)" || return 0
  bash "$resolver" root 2>/dev/null || true
}

do_render() {
  local file="$1" catalog
  [ -f "$file" ] && [ -r "$file" ] || fail "catalog file is not a readable file: $file"
  catalog="$(cat -- "$file")" || fail "could not read catalog file: $file"
  if ! printf '%s' "$catalog" | jq -e 'type == "object" and (.runnable | type) == "array"
        and (.runnable | all(type == "object"))' >/dev/null 2>&1; then
    fail "catalog file is not valid catalog JSON (an object with a runnable array): $file"
  fi
  printf '%s' "$catalog" | jq -r "$RENDER_PROGRAM" \
    || fail "could not render the catalog: $file"
}

do_build() {
  local discovery scripts_json="{}" root
  if [ -n "$DISCOVERY_FILE" ]; then
    [ -f "$DISCOVERY_FILE" ] && [ -r "$DISCOVERY_FILE" ] \
      || fail "discovery file is not a readable file: $DISCOVERY_FILE"
    discovery="$(cat -- "$DISCOVERY_FILE")" || fail "could not read discovery file: $DISCOVERY_FILE"
  else
    local discover="$SCRIPT_DIR/discover-tests.sh" rc=0
    [ -f "$discover" ] || fail "could not locate discover-tests.sh next to $SCRIPT_NAME"
    if [ -n "$ROOT_ARG" ]; then
      discovery="$(bash "$discover" --root "$ROOT_ARG")" || rc=$?
    else
      discovery="$(bash "$discover")" || rc=$?
    fi
    [ "$rc" -eq 0 ] || fail "discover-tests.sh failed (exit $rc)"
  fi

  if ! printf '%s' "$discovery" | jq -e 'type == "object" and (.suites | type) == "array"
        and (.suites | all(type == "object" and (.id | type) == "string"))' >/dev/null 2>&1; then
    fail "discovery output is not valid discovery JSON (an object with a suites array of objects with a string id)"
  fi

  if printf '%s' "$discovery" | jq -e '.suites | any(.ecosystem == "npm")' >/dev/null 2>&1; then
    root="$(alias_root)"
    scripts_json="$(read_scripts "$root")"
  fi

  printf '%s' "$discovery" | jq -c --argjson scripts "$scripts_json" "$BUILD_PROGRAM" \
    || fail "could not build the catalog from discovery output"
}

# ---- main -------------------------------------------------------------------

ROOT_ARG=""
DISCOVERY_FILE=""
RENDER_FILE=""

needs_value() {
  if [ "$2" -lt 2 ] || [ -z "$3" ]; then
    err "$1 requires an argument"
    usage >&2
    exit 2
  fi
}

main() {
  local have_root=0 have_disc=0 have_render=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        needs_value --root "$#" "${2:-}"
        ROOT_ARG="$2"; have_root=1; shift 2 ;;
      --discovery-file)
        needs_value --discovery-file "$#" "${2:-}"
        DISCOVERY_FILE="$2"; have_disc=1; shift 2 ;;
      --render)
        needs_value --render "$#" "${2:-}"
        RENDER_FILE="$2"; have_render=1; shift 2 ;;
      -h|--help|help) usage; exit 0 ;;
      *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
  done

  if [ "$have_render" -eq 1 ] && [ $((have_root + have_disc)) -gt 0 ]; then
    err "--render cannot be combined with --root or --discovery-file"
    usage >&2
    exit 2
  fi
  if [ "$have_root" -eq 1 ] && [ ! -d "$ROOT_ARG" ]; then
    err "--root is not a directory: $ROOT_ARG"
    exit 2
  fi

  command -v jq >/dev/null 2>&1 || fail "jq is required but was not found on PATH"

  if [ "$have_render" -eq 1 ]; then
    do_render "$RENDER_FILE"
  else
    do_build
  fi
}

main "$@"

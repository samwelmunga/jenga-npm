#!/usr/bin/env bash
# Read and write entries in a preferred-tools registry layer (E66_S03_T02).
#
# The deterministic half of the j.tools wizard (skills/j-tools/SKILL.md): every write
# resolves the layer file, applies one change with jq while keeping everything else in the
# file, validates the result with scripts/validate-tools-registry.sh, and only then replaces
# the file with an atomic rename. The file format and layering rules are documented in
# project/documentation/preferred-tools-registry.md.
#
# Usage:
#   tools-entry.sh add       --layer user|project --name N --category C --enforcement required|recommended
#                            --rationale TEXT [--version V] [--alternative "NAME::WHY_NOT"]...
#                            [--descriptor ID] [--install-text TEXT] [--add-category]
#   tools-entry.sh edit      --layer L --name N [--category C] [--enforcement E] [--rationale TEXT]
#                            [--version V] [--alternative "NAME::WHY_NOT"]... [--clear-alternatives]
#                            [--descriptor ID] [--clear-descriptor] [--install-text TEXT]
#                            [--clear-install-text] [--add-category]
#   tools-entry.sh remove    --layer L --name N
#   tools-entry.sh suppress  --layer L --name N     hide a lower-layer entry of that name
#   tools-entry.sh unsuppress --layer L --name N
#   tools-entry.sh descriptors [--format lines|json]    real j-connect descriptor ids
#   tools-entry.sh show      --layer shipped|user|project [--name N]
#   tools-entry.sh path      --layer shipped|user|project
#   tools-entry.sh check     <category|enforcement|version|descriptor|name> <value> [--layer L]
#
# Option values are passed as a separate argument (`--name foo`, not `--name=foo`).
#
# add: version defaults to "*" and alternatives to []. Every other field is checked by the
#      validator, so a missing field is reported as the validator's own message. A name already
#      present in the layer is refused (use edit). --add-category appends the category to the
#      layer's `categories` when it is not in the base vocabulary.
# edit: changes only the fields that were given. Supplying --alternative replaces the whole
#      alternatives list; the --clear-* flags remove the named part of the install hint. The
#      entry is not renamed, and is changed in place (an entry from another layer is not
#      copied; use add for that).
# remove / unsuppress: refuse when the name is absent. suppress is idempotent: an already
#      suppressed name is a successful no-op ("changed": false).
# check: validates one input with the real validator (via a probe registry) so no rule is
#      duplicated here. Prints {"valid": true} or {"valid": false, "reason": "..."} and exits 0
#      for both. check category also reports "extendable" (the name would be accepted as a new
#      category), and check name reports "exists" (already present in --layer).
#
# Layer files are located exactly as scripts/resolve-tools.sh does:
#   user     ${JENGA_USER_TOOLS_FILE:-$HOME/.jenga/tools.json}
#   project  <configs path from scripts/resolve-root.sh get configs>/preferred-tools.json
#   shipped  <package root>/skills/j-tools/assets/shipped-tools.json (read only: show and path)
# A missing user or project file is created, as a minimal valid registry, by the first write.
# The descriptor directory honours JENGA_DESCRIPTORS_DIR like the validator does.
#
# Write guarantees: untouched entries and unknown keys survive (same parsed content); the
# candidate is validated before anything is replaced; the replacement is a temp file in the
# target directory renamed over the target; an invalid result leaves the original file (or its
# absence) untouched and nothing new is created.
#
# Output: one JSON object on stdout for add/edit/remove/suppress/unsuppress, e.g.
#   {"ok": true, "action": "add", "layer": "user", "path": "...", "name": "...", "changed": true}
#
# Exit codes:
#   0  success (see above; check and descriptors and show and path print their result)
#   1  precondition failed (name already present for add, absent for edit/remove/unsuppress/show)
#      or an internal error
#   2  usage error
#   3  jq is not installed
#   4  the existing layer file is invalid or not an object, or the change would make it
#      invalid; the validator's messages are on stderr and the file is untouched
#   5  the project configs path could not be resolved (resolve-root.sh failed)
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).

set -u

SELF="tools-entry.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATOR="$PACKAGE_ROOT/scripts/validate-tools-registry.sh"
RESOLVE_ROOT="$PACKAGE_ROOT/scripts/resolve-root.sh"
SHIPPED_FILE="$PACKAGE_ROOT/skills/j-tools/assets/shipped-tools.json"
DESC_DIR="${JENGA_DESCRIPTORS_DIR:-$PACKAGE_ROOT/skills/j-connect/descriptors}"

# Mirrors the base vocabulary in validate-tools-registry.sh (resolve-tools.sh does the same);
# only used to decide whether --add-category must extend the file. The validator stays the authority.
BASE_CATEGORIES='["runtime","testing","lint","CI","infra"]'
SKELETON='{"registry_version":1,"categories":[],"suppress":[],"tools":[]}'

TMP_CANDIDATE=""
TMP_PUBLISH=""
TMP_PROBE=""
cleanup() {
  [ -z "$TMP_CANDIDATE" ] || rm -f "$TMP_CANDIDATE"
  [ -z "$TMP_PUBLISH" ] || rm -f "$TMP_PUBLISH"
  [ -z "$TMP_PROBE" ] || rm -f "$TMP_PROBE"
}
trap cleanup EXIT

usage() {
  cat >&2 <<'EOF'
usage: tools-entry.sh <subcommand> [options]
  add        --layer user|project --name N --category C --enforcement required|recommended
             --rationale TEXT [--version V] [--alternative "NAME::WHY_NOT"]... [--descriptor ID]
             [--install-text TEXT] [--add-category]
  edit       --layer L --name N [field flags as for add] [--clear-alternatives]
             [--clear-descriptor] [--clear-install-text]
  remove     --layer L --name N
  suppress   --layer L --name N
  unsuppress --layer L --name N
  descriptors [--format lines|json]
  show       --layer shipped|user|project [--name N]
  path       --layer shipped|user|project
  check      <category|enforcement|version|descriptor|name> <value> [--layer L]
EOF
}

die() {
  local code="$1"
  shift
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

die_usage() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  usage
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  die 3 "jq is required but was not found on PATH; install jq (e.g. brew install jq)"
fi

[ "$#" -ge 1 ] || {
  usage
  exit 2
}

SUB="$1"
shift

case "$SUB" in
  -h | --help | help)
    usage
    exit 0
    ;;
  add | edit | remove | suppress | unsuppress | descriptors | show | path | check) ;;
  *) die_usage "unknown subcommand: $SUB" ;;
esac

# --- option parsing -----------------------------------------------------------

LAYER=""
NAME=""
HAVE_NAME=0
CATEGORY=""
HAVE_CATEGORY=0
ENFORCEMENT=""
HAVE_ENFORCEMENT=0
RATIONALE=""
HAVE_RATIONALE=0
VERSION=""
HAVE_VERSION=0
DESCRIPTOR=""
HAVE_DESCRIPTOR=0
INSTALL_TEXT=""
HAVE_INSTALL_TEXT=0
ALTS_JSON='[]'
HAVE_ALTS=0
CLEAR_ALTS=0
CLEAR_DESCRIPTOR=0
CLEAR_INSTALL_TEXT=0
ADD_CATEGORY=0
FORMAT="lines"
POS1=""
POS2=""
NPOS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --layer | --name | --category | --enforcement | --rationale | --version | --descriptor | --install-text | --alternative | --format)
      [ "$#" -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --layer) LAYER="$2" ;;
        --name)
          NAME="$2"
          HAVE_NAME=1
          ;;
        --category)
          CATEGORY="$2"
          HAVE_CATEGORY=1
          ;;
        --enforcement)
          ENFORCEMENT="$2"
          HAVE_ENFORCEMENT=1
          ;;
        --rationale)
          RATIONALE="$2"
          HAVE_RATIONALE=1
          ;;
        --version)
          VERSION="$2"
          HAVE_VERSION=1
          ;;
        --descriptor)
          DESCRIPTOR="$2"
          HAVE_DESCRIPTOR=1
          ;;
        --install-text)
          INSTALL_TEXT="$2"
          HAVE_INSTALL_TEXT=1
          ;;
        --format) FORMAT="$2" ;;
        --alternative)
          case "$2" in
            *::*) ;;
            *) die_usage "--alternative must look like \"NAME::WHY_NOT\" (got: $2)" ;;
          esac
          ALTS_JSON="$(jq -c --arg n "${2%%::*}" --arg w "${2#*::}" '. + [{name: $n, why_not: $w}]' <<<"$ALTS_JSON")"
          HAVE_ALTS=1
          ;;
      esac
      shift 2
      ;;
    --clear-alternatives)
      CLEAR_ALTS=1
      shift
      ;;
    --clear-descriptor)
      CLEAR_DESCRIPTOR=1
      shift
      ;;
    --clear-install-text)
      CLEAR_INSTALL_TEXT=1
      shift
      ;;
    --add-category)
      ADD_CATEGORY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      NPOS=$((NPOS + 1))
      case "$NPOS" in
        1) POS1="$1" ;;
        2) POS2="$1" ;;
        *) die_usage "unexpected argument: $1" ;;
      esac
      shift
      ;;
  esac
done

if [ "$SUB" != "check" ] && [ "$NPOS" -gt 0 ]; then
  die_usage "unexpected argument: $POS1"
fi

# --- layer resolution (mirrors scripts/resolve-tools.sh) -----------------------

LAYER_FILE=""

resolve_layer_file() {
  local f cfg
  case "$LAYER" in
    user)
      f="${JENGA_USER_TOOLS_FILE:-}"
      if [ -z "$f" ] && [ -n "${HOME:-}" ]; then
        f="$HOME/.jenga/tools.json"
      fi
      [ -n "$f" ] || die 2 "cannot determine the user layer path (set JENGA_USER_TOOLS_FILE or HOME)"
      LAYER_FILE="$f"
      ;;
    project)
      # Runs in the caller's working directory so the upward search starts where the caller is.
      if ! cfg="$(bash "$RESOLVE_ROOT" get configs)"; then
        die 5 "could not resolve the project configs path via resolve-root.sh"
      fi
      LAYER_FILE="$cfg/preferred-tools.json"
      ;;
    shipped)
      LAYER_FILE="$SHIPPED_FILE"
      ;;
  esac
}

require_layer() { # $1 = space-separated allowed layers
  local ok=0 l
  [ -n "$LAYER" ] || die_usage "$SUB needs --layer"
  for l in $1; do
    [ "$l" = "$LAYER" ] && ok=1
  done
  [ "$ok" -eq 1 ] || die_usage "--layer must be one of: $1 (got: $LAYER)"
}

require_name() {
  [ "$HAVE_NAME" -eq 1 ] || die_usage "$SUB needs --name"
}

# --- validation and writing ----------------------------------------------------

# validate_file <file> <path-to-show-in-messages>: runs the validator; on failure prints its
# messages (with the shown path) to stderr and returns non-zero.
validate_file() {
  local f="$1" shown="$2" out rc
  out="$(bash "$VALIDATOR" "$f" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${out//"$f"/$shown}" >&2
    return "$rc"
  fi
  return 0
}

# Reads the current document. Existing files must already be valid; absent files start as
# the minimal skeleton.
CURRENT=""
load_current() {
  if [ -f "$LAYER_FILE" ]; then
    if ! jq -e 'type == "object"' "$LAYER_FILE" >/dev/null 2>&1; then
      die 4 "$LAYER_FILE: existing file is not a parseable JSON object; fix it by hand first. Nothing was changed."
    fi
    if ! validate_file "$LAYER_FILE" "$LAYER_FILE"; then
      die 4 "$LAYER_FILE: existing file is not a valid registry (messages above); fix it by hand first. Nothing was changed."
    fi
    CURRENT="$(cat "$LAYER_FILE")"
  else
    CURRENT="$SKELETON"
  fi
}

count_entries() { # $1 = name; prints how many tools in CURRENT carry that name
  jq -r --arg n "$1" '[(.tools // [])[] | select(.name == $n)] | length' <<<"$CURRENT"
}

count_suppressed() {
  jq -r --arg n "$1" '[(.suppress // [])[] | select(. == $n)] | length' <<<"$CURRENT"
}

# publish <candidate-file>: copies the candidate to a temp file beside the target and renames it
# over the target (atomic on the same filesystem).
publish() {
  local cand="$1" dir mode
  dir="$(dirname "$LAYER_FILE")"
  mkdir -p "$dir" || die 1 "cannot create directory: $dir"
  TMP_PUBLISH="$(mktemp "$dir/.tools-entry.XXXXXX")" || die 1 "cannot create a temp file in $dir"
  if [ -f "$LAYER_FILE" ]; then
    # Keep the existing file's mode and ownership.
    cp -p "$LAYER_FILE" "$TMP_PUBLISH" 2>/dev/null || true
  else
    mode="$(printf '%o' $((0666 & ~$(umask))))"
    chmod "$mode" "$TMP_PUBLISH" 2>/dev/null || true
  fi
  cat "$cand" >"$TMP_PUBLISH" || die 1 "cannot write $TMP_PUBLISH"
  mv -f "$TMP_PUBLISH" "$LAYER_FILE" || die 1 "cannot replace $LAYER_FILE"
  TMP_PUBLISH=""
}

# mutate <action> <name> <jq-filter> [jq options...]: applies the filter to CURRENT, validates
# the candidate, publishes it, and prints the result object.
mutate() {
  local action="$1" name="$2" filter="$3"
  shift 3
  TMP_CANDIDATE="$(mktemp "${TMPDIR:-/tmp}/tools-entry.XXXXXX")" || die 1 "cannot create a temp file"
  if ! printf '%s' "$CURRENT" | jq "$@" "$filter" >"$TMP_CANDIDATE" 2>"$TMP_CANDIDATE.err"; then
    local msg
    msg="$(cat "$TMP_CANDIDATE.err" 2>/dev/null)"
    rm -f "$TMP_CANDIDATE.err"
    die 1 "internal error applying $action to $LAYER_FILE: $msg"
  fi
  rm -f "$TMP_CANDIDATE.err"
  if ! validate_file "$TMP_CANDIDATE" "$LAYER_FILE"; then
    die 4 "$action rejected: the result would not be a valid registry (messages above). $LAYER_FILE was left untouched."
  fi
  publish "$TMP_CANDIDATE"
  jq -n -c --arg a "$action" --arg l "$LAYER" --arg p "$LAYER_FILE" --arg n "$name" \
    '{ok: true, action: $a, layer: $l, path: $p, name: $n, changed: true}'
}

# JQ fragment shared by add and edit: declares $cat in the file's `categories` when asked to
# and when it is not in the base vocabulary.
# shellcheck disable=SC2016  # $-names are jq variables, not shell expansions
ADD_CATEGORY_FILTER='
  | if $addcat and ($cat | type == "string") and ($base | index($cat) == null) then
      .categories = ((.categories // []) | if index($cat) == null then . + [$cat] else . end)
    else . end'

# --- subcommands --------------------------------------------------------------

cmd_descriptors() {
  case "$FORMAT" in
    lines | json) ;;
    *) die_usage "--format must be lines or json (got: $FORMAT)" ;;
  esac
  local ids=""
  if [ -d "$DESC_DIR" ]; then
    ids="$(find "$DESC_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null |
      sed -e 's|.*/||' -e 's|\.json$||' | LC_ALL=C sort)"
  fi
  if [ "$FORMAT" = "json" ]; then
    if [ -n "$ids" ]; then
      printf '%s\n' "$ids" | jq -R . | jq -s -c .
    else
      printf '[]\n'
    fi
  elif [ -n "$ids" ]; then
    printf '%s\n' "$ids"
  fi
}

cmd_path() {
  require_layer "shipped user project"
  resolve_layer_file
  printf '%s\n' "$LAYER_FILE"
}

cmd_show() {
  require_layer "shipped user project"
  resolve_layer_file
  if [ ! -f "$LAYER_FILE" ]; then
    CURRENT="$SKELETON"
  else
    jq -e 'type == "object"' "$LAYER_FILE" >/dev/null 2>&1 ||
      die 4 "$LAYER_FILE: not a parseable JSON object"
    CURRENT="$(cat "$LAYER_FILE")"
  fi
  if [ "$HAVE_NAME" -eq 1 ]; then
    [ "$(count_entries "$NAME")" -gt 0 ] || die 1 "no tool named \"$NAME\" in the $LAYER layer ($LAYER_FILE)"
    jq --arg n "$NAME" '(.tools // [])[] | select(.name == $n)' <<<"$CURRENT"
  else
    jq . <<<"$CURRENT"
  fi
}

cmd_add() {
  require_layer "user project"
  require_name
  resolve_layer_file
  load_current
  [ "$(count_entries "$NAME")" -eq 0 ] || die 1 "tool \"$NAME\" already exists in the $LAYER layer ($LAYER_FILE); use edit to change it"

  local hint entry
  hint='{}'
  if [ "$HAVE_DESCRIPTOR" -eq 1 ]; then
    hint="$(jq -c --arg v "$DESCRIPTOR" '. + {descriptor: $v}' <<<"$hint")"
  fi
  if [ "$HAVE_INSTALL_TEXT" -eq 1 ]; then
    hint="$(jq -c --arg v "$INSTALL_TEXT" '. + {text: $v}' <<<"$hint")"
  fi
  [ "$HAVE_VERSION" -eq 1 ] || VERSION="*"
  entry="$(jq -n -c --arg n "$NAME" --argjson alts "$ALTS_JSON" --arg v "$VERSION" --argjson hint "$hint" \
    '{name: $n, alternatives: $alts, version: $v, install_hint: $hint}')"
  if [ "$HAVE_CATEGORY" -eq 1 ]; then
    entry="$(jq -c --arg v "$CATEGORY" '. + {category: $v}' <<<"$entry")"
  fi
  if [ "$HAVE_ENFORCEMENT" -eq 1 ]; then
    entry="$(jq -c --arg v "$ENFORCEMENT" '. + {enforcement: $v}' <<<"$entry")"
  fi
  if [ "$HAVE_RATIONALE" -eq 1 ]; then
    entry="$(jq -c --arg v "$RATIONALE" '. + {rationale: $v}' <<<"$entry")"
  fi

  # Canonical field order, keeping only the fields that were given.
  # shellcheck disable=SC2016
  entry="$(jq -c '. as $e | reduce (["name", "category", "enforcement", "rationale", "alternatives", "version", "install_hint"][] | select(. as $x | $e | has($x))) as $k ({}; .[$k] = $e[$k])' <<<"$entry")"

  local addcat=false
  [ "$ADD_CATEGORY" -eq 1 ] && addcat=true
  mutate add "$NAME" ".tools = ((.tools // []) + [\$entry]) $ADD_CATEGORY_FILTER" \
    --argjson entry "$entry" --argjson addcat "$addcat" --arg cat "$CATEGORY" --argjson base "$BASE_CATEGORIES"
}

cmd_edit() {
  require_layer "user project"
  require_name
  if [ "$CLEAR_ALTS" -eq 1 ] && [ "$HAVE_ALTS" -eq 1 ]; then
    die_usage "--clear-alternatives cannot be combined with --alternative"
  fi
  if [ "$CLEAR_DESCRIPTOR" -eq 1 ] && [ "$HAVE_DESCRIPTOR" -eq 1 ]; then
    die_usage "--clear-descriptor cannot be combined with --descriptor"
  fi
  if [ "$CLEAR_INSTALL_TEXT" -eq 1 ] && [ "$HAVE_INSTALL_TEXT" -eq 1 ]; then
    die_usage "--clear-install-text cannot be combined with --install-text"
  fi
  if [ $((HAVE_CATEGORY + HAVE_ENFORCEMENT + HAVE_RATIONALE + HAVE_VERSION + HAVE_DESCRIPTOR + HAVE_INSTALL_TEXT + HAVE_ALTS + CLEAR_ALTS + CLEAR_DESCRIPTOR + CLEAR_INSTALL_TEXT)) -eq 0 ]; then
    die_usage "edit needs at least one field flag"
  fi
  resolve_layer_file
  load_current
  [ "$(count_entries "$NAME")" -gt 0 ] || die 1 "no tool named \"$NAME\" in the $LAYER layer ($LAYER_FILE); use add to create it"

  local patch ihset ihdel
  patch='{}'
  ihset='{}'
  ihdel='[]'
  if [ "$HAVE_CATEGORY" -eq 1 ]; then
    patch="$(jq -c --arg v "$CATEGORY" '. + {category: $v}' <<<"$patch")"
  fi
  if [ "$HAVE_ENFORCEMENT" -eq 1 ]; then
    patch="$(jq -c --arg v "$ENFORCEMENT" '. + {enforcement: $v}' <<<"$patch")"
  fi
  if [ "$HAVE_RATIONALE" -eq 1 ]; then
    patch="$(jq -c --arg v "$RATIONALE" '. + {rationale: $v}' <<<"$patch")"
  fi
  if [ "$HAVE_VERSION" -eq 1 ]; then
    patch="$(jq -c --arg v "$VERSION" '. + {version: $v}' <<<"$patch")"
  fi
  if [ "$HAVE_ALTS" -eq 1 ]; then
    patch="$(jq -c --argjson a "$ALTS_JSON" '. + {alternatives: $a}' <<<"$patch")"
  fi
  if [ "$CLEAR_ALTS" -eq 1 ]; then
    patch="$(jq -c '. + {alternatives: []}' <<<"$patch")"
  fi
  if [ "$HAVE_DESCRIPTOR" -eq 1 ]; then
    ihset="$(jq -c --arg v "$DESCRIPTOR" '. + {descriptor: $v}' <<<"$ihset")"
  fi
  if [ "$HAVE_INSTALL_TEXT" -eq 1 ]; then
    ihset="$(jq -c --arg v "$INSTALL_TEXT" '. + {text: $v}' <<<"$ihset")"
  fi
  if [ "$CLEAR_DESCRIPTOR" -eq 1 ]; then
    ihdel="$(jq -c '. + ["descriptor"]' <<<"$ihdel")"
  fi
  if [ "$CLEAR_INSTALL_TEXT" -eq 1 ]; then
    ihdel="$(jq -c '. + ["text"]' <<<"$ihdel")"
  fi

  local addcat=false
  [ "$ADD_CATEGORY" -eq 1 ] && addcat=true
  mutate edit "$NAME" "
    .tools = [ (.tools // [])[]
      | if .name == \$n then
          (. + \$patch)
          | if ((\$ihset | length) + (\$ihdel | length)) > 0 then
              .install_hint = (reduce \$ihdel[] as \$k ((.install_hint // {}) + \$ihset; del(.[\$k])))
            else . end
        else . end ]
    $ADD_CATEGORY_FILTER" \
    --arg n "$NAME" --argjson patch "$patch" --argjson ihset "$ihset" --argjson ihdel "$ihdel" \
    --argjson addcat "$addcat" --arg cat "$CATEGORY" --argjson base "$BASE_CATEGORIES"
}

cmd_remove() {
  require_layer "user project"
  require_name
  resolve_layer_file
  load_current
  [ "$(count_entries "$NAME")" -gt 0 ] || die 1 "no tool named \"$NAME\" in the $LAYER layer ($LAYER_FILE)"
  # shellcheck disable=SC2016
  mutate remove "$NAME" '.tools = [(.tools // [])[] | select(.name != $n)]' --arg n "$NAME"
}

cmd_suppress() {
  require_layer "user project"
  require_name
  resolve_layer_file
  load_current
  if [ "$(count_suppressed "$NAME")" -gt 0 ]; then
    jq -n -c --arg l "$LAYER" --arg p "$LAYER_FILE" --arg n "$NAME" \
      '{ok: true, action: "suppress", layer: $l, path: $p, name: $n, changed: false}'
    return 0
  fi
  # shellcheck disable=SC2016
  mutate suppress "$NAME" '.suppress = ((.suppress // []) + [$n])' --arg n "$NAME"
}

cmd_unsuppress() {
  require_layer "user project"
  require_name
  resolve_layer_file
  load_current
  [ "$(count_suppressed "$NAME")" -gt 0 ] || die 1 "\"$NAME\" is not suppressed in the $LAYER layer ($LAYER_FILE)"
  # shellcheck disable=SC2016
  mutate unsuppress "$NAME" '.suppress = [(.suppress // [])[] | select(. != $n)]' --arg n "$NAME"
}

# check <field> <value>: validates one input by running the real validator on a probe registry
# whose every other field is valid.
probe_reason() { # $1 = probe document (JSON); prints validator messages joined with "; ", or nothing if valid
  local doc="$1" out
  TMP_PROBE="$(mktemp "${TMPDIR:-/tmp}/tools-entry-probe.XXXXXX")" || die 1 "cannot create a temp file"
  printf '%s' "$doc" >"$TMP_PROBE"
  if out="$(bash "$VALIDATOR" "$TMP_PROBE" 2>&1)"; then
    rm -f "$TMP_PROBE"
    TMP_PROBE=""
    return 0
  fi
  out="${out//"$TMP_PROBE"/}"
  rm -f "$TMP_PROBE"
  TMP_PROBE=""
  # Drop the "<path>: " and "tools[0] (probe): " prefixes, join the lines.
  printf '%s\n' "$out" | sed -E -e 's/^: //' -e 's/^tools\[0\]( \([^)]*\))?: //' |
    awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { print "" }'
}

cmd_check() {
  [ "$NPOS" -eq 2 ] || die_usage "check needs a field and a value"
  local field="$POS1" value="$POS2" cats='[]' entry doc reason extendable exists
  case "$field" in
    category | enforcement | version | descriptor | name) ;;
    *) die_usage "check field must be category, enforcement, version, descriptor or name (got: $field)" ;;
  esac
  if [ -n "$LAYER" ]; then
    require_layer "user project"
    resolve_layer_file
    if [ -f "$LAYER_FILE" ]; then
      cats="$(jq -c 'if (.categories | type) == "array" then [.categories[] | select(type == "string")] else [] end' "$LAYER_FILE" 2>/dev/null || printf '[]')"
      [ -n "$cats" ] || cats='[]'
    fi
  fi

  entry='{"name":"probe","category":"runtime","enforcement":"recommended","rationale":"probe","alternatives":[],"version":"*","install_hint":{"text":"probe"}}'
  case "$field" in
    category) entry="$(jq -c --arg v "$value" '.category = $v' <<<"$entry")" ;;
    enforcement) entry="$(jq -c --arg v "$value" '.enforcement = $v' <<<"$entry")" ;;
    version) entry="$(jq -c --arg v "$value" '.version = $v' <<<"$entry")" ;;
    descriptor) entry="$(jq -c --arg v "$value" '.install_hint = {descriptor: $v}' <<<"$entry")" ;;
    name) entry="$(jq -c --arg v "$value" '.name = $v' <<<"$entry")" ;;
  esac
  doc="$(jq -n -c --argjson c "$cats" --argjson t "$entry" '{registry_version: 1, categories: $c, suppress: [], tools: [$t]}')"
  reason="$(probe_reason "$doc")"

  if [ "$field" = "category" ]; then
    extendable=false
    if [ -n "$reason" ]; then
      doc="$(jq -n -c --arg v "$value" --argjson t "$entry" '{registry_version: 1, categories: [$v], suppress: [], tools: [$t]}')"
      [ -n "$(probe_reason "$doc")" ] || extendable=true
    fi
    jq -n -c --arg r "$reason" --argjson e "$extendable" \
      'if $r == "" then {valid: true, extendable: false} else {valid: false, reason: $r, extendable: $e} end'
    return 0
  fi

  if [ "$field" = "name" ]; then
    exists=false
    if [ -n "$LAYER" ] && [ -f "$LAYER_FILE" ]; then
      CURRENT="$(cat "$LAYER_FILE")"
      [ "$(count_entries "$value" 2>/dev/null || printf 0)" -gt 0 ] && exists=true
    fi
    if [ "$exists" = "true" ]; then
      jq -n -c --arg n "$value" --arg l "$LAYER" \
        '{valid: false, exists: true, reason: ("a tool named " + ($n | tojson) + " already exists in the " + $l + " layer; edit it instead")}'
      return 0
    fi
    jq -n -c --arg r "$reason" 'if $r == "" then {valid: true, exists: false} else {valid: false, exists: false, reason: $r} end'
    return 0
  fi

  jq -n -c --arg r "$reason" 'if $r == "" then {valid: true} else {valid: false, reason: $r} end'
}

case "$SUB" in
  descriptors) cmd_descriptors ;;
  path) cmd_path ;;
  show) cmd_show ;;
  add) cmd_add ;;
  edit) cmd_edit ;;
  remove) cmd_remove ;;
  suppress) cmd_suppress ;;
  unsuppress) cmd_unsuppress ;;
  check) cmd_check ;;
esac

#!/usr/bin/env bash
# conventions-entry.sh - the deterministic backend of the j.conventions wizard (E69_S04).
#
# skills/j-conventions/SKILL.md runs the conversation; this script does everything that is deterministic:
# resolving the instance path, reading the recorded conventions, listing the categories and their presets,
# running the detector, and validating every single input BEFORE it is accepted. Modelled on
# skills/j-tools/scripts/tools-entry.sh. The file format, the categories and the strength rule are defined by
# templates/conventions-schema.json and documented in project/documentation/project-conventions.md.
#
# Project layer only: there is no --layer option anywhere (epic E69, Decision 5). The one instance is
# <configs>/conventions.json, where <configs> comes from scripts/resolve-root.sh get configs (JENGA_PROJECT_ROOT is
# honoured).
#
# Usage:
#   conventions-entry.sh path                                 print the project instance path
#   conventions-entry.sh show [--category ID]                 print the recorded instance (or one category's entry)
#   conventions-entry.sh categories [--format lines|json]     the 9 category ids in schema order, with their labels
#   conventions-entry.sh detect                               run detect-conventions.sh, its JSON unchanged
#   conventions-entry.sh presets CATEGORY-ID                  that category's general-standard presets, as JSON
#   conventions-entry.sh check CATEGORY-ID FIELD "VALUE"      validate one `values` field (or `strength`) of a category
#   conventions-entry.sh check summary "VALUE"                validate a one-line summary
#   conventions-entry.sh draft-init                           create a draft (seeded from the recorded instance)
#   conventions-entry.sh draft-set CATEGORY-ID --draft PATH --source detected|preset|custom [--preset ID]
#                         [--summary TEXT] [--value FIELD=VALUE]... [--unset FIELD]... [--strength advisory|confirm]
#   conventions-entry.sh draft-skip CATEGORY-ID --draft PATH  record nothing for a category
#   conventions-entry.sh draft-show --draft PATH [--category ID]   print the draft (or one category's entry)
#   conventions-entry.sh draft-diff --draft PATH [--format json|text]   draft against the recorded instance
#   conventions-entry.sh commit --draft PATH                  validate, write atomically, generate, self-validate
#   conventions-entry.sh --help                               print this contract
#
# Option values are passed as a separate argument (`--category naming`, not `--category=naming`).
#
# path:       prints <configs>/conventions.json whether or not the file exists.
# show:       prints the recorded instance unchanged; when none exists prints the empty skeleton
#             {"conventions_version":1,"categories":{}} and exits 0. With --category prints that category's entry
#             as JSON, exit 1 when it is absent (or no instance exists). An existing instance that is not a
#             parseable JSON object exits 4.
# categories: one "<id><TAB><label>" line per category, in schema order. --format json prints an array of
#             {"id","label","applies_to","values"} where `values` is the category's field list from the schema
#             (type, required, single_line, non_empty) and `applies_to` is present only when the schema has one
#             (commit-format: non-board commits only; EST naming stays mandatory for board commits).
# detect:     runs skills/j-conventions/scripts/detect-conventions.sh and prints its JSON unchanged (stdout, stderr
#             and exit code pass through). Read-only. Run it once per wizard session.
# presets:    prints the category's presets from templates/conventions-presets.json as a JSON array, each preset
#             with the catalog's own fields (id, label, description, values) plus `placeholder_fields`: the names of
#             `values` fields that still hold an unreplaced placeholder such as "<lint command>". Exit 1 for an
#             unknown category.
# check:      validates ONE input with the real scripts/validate-conventions.sh (a one-category probe document is
#             built and validated, so no rule is duplicated here) and prints {"valid": true} or
#             {"valid": false, "reason": "<validator message>"}; the exit status is 0 for both. FIELD is a name from
#             the category's `values` field list; its value is typed from the schema (boolean: true|false, integer:
#             digits, string_array: comma separated, anything else a string). It refuses a multi-line value, an
#             empty value, an unknown category or field, a wrong type, a `block` strength, and a value that is
#             still an unreplaced <placeholder> (see below).
#
# draft-init: creates the draft, a temp file named ${TMPDIR:-/tmp}/conventions-draft.XXXXXX (never inside the project
#             root), and prints its path on stdout; every later draft-* call and commit takes it as --draft. When a
#             conventions.json already exists the draft is seeded with its recorded answers (this is how a re-run
#             pre-selects them), otherwise with the empty skeleton; a note on stderr says which. An existing instance
#             that is not valid is refused (exit 4): fix it by hand first.
# draft-set:  records one category's answer. --source preset needs --preset ID from the catalog; the summary defaults to
#             the preset's label and `values` to its values. --source detected takes the detector's value for that
#             category (exit 1 when it found none; the summary defaults to the matching preset's label, else a
#             "field=value (detected)" line); the detector result is cached beside the draft after the first call.
#             --source custom needs --summary and at least the category's required --value fields. --value FIELD=VALUE
#             sets or overrides one `values` field (typed as in `check`), --unset FIELD drops one, --strength advisory
#             or confirm sets an explicit strength (block is refused by the validator). The WHOLE resulting document is
#             validated with the real validator and the placeholder rule BEFORE anything is applied: an invalid input
#             exits 1 with the reason on stderr and the draft stays byte-identical. A preset whose value is still a bare
#             <placeholder> (see `presets`: placeholder_fields) is refused until the user gives the real value with
#             --value, or drops an optional field with --unset. Prints {"ok":true,"action":"draft-set",...}.
# draft-skip: removes the category from the draft (skipped = no convention recorded). A category that is not in the
#             draft is a successful no-op ("changed": false); an unknown category id exits 1.
# draft-show: prints the draft, or with --category one entry (exit 1 when absent).
# draft-diff: compares the draft with the recorded instance (an absent instance counts as empty). JSON by default:
#             {"added":[ids],"removed":[ids],"changed":[ids],"unchanged":[ids],"categories":[{"id","label","status",
#             "before","after"}]} with before/after the full entries (null when absent), in schema order, only
#             categories present on either side; --format text prints one line per category ("+" added, "-" removed,
#             "~" changed with before -> after summaries, "=" unchanged).
# commit:     (1) validates the draft and applies the placeholder rule; (2) under scripts/with-lock.sh on the instance,
#             writes a candidate in the instance's directory and renames it over conventions.json (atomic replace; the
#             previous bytes and the checklist registry are backed up first, and the write is skipped when the draft
#             records exactly what is already there); (3) runs scripts/generate-convention-checklist.sh; (4) validates
#             conventions.json and the registry (scripts/validate-conventions.sh, scripts/validate-checklists.sh). Only
#             after all of that passed does it print {"ok":true,"action":"commit","path","registry","changed",
#             "categories","generator"} and remove the draft. If step 3 or 4 fails, the previous conventions.json is
#             restored (removed when there was none), the registry is restored the same way, the failing validator's
#             lines go to stderr, the exit code is non-zero, NO success line is printed and the draft is kept so the
#             wizard can retry. If the lock cannot be acquired, nothing is written (exit 6). Never reports success on a
#             failed validation. The registry is "<configs>/checklists.json"; generated items are advisory or confirm,
#             never block.
#
# Placeholders: a `values` string that is entirely one `<...>` token (for example the preset value
# "<lint command>") is a template the user has not filled in. It is refused here (`check` -> valid false with a reason
# naming the field) and by draft-set / commit, never silently stored. Prefixes and suffixes are fine
# ("feature/<slug>" is a pattern, not a placeholder). scripts/generate-convention-checklist.sh also treats a bare
# <...> value as unset, as a second line of defence.
#
# Writes: path, show, categories, detect, presets and check are read-only. Only `commit` writes project files
# (conventions.json and, through the generator, checklists.json); the draft-* calls touch temp files only.
#
# Environment (tests): JENGA_PROJECT_ROOT (project root), JENGA_CONVENTIONS_SCHEMA, JENGA_CONVENTIONS_PRESETS,
# JENGA_CONVENTIONS_GENERATOR (replaces scripts/generate-convention-checklist.sh), WITH_LOCK_* (with-lock.sh).
#
# Exit codes:
#   0  success (check prints its verdict, valid or not)
#   1  precondition failed (unknown category or preset, absent entry, no detected value) or an internal error;
#      draft-set refusing an invalid input
#   2  usage error
#   3  jq or python3 is not installed
#   4  the existing instance is not valid, or the draft / the written result failed validation (commit restores)
#   5  the project configs path could not be resolved
#   6  commit could not acquire the lock; nothing was written
#   7  the checklist generator failed; commit restored the previous files
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).

set -u

SELF="conventions-entry.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATOR="$PACKAGE_ROOT/scripts/validate-conventions.sh"
RESOLVE_ROOT="$PACKAGE_ROOT/scripts/resolve-root.sh"
DETECT="$SCRIPT_DIR/detect-conventions.sh"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$PACKAGE_ROOT/templates/conventions-schema.json}"
PRESETS="${JENGA_CONVENTIONS_PRESETS:-$PACKAGE_ROOT/templates/conventions-presets.json}"
GENERATOR="${JENGA_CONVENTIONS_GENERATOR:-$PACKAGE_ROOT/scripts/generate-convention-checklist.sh}"
CHECKLIST_VALIDATOR="$PACKAGE_ROOT/scripts/validate-checklists.sh"
WITH_LOCK="$PACKAGE_ROOT/scripts/with-lock.sh"
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

SKELETON='{"conventions_version":1,"categories":{}}'
# A string that is entirely one <...> token (surrounding whitespace allowed). Same shape the generator treats as unset.
PLACEHOLDER_RE='^\s*<[^<>]*>\s*$'

TMP_PROBE=""
TMP_FILES=""
cleanup() {
  local f
  # An interrupted commit puts both files back before it leaves (see rollback).
  if [ "${ROLLBACK_ARMED:-0}" -eq 1 ]; then
    rollback
  fi
  [ -z "$TMP_PROBE" ] || rm -f "$TMP_PROBE"
  for f in $TMP_FILES; do
    rm -f "$f"
  done
}
trap cleanup EXIT

# The contract is this file's own header (its "Usage:" block through the exit codes).
print_contract() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  local code="$1"
  shift
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

die_usage() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  printf 'run "%s --help" for the contract\n' "$SELF" >&2
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  die 3 "jq is required but was not found on PATH; install jq (e.g. brew install jq)"
fi

# --- shared helpers --------------------------------------------------------------------------------------

INSTANCE=""
resolve_instance() {
  local cfg
  [ -z "$INSTANCE" ] || return 0
  if ! cfg="$(bash "$RESOLVE_ROOT" get configs 2>/dev/null)" || [ -z "$cfg" ]; then
    die 5 "could not resolve the project configs path via resolve-root.sh"
  fi
  INSTANCE="$cfg/conventions.json"
}

schema_readable() {
  jq -e '.categories | type == "object"' "$SCHEMA" >/dev/null 2>&1 ||
    die 1 "cannot read the category list from $SCHEMA"
}

# category_exists <id>: succeeds when the id is in the schema.
category_exists() {
  schema_readable
  jq -e --arg c "$1" '.categories | has($c)' "$SCHEMA" >/dev/null 2>&1
}

unknown_category_message() {
  printf 'unknown category: %s (allowed: %s)' "$1" "$(jq -r '.categories | keys_unsorted | join(", ")' "$SCHEMA")"
}

# category_known <id>: exits 1 with the allowed list when the id is not in the schema.
category_known() {
  category_exists "$1" || die 1 "$(unknown_category_message "$1")"
}

# coerce_value <category> <field> <raw>: prints the JSON for the raw string, typed from the schema. A raw value that
# does not fit the field's type is kept as a string so the real validator reports the wrong type.
coerce_value() {
  local ftype
  ftype="$(jq -r --arg c "$1" --arg f "$2" '.categories[$c].values[$f].type // "string"' "$SCHEMA")"
  case "$ftype" in
    boolean)
      case "$3" in
        true | false) printf '%s\n' "$3" ;;
        *) jq -n -c --arg v "$3" '$v' ;;
      esac
      ;;
    integer)
      if printf '%s' "$3" | grep -Eq '^(0|-?[1-9][0-9]*)$'; then
        printf '%s\n' "$3"
      else
        jq -n -c --arg v "$3" '$v'
      fi
      ;;
    string_array)
      jq -n -c --arg v "$3" '$v | split(",") | map(gsub("^\\s+|\\s+$"; ""))'
      ;;
    *) jq -n -c --arg v "$3" '$v' ;;
  esac
}

# placeholder_fields <values-json>: prints a JSON array of the field names whose string value is a bare <...> token.
placeholder_fields() {
  jq -c --arg re "$PLACEHOLDER_RE" \
    '[to_entries[] | select((.value | type) == "string" and (.value | test($re))) | .key]' <<<"$1"
}

# validator_reason <document-file>: prints the validator's problem lines joined with "; " (file prefix removed), or
# nothing when the document is valid. Exits 3 when python3 is missing.
validator_reason() {
  local f="$1" out rc
  out="$(bash "$VALIDATOR" "$f" 2>&1 >/dev/null)"
  rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 3 ]; then
    die 3 "python3 is required by validate-conventions.sh but was not found on PATH"
  fi
  printf '%s\n' "${out//"$f: "/}" | awk 'NF { if (n++) printf "; "; printf "%s", $0 } END { print "" }'
}

# --- subcommands -----------------------------------------------------------------------------------------

cmd_path() {
  [ "$#" -eq 0 ] || die_usage "path takes no arguments (the wizard is project layer only; there is no --layer)"
  resolve_instance
  printf '%s\n' "$INSTANCE"
}

cmd_show() {
  local category="" have_category=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --category)
        [ "$#" -ge 2 ] || die_usage "--category needs a value"
        category="$2"
        have_category=1
        shift 2
        ;;
      *) die_usage "show: unexpected argument: $1" ;;
    esac
  done
  resolve_instance
  if [ ! -f "$INSTANCE" ]; then
    if [ "$have_category" -eq 1 ]; then
      die 1 "no conventions recorded: $INSTANCE does not exist, so category \"$category\" is absent"
    fi
    printf '%s\n' "$SKELETON"
    return 0
  fi
  jq -e 'type == "object"' "$INSTANCE" >/dev/null 2>&1 ||
    die 4 "$INSTANCE: not a parseable JSON object; fix it by hand first"
  if [ "$have_category" -eq 1 ]; then
    jq -e --arg c "$category" '.categories[$c] // empty' "$INSTANCE" ||
      die 1 "category \"$category\" is not recorded in $INSTANCE"
    return 0
  fi
  cat "$INSTANCE"
}

cmd_categories() {
  local format="lines"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --format)
        [ "$#" -ge 2 ] || die_usage "--format needs a value"
        format="$2"
        shift 2
        ;;
      *) die_usage "categories: unexpected argument: $1" ;;
    esac
  done
  schema_readable
  case "$format" in
    lines) jq -r '.categories | to_entries[] | "\(.key)\t\(.value.label // .key)"' "$SCHEMA" ;;
    json)
      jq '[.categories | to_entries[]
           | {id: .key, label: (.value.label // .key)}
             + (if .value.applies_to then {applies_to: .value.applies_to} else {} end)
             + {values: .value.values}]' "$SCHEMA"
      ;;
    *) die_usage "--format must be lines or json (got: $format)" ;;
  esac
}

cmd_detect() {
  [ "$#" -eq 0 ] || die_usage "detect takes no arguments"
  [ -f "$DETECT" ] || die 1 "detector not found: $DETECT"
  bash "$DETECT"
}

cmd_presets() {
  [ "$#" -eq 1 ] || die_usage "presets needs exactly one category id"
  category_known "$1"
  jq -e --arg c "$1" '.categories[$c] | type == "array"' "$PRESETS" >/dev/null 2>&1 ||
    die 1 "no presets for category \"$1\" in $PRESETS"
  jq --arg c "$1" --arg re "$PLACEHOLDER_RE" \
    '.categories[$c] | map(. + {placeholder_fields: [.values | to_entries[]
        | select((.value | type) == "string" and (.value | test($re))) | .key]})' "$PRESETS"
}

# check: see the header. A probe document holds one category whose required fields carry dummy values; the field
# under test replaces its dummy, and the real validator judges the result.
cmd_check() {
  local category field value probe_values entry doc reason typed bad
  [ "$#" -ge 2 ] || die_usage "check needs a category id, a field and a value (or: check summary \"VALUE\")"
  schema_readable
  if [ "$1" = "summary" ] && [ "$#" -eq 2 ]; then
    category="$(jq -r '.categories | keys_unsorted[0]' "$SCHEMA")"
    field="summary"
    value="$2"
  else
    [ "$#" -eq 3 ] || die_usage "check needs a category id, a field and a value (or: check summary \"VALUE\")"
    category="$1"
    field="$2"
    value="$3"
    if ! category_exists "$category"; then
      jq -n -c --arg r "$(unknown_category_message "$category")" '{valid: false, reason: $r}'
      return 0
    fi
  fi

  probe_values="$(jq -c --arg c "$category" '.categories[$c].values | to_entries
      | map(select(.value.required == true)
            | {key, value: (if .value.type == "boolean" then true
                            elif .value.type == "integer" then 1
                            elif .value.type == "string_array" then ["probe"]
                            else "probe" end)})
      | from_entries' "$SCHEMA")"
  entry="$(jq -n -c --argjson v "$probe_values" '{source: "custom", summary: "probe", values: $v}')"

  case "$field" in
    summary) entry="$(jq -c --arg v "$value" '.summary = $v' <<<"$entry")" ;;
    strength) entry="$(jq -c --arg v "$value" '.strength = $v' <<<"$entry")" ;;
    *)
      typed="$(coerce_value "$category" "$field" "$value")"
      entry="$(jq -c --arg f "$field" --argjson v "$typed" '.values[$f] = $v' <<<"$entry")"
      ;;
  esac

  doc="$(jq -n -c --argjson e "$entry" --arg c "$category" --slurpfile s "$SCHEMA" \
    '{conventions_version: $s[0].conventions_version, categories: {($c): $e}}')"
  TMP_PROBE="$(mktemp "${TMPDIR:-/tmp}/conventions-entry-probe.XXXXXX")" || die 1 "cannot create a temp file"
  printf '%s\n' "$doc" >"$TMP_PROBE"
  reason="$(validator_reason "$TMP_PROBE")"
  rm -f "$TMP_PROBE"
  TMP_PROBE=""

  if [ -z "$reason" ] && [ "$field" != "summary" ] && [ "$field" != "strength" ]; then
    bad="$(placeholder_fields "$(jq -c '.values' <<<"$entry")" | jq -r '.[]')"
    if [ -n "$bad" ]; then
      reason="$field is still an unreplaced placeholder ($value): supply the real value, or leave the field unset"
    fi
  fi

  jq -n -c --arg r "$reason" 'if $r == "" then {valid: true} else {valid: false, reason: $r} end'
}

# --- drafts ----------------------------------------------------------------------------------------------

# Parsed options shared by the draft-* and commit subcommands.
DRAFT=""
SOURCE=""
PRESET_ID=""
HAVE_PRESET=0
SUMMARY=""
HAVE_SUMMARY=0
STRENGTH=""
HAVE_STRENGTH=0
CATEGORY_OPT=""
HAVE_CATEGORY_OPT=0
FORMAT=""
POS1=""
NPOS=0
VAL_FIELDS=()
VAL_RAWS=()
UNSET_FIELDS=()

parse_draft_opts() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --draft | --source | --preset | --summary | --value | --unset | --strength | --category | --format)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value"
        case "$1" in
          --draft) DRAFT="$2" ;;
          --source) SOURCE="$2" ;;
          --preset)
            PRESET_ID="$2"
            HAVE_PRESET=1
            ;;
          --summary)
            SUMMARY="$2"
            HAVE_SUMMARY=1
            ;;
          --strength)
            STRENGTH="$2"
            HAVE_STRENGTH=1
            ;;
          --category)
            CATEGORY_OPT="$2"
            HAVE_CATEGORY_OPT=1
            ;;
          --format) FORMAT="$2" ;;
          --unset) UNSET_FIELDS[${#UNSET_FIELDS[@]}]="$2" ;;
          --value)
            case "$2" in
              ?*=*) ;;
              *) die_usage "--value must look like FIELD=VALUE (got: $2)" ;;
            esac
            VAL_FIELDS[${#VAL_FIELDS[@]}]="${2%%=*}"
            VAL_RAWS[${#VAL_RAWS[@]}]="${2#*=}"
            ;;
        esac
        shift 2
        ;;
      --layer) die_usage "there is no --layer option: the wizard records project conventions only" ;;
      -*) die_usage "unknown option: $1" ;;
      *)
        NPOS=$((NPOS + 1))
        [ "$NPOS" -le 1 ] || die_usage "unexpected argument: $1"
        POS1="$1"
        shift
        ;;
    esac
  done
}

require_draft() {
  [ -n "$DRAFT" ] || die_usage "$SUB needs --draft <path>"
  [ -f "$DRAFT" ] || die 1 "draft not found: $DRAFT (create one with draft-init)"
  jq -e 'type == "object" and (.categories | type == "object")' "$DRAFT" >/dev/null 2>&1 ||
    die 4 "draft is not a conventions document: $DRAFT"
}

# normalize_doc <file>: prints the document with categories in schema order, entry keys in the schema's entry-field
# order and `values` in the category's field order. Unknown keys are kept (after the known ones), so this only
# reorders; validation has already happened or happens on the result.
normalize_doc() {
  jq --slurpfile s "$SCHEMA" '
    def order($keys): . as $o
      | (reduce $keys[] as $k ({}; if ($o | has($k)) then .[$k] = $o[$k] else . end))
        + ($o | with_entries(select(.key as $k | ($keys | index($k)) == null)));
    ($s[0].categories | keys_unsorted) as $ids
    | ($s[0].entry_fields | keys_unsorted) as $efields
    | .categories |= (order($ids)
        | with_entries(.key as $id | .value |= (
            order($efields)
            | if (.values | type) == "object"
              then .values |= order($s[0].categories[$id].values // {} | keys_unsorted)
              else . end)))
    | order(["conventions_version", "categories"])' "$1"
}

# placeholder_report <file>: prints "category.field" for every bare <...> value in the document's categories.
placeholder_report() {
  jq -r --arg re "$PLACEHOLDER_RE" \
    '.categories | to_entries[] | .key as $c | (.value.values // {}) | to_entries[]
     | select((.value | type) == "string" and (.value | test($re))) | "\($c).\(.key)"' "$1"
}

# detect_cached: prints the detector's JSON; the first call runs it and caches the result beside the draft.
detect_cached() {
  local cache="$DRAFT.detect.json"
  if [ ! -s "$cache" ]; then
    bash "$DETECT" >"$cache" 2>/dev/null || {
      rm -f "$cache"
      die 1 "the detector failed; run \"$SELF detect\" to see why"
    }
  fi
  cat "$cache"
}

cmd_draft_init() {
  local root d seed_note
  [ "$#" -eq 0 ] || die_usage "draft-init takes no arguments"
  schema_readable
  resolve_instance
  root="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" || root=""
  d="$(mktemp "${TMPDIR:-/tmp}/conventions-draft.XXXXXX")" || die 1 "cannot create a draft file"
  if [ -n "$root" ]; then
    case "$d" in
      "${root%/}"/*)
        rm -f "$d"
        d="$(mktemp "/tmp/conventions-draft.XXXXXX")" || die 1 "cannot create a draft file"
        ;;
    esac
  fi
  if [ -f "$INSTANCE" ]; then
    if ! jq -e 'type == "object"' "$INSTANCE" >/dev/null 2>&1; then
      rm -f "$d"
      die 4 "$INSTANCE: not a parseable JSON object; fix it by hand first. No draft was created."
    fi
    local reason
    reason="$(validator_reason "$INSTANCE")"
    if [ -n "$reason" ]; then
      rm -f "$d"
      die 4 "$INSTANCE: the recorded conventions are not valid ($reason); fix it by hand first. No draft was created."
    fi
    cat "$INSTANCE" >"$d"
    seed_note="seeded from the recorded conventions in $INSTANCE ($(jq '.categories | length' "$INSTANCE") categories)"
  else
    printf '%s\n' "$SKELETON" >"$d"
    seed_note="no recorded conventions yet: starting blank"
  fi
  printf '%s: %s\n' "$SELF" "$seed_note" >&2
  printf '%s\n' "$d"
}

# Applies the candidate document ($1) to the draft after validating it. Refuses (exit 1) without touching the draft.
publish_draft_candidate() {
  local cand="$1" reason bad
  reason="$(validator_reason "$cand")"
  if [ -n "$reason" ]; then
    rm -f "$cand"
    die 1 "refused: $reason. The draft was not changed."
  fi
  bad="$(placeholder_report "$cand" | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    rm -f "$cand"
    die 1 "refused: unreplaced placeholder in ${bad% }: give the real value with --value FIELD=VALUE, or drop an optional field with --unset FIELD. The draft was not changed."
  fi
}

cmd_draft_set() {
  local category base_values entry summary_default detect_json detected cand i typed new_doc before after
  parse_draft_opts "$@"
  [ "$NPOS" -eq 1 ] || die_usage "draft-set needs a category id"
  category="$POS1"
  require_draft
  category_known "$category"
  case "$SOURCE" in
    detected | preset | custom) ;;
    "") die_usage "draft-set needs --source detected|preset|custom" ;;
    *) die_usage "--source must be detected, preset or custom (got: $SOURCE)" ;;
  esac
  if [ "$HAVE_PRESET" -eq 1 ] && [ "$SOURCE" != "preset" ]; then
    die_usage "--preset is only valid with --source preset"
  fi

  summary_default=""
  case "$SOURCE" in
    preset)
      [ "$HAVE_PRESET" -eq 1 ] || die_usage "--source preset needs --preset ID (see: $SELF presets $category)"
      if ! entry="$(jq -e -c --arg c "$category" --arg p "$PRESET_ID" '.categories[$c][]? | select(.id == $p)' "$PRESETS" 2>/dev/null)" || [ -z "$entry" ]; then
        die 1 "unknown preset \"$PRESET_ID\" for category $category (see: $SELF presets $category)"
      fi
      base_values="$(jq -c '.values' <<<"$entry")"
      summary_default="$(jq -r '.label' <<<"$entry")"
      if [ "$HAVE_STRENGTH" -eq 0 ] && jq -e 'has("strength")' <<<"$entry" >/dev/null; then
        STRENGTH="$(jq -r '.strength' <<<"$entry")"
        HAVE_STRENGTH=1
      fi
      ;;
    detected)
      detect_json="$(detect_cached)"
      detected="$(jq -c --arg c "$category" '.categories[$c].detected // null' <<<"$detect_json")"
      [ "$detected" != "null" ] || die 1 "the detector found no standard for category $category; pick a preset or custom"
      base_values="$detected"
      summary_default="$(jq -r --arg c "$category" --slurpfile p "$PRESETS" '
        .categories[$c] as $d
        | (if $d.preset_match != null
           then (($p[0].categories[$c][]? | select(.id == $d.preset_match) | .label) // $d.preset_match)
           else (($d.detected | to_entries | map("\(.key)=\(.value)") | join(", ")) + " (detected)") end)
        | gsub("[\r\n]+"; " ")' <<<"$detect_json")"
      ;;
    custom)
      [ "$HAVE_SUMMARY" -eq 1 ] || die_usage "--source custom needs --summary"
      base_values='{}'
      ;;
  esac

  i=0
  while [ "$i" -lt "${#VAL_FIELDS[@]}" ]; do
    typed="$(coerce_value "$category" "${VAL_FIELDS[$i]}" "${VAL_RAWS[$i]}")"
    base_values="$(jq -c --arg f "${VAL_FIELDS[$i]}" --argjson v "$typed" '.[$f] = $v' <<<"$base_values")"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#UNSET_FIELDS[@]}" ]; do
    base_values="$(jq -c --arg f "${UNSET_FIELDS[$i]}" 'del(.[$f])' <<<"$base_values")"
    i=$((i + 1))
  done

  [ "$HAVE_SUMMARY" -eq 1 ] || SUMMARY="$summary_default"
  entry="$(jq -n -c --arg s "$SOURCE" --arg p "$PRESET_ID" --arg m "$SUMMARY" --argjson v "$base_values" \
    '{source: $s} + (if $s == "preset" then {preset: $p} else {} end) + {summary: $m, values: $v}')"
  if [ "$HAVE_STRENGTH" -eq 1 ]; then
    entry="$(jq -c --arg v "$STRENGTH" '.strength = $v' <<<"$entry")"
  fi

  cand="$(mktemp "$DRAFT.XXXXXX")" || die 1 "cannot create a temp file next to the draft"
  TMP_FILES="$TMP_FILES $cand"
  jq --arg c "$category" --argjson e "$entry" '.categories[$c] = $e' "$DRAFT" >"$cand.raw" || die 1 "internal error building the candidate"
  TMP_FILES="$TMP_FILES $cand.raw"
  publish_draft_candidate "$cand.raw"
  normalize_doc "$cand.raw" >"$cand"
  before="$(jq -c . "$DRAFT")"
  after="$(jq -c . "$cand")"
  mv -f "$cand" "$DRAFT" || die 1 "cannot update the draft"
  rm -f "$cand.raw"
  new_doc="$(jq -n -c --arg c "$category" --arg d "$DRAFT" --argjson ch "$([ "$before" = "$after" ] && echo false || echo true)" \
    '{ok: true, action: "draft-set", category: $c, draft: $d, changed: $ch}')"
  printf '%s\n' "$new_doc"
}

cmd_draft_skip() {
  local category before after cand
  parse_draft_opts "$@"
  [ "$NPOS" -eq 1 ] || die_usage "draft-skip needs a category id"
  category="$POS1"
  require_draft
  category_known "$category"
  cand="$(mktemp "$DRAFT.XXXXXX")" || die 1 "cannot create a temp file next to the draft"
  TMP_FILES="$TMP_FILES $cand"
  jq --arg c "$category" 'del(.categories[$c])' "$DRAFT" >"$cand" || die 1 "internal error building the candidate"
  before="$(jq -c . "$DRAFT")"
  after="$(jq -c . "$cand")"
  if [ "$before" != "$after" ]; then
    mv -f "$cand" "$DRAFT" || die 1 "cannot update the draft"
  fi
  jq -n -c --arg c "$category" --arg d "$DRAFT" --argjson ch "$([ "$before" = "$after" ] && echo false || echo true)" \
    '{ok: true, action: "draft-skip", category: $c, draft: $d, changed: $ch}'
}

cmd_draft_show() {
  parse_draft_opts "$@"
  [ "$NPOS" -eq 0 ] || die_usage "draft-show: unexpected argument: $POS1"
  require_draft
  if [ "$HAVE_CATEGORY_OPT" -eq 1 ]; then
    jq -e --arg c "$CATEGORY_OPT" '.categories[$c] // empty' "$DRAFT" ||
      die 1 "category \"$CATEGORY_OPT\" is not in the draft"
    return 0
  fi
  cat "$DRAFT"
}

cmd_draft_diff() {
  local live
  parse_draft_opts "$@"
  [ "$NPOS" -eq 0 ] || die_usage "draft-diff: unexpected argument: $POS1"
  [ -n "$FORMAT" ] || FORMAT="json"
  case "$FORMAT" in
    json | text) ;;
    *) die_usage "--format must be json or text (got: $FORMAT)" ;;
  esac
  require_draft
  resolve_instance
  live="$INSTANCE"
  if [ -f "$INSTANCE" ]; then
    jq -e 'type == "object"' "$INSTANCE" >/dev/null 2>&1 || die 4 "$INSTANCE: not a parseable JSON object; fix it by hand first"
  else
    live="$(mktemp "${TMPDIR:-/tmp}/conventions-entry-live.XXXXXX")" || die 1 "cannot create a temp file"
    TMP_FILES="$TMP_FILES $live"
    printf '%s\n' "$SKELETON" >"$live"
  fi
  jq -n -r --arg fmt "$FORMAT" --slurpfile live "$live" --slurpfile draft "$DRAFT" --slurpfile s "$SCHEMA" '
    [ $s[0].categories | to_entries[]
      | .key as $id | .value.label as $label
      | ($live[0].categories[$id]) as $b | ($draft[0].categories[$id]) as $a
      | select($a != null or $b != null)
      | {id: $id, label: ($label // $id),
         status: (if $b == null then "added" elif $a == null then "removed" elif $a == $b then "unchanged" else "changed" end),
         before: $b, after: $a} ] as $cats
    | if $fmt == "json" then
        {added: [$cats[] | select(.status == "added") | .id],
         removed: [$cats[] | select(.status == "removed") | .id],
         changed: [$cats[] | select(.status == "changed") | .id],
         unchanged: [$cats[] | select(.status == "unchanged") | .id],
         categories: $cats}
      else
        ($cats[] | (if .status == "added" then "+ \(.id): \(.after.summary)"
                    elif .status == "removed" then "- \(.id): \(.before.summary) (removed)"
                    elif .status == "changed" then "~ \(.id): \(.before.summary) -> \(.after.summary)"
                    else "= \(.id): \(.after.summary)" end))
      end'
}

# --- commit ----------------------------------------------------------------------------------------------

BAK_INSTANCE=""
BAK_REGISTRY=""
HAD_INSTANCE=0
HAD_REGISTRY=0
REGISTRY=""
ROLLBACK_ARMED=0

# rollback: puts the instance and the registry back exactly as they were before the commit started.
rollback() {
  ROLLBACK_ARMED=0
  if [ "$HAD_INSTANCE" -eq 1 ] && [ -n "$BAK_INSTANCE" ] && [ -f "$BAK_INSTANCE" ]; then
    mv -f "$BAK_INSTANCE" "$INSTANCE"
  elif [ "$HAD_INSTANCE" -eq 0 ]; then
    rm -f "$INSTANCE"
  fi
  if [ "$HAD_REGISTRY" -eq 1 ] && [ -n "$BAK_REGISTRY" ] && [ -f "$BAK_REGISTRY" ]; then
    mv -f "$BAK_REGISTRY" "$REGISTRY"
  elif [ "$HAD_REGISTRY" -eq 0 ]; then
    rm -f "$REGISTRY"
  fi
}

# cmd_commit_locked: the critical section, run by with-lock.sh. Exit codes: 0 ok, 1 internal, 4 validation, 7 generator.
cmd_commit_locked() {
  local dir cand reason gen_out gen_err out changed=true cats
  parse_draft_opts "$@"
  require_draft
  resolve_instance
  dir="$(dirname "$INSTANCE")"
  REGISTRY="$dir/checklists.json"
  mkdir -p "$dir" || die 1 "cannot create directory: $dir"

  cand="$(mktemp "$dir/.conventions-entry.XXXXXX")" || die 1 "cannot create a temp file in $dir"
  TMP_FILES="$TMP_FILES $cand"
  normalize_doc "$DRAFT" >"$cand" || die 1 "internal error normalising the draft"
  if [ -f "$INSTANCE" ]; then
    HAD_INSTANCE=1
    BAK_INSTANCE="$dir/.conventions-entry.bak.$$"
    cp -p "$INSTANCE" "$BAK_INSTANCE" || die 1 "cannot back up $INSTANCE"
    TMP_FILES="$TMP_FILES $BAK_INSTANCE"
    if [ "$(jq -c . "$INSTANCE" 2>/dev/null)" = "$(jq -c . "$cand")" ]; then
      changed=false
    fi
  fi
  if [ -f "$REGISTRY" ]; then
    HAD_REGISTRY=1
    BAK_REGISTRY="$dir/.conventions-entry.reg.bak.$$"
    cp -p "$REGISTRY" "$BAK_REGISTRY" || die 1 "cannot back up $REGISTRY"
    TMP_FILES="$TMP_FILES $BAK_REGISTRY"
  fi

  # Step 2: atomic replace. The trap restores both files on any exit between here and the success line.
  ROLLBACK_ARMED=1
  if [ "$changed" = "true" ]; then
    mv -f "$cand" "$INSTANCE" || die 1 "cannot replace $INSTANCE"
  else
    rm -f "$cand"
  fi

  # Step 3: generate the managed conv- checklist items.
  gen_err="$(mktemp "${TMPDIR:-/tmp}/conventions-entry-gen.XXXXXX")" || die 1 "cannot create a temp file"
  TMP_FILES="$TMP_FILES $gen_err"
  if ! gen_out="$(bash "$GENERATOR" --conventions "$INSTANCE" 2>"$gen_err")"; then
    cat "$gen_err" >&2
    rollback
    die 7 "the checklist generator failed; the previous conventions.json and checklists.json were restored and nothing was recorded. The draft was kept."
  fi

  # Step 4: self-validate both files.
  reason="$(validator_reason "$INSTANCE")"
  if [ -n "$reason" ]; then
    printf '%s: %s\n' "$INSTANCE" "$reason" >&2
    rollback
    die 4 "the written conventions.json failed validation; the previous files were restored. The draft was kept."
  fi
  if [ -f "$REGISTRY" ]; then
    if ! out="$(bash "$CHECKLIST_VALIDATOR" "$REGISTRY" 2>&1 >/dev/null)"; then
      printf '%s\n' "$out" >&2
      rollback
      die 4 "the resulting checklists.json failed validation; the previous files were restored. The draft was kept."
    fi
  fi

  ROLLBACK_ARMED=0
  cats="$(jq '.categories | length' "$INSTANCE")"
  jq -n -c --arg p "$INSTANCE" --arg r "$REGISTRY" --arg g "$gen_out" --argjson ch "$changed" --argjson n "$cats" \
    '{ok: true, action: "commit", path: $p, registry: $r, changed: $ch, categories: $n, generator: $g}'
}

cmd_commit() {
  local reason bad rc
  parse_draft_opts "$@"
  [ "$NPOS" -eq 0 ] || die_usage "commit: unexpected argument: $POS1"
  require_draft
  resolve_instance
  # Step 1: validate the draft before any lock or write.
  reason="$(validator_reason "$DRAFT")"
  if [ -n "$reason" ]; then
    printf '%s: %s\n' "$DRAFT" "$reason" >&2
    die 4 "the draft is not valid; nothing was written. Fix the answers (draft-set) and commit again."
  fi
  bad="$(placeholder_report "$DRAFT" | tr '\n' ' ')"
  if [ -n "$bad" ]; then
    die 4 "the draft still holds an unreplaced placeholder in ${bad% }; nothing was written. Supply the real value (draft-set --value) or drop the field (--unset)."
  fi
  mkdir -p "$(dirname "$INSTANCE")" || die 1 "cannot create directory: $(dirname "$INSTANCE")"
  bash "$WITH_LOCK" "$INSTANCE" -- bash "$SELF_PATH" _commit-locked --draft "$DRAFT"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$DRAFT" "$DRAFT.detect.json"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    die 6 "could not acquire the lock on $INSTANCE; nothing was written. The draft was kept; retry shortly."
  fi
  exit "$rc"
}

# --- dispatch --------------------------------------------------------------------------------------------

[ "$#" -ge 1 ] || die_usage "a subcommand is required"

SUB="$1"
shift

case "$SUB" in
  -h | --help | help)
    print_contract
    exit 0
    ;;
  path) cmd_path "$@" ;;
  show) cmd_show "$@" ;;
  categories) cmd_categories "$@" ;;
  detect) cmd_detect "$@" ;;
  presets) cmd_presets "$@" ;;
  check) cmd_check "$@" ;;
  draft-init) cmd_draft_init "$@" ;;
  draft-set) cmd_draft_set "$@" ;;
  draft-skip) cmd_draft_skip "$@" ;;
  draft-show) cmd_draft_show "$@" ;;
  draft-diff) cmd_draft_diff "$@" ;;
  commit) cmd_commit "$@" ;;
  _commit-locked) cmd_commit_locked "$@" ;;
  *) die_usage "unknown subcommand: $SUB" ;;
esac

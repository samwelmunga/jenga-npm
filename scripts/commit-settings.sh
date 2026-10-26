#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/commit-settings.sh - the one place that decides whether a project is opted in to the commit-format
# convention and what its effective commit settings are
#
# Every consumer (the conventions digest, the commit composer, the subject check, the reconcile and close-story
# readers) asks this script instead of reading conventions.json itself, so the opt-in rule and the defaults exist
# exactly once. It is read-only: it writes no file and changes no config, board or git state.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   commit-settings.sh [--conventions <file>] opted-in
#   commit-settings.sh [--conventions <file>] show
#   commit-settings.sh default <field>
#   commit-settings.sh -h | --help       print this usage on stdout, exit 0
#
#   opted-in   exit 0 when the project is opted in, 1 when it is not. Prints nothing.
#   show       prints nothing and exits 0 when the project is not opted in. When it is opted in, prints one
#              key=value line per effective setting, in this fixed order:
#                template  ref_source  ref_pattern  on_unresolved  trace_mode  trailer_key  subject_max_length
#              Each value is the one the project recorded or, when it recorded none, the default of that schema
#              field. The defaults are read from the schema at run time; this script holds no copy of them, so a
#              changed schema default is a changed effective value with no edit here. One setting has no schema
#              default, subject_max_length: its field spec must stay as it is, so when it is not recorded the
#              value is the budget scripts/commit-template.sh itself derives with (read from that script, never
#              copied here). trace_mode and trailer_key come from the opt-in trace category; a project that opted
#              in without recording that category therefore gets the schema defaults for both.
#
# OPTED IN means: conventions.json records the commit-format category with a non-empty string `template` and
# `apply_to_board_commits` equal to true. Nothing else opts a project in: a template without the flag, the flag
# without a template, or a trace entry on its own is "not opted in". An absent file, an unresolvable configs path,
# an empty `categories` or no such entry is also "not opted in", silently: that is the legacy path.
#
#   default    prints the schema's default for <field> (any field of any category, found by the field name alone),
#              whether or not the project is opted in, and reads no conventions file. It exists so a caller that must
#              work for a project that has not opted in (the commit ref gate) can still read a schema default through
#              this script instead of holding a copy of it. Exit 3 when the schema declares no such field or the field
#              has no default. <field> is only ever passed to jq with --arg.
#
# The two categories are found by the schema field they declare (the one declaring `template`, the one declaring
# `trailer_key`), never by a category id written in this script.
#
# CONVENTIONS FILE: --conventions <file> wins; otherwise "<configs>/conventions.json", with <configs> located through
# scripts/resolve-root.sh get configs (JENGA_PROJECT_ROOT is honoured), exactly as scripts/conventions-digest.sh does.
# The schema is templates/conventions-schema.json relative to this script, or JENGA_CONVENTIONS_SCHEMA (tests);
# scripts/validate-conventions.sh reads the same variable.
#
# READING THE OUTPUT: the values are data. Callers must read them with `read` (split at the FIRST "=") or with jq,
# and must never `source` or evaluate the output. A value never contains a newline (the validator rejects those
# for every field printed here).
#
# EXIT CODES
#   0  opted in (opted-in), or show finished (including "not opted in", which prints nothing)
#   1  not opted in (opted-in only)
#   2  usage error
#   3  the conventions file exists but is invalid or unreadable (the validator's lines go to stderr), or the
#      schema cannot supply a setting (default: no such field, or no default); jq is missing while there is a file
#      to read (or, for default, always)
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). The conventions
# file is validated first by scripts/validate-conventions.sh.
# ---------------------------------------------------------------------------

set -u

SELF="$(basename "$0")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$here/../templates/conventions-schema.json}"

usage() {
  cat <<'EOF'
Usage:
  commit-settings.sh [--conventions <file>] opted-in
  commit-settings.sh [--conventions <file>] show
  commit-settings.sh default <field>
  commit-settings.sh -h | --help
EOF
}

usage_error() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  usage >&2
  exit 2
}

conv=""
sub=""
dfield=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --conventions)
      [ "$#" -ge 2 ] || usage_error "--conventions needs a file"
      [ -z "$conv" ] || usage_error "--conventions may be given once"
      conv="$2"
      shift 2
      ;;
    opted-in|show)
      [ -z "$sub" ] || usage_error "only one subcommand may be given"
      sub="$1"
      shift
      ;;
    default)
      [ -z "$sub" ] || usage_error "only one subcommand may be given"
      [ "$#" -ge 2 ] || usage_error "default needs a field name"
      sub="default"
      dfield="$2"
      shift 2
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      usage_error "unknown subcommand: $1 (opted-in, show or default)"
      ;;
  esac
done
[ -n "$sub" ] || usage_error "a subcommand is required (opted-in, show or default)"

# default: a schema lookup only. It needs no conventions file, so it runs before the file is located.
if [ "$sub" = "default" ]; then
  [ -z "$conv" ] || usage_error "default reads the schema only; --conventions does not apply"
  command -v jq >/dev/null 2>&1 || { printf '%s: jq is required but was not found on PATH\n' "$SELF" >&2; exit 3; }
  dval="$(jq -r --arg f "$dfield" '
    ((.categories // {}) + (.opt_in_categories // {}))
    | [ to_entries[] | (.value.values // {}) | select(has($f)) | .[$f].default | select(. != null) ]
    | if length > 0 then .[0] else empty end' "$SCHEMA" 2>/dev/null)" || {
    printf '%s: cannot read the schema: %s\n' "$SELF" "$SCHEMA" >&2
    exit 3
  }
  if [ -z "$dval" ]; then
    printf '%s: the schema declares no default for field: %s\n' "$SELF" "$dfield" >&2
    exit 3
  fi
  printf '%s\n' "$dval"
  exit 0
fi

# not_opted_in: the legacy path. Silent for both subcommands.
not_opted_in() {
  if [ "$sub" = "opted-in" ]; then exit 1; fi
  exit 0
}

# Locate the file. Anything that means "no conventions recorded" is "not opted in".
if [ -z "$conv" ]; then
  cfg="$(bash "$here/resolve-root.sh" get configs 2>/dev/null)" || not_opted_in
  [ -n "$cfg" ] || not_opted_in
  conv="$cfg/conventions.json"
fi
[ -f "$conv" ] || not_opted_in

command -v jq >/dev/null 2>&1 || { printf '%s: jq is required but was not found on PATH\n' "$SELF" >&2; exit 3; }

# Validate first. The validator's problem lines are the user-facing message; its PASS/FAIL line is not needed.
verr="$(bash "$here/validate-conventions.sh" "$conv" 2>&1 >/dev/null)"
vrc=$?
if [ "$vrc" -ne 0 ]; then
  [ -z "$verr" ] || printf '%s\n' "$verr" >&2
  printf '%s: conventions file is invalid or unreadable: %s\n' "$SELF" "$conv" >&2
  exit 3
fi

# The category that declares `field`, found in the schema (core or opt-in categories); empty when none does.
category_with_field() {
  jq -r --arg f "$1" '
    ((.categories // {}) + (.opt_in_categories // {}))
    | to_entries
    | map(select((.value.values // {}) | has($f)))
    | (.[0].key // empty)' "$SCHEMA"
}

fmt_cat="$(category_with_field template)" || { printf '%s: cannot read the schema: %s\n' "$SELF" "$SCHEMA" >&2; exit 3; }
trace_cat="$(category_with_field trailer_key)" || { printf '%s: cannot read the schema: %s\n' "$SELF" "$SCHEMA" >&2; exit 3; }

# A schema that declares no template field cannot opt anyone in.
[ -n "$fmt_cat" ] || not_opted_in

opted="$(jq -r --arg id "$fmt_cat" '
  ((.categories // {})[$id].values // {}) as $v
  | (($v.template | type) == "string" and ($v.template | length) > 0 and $v.apply_to_board_commits == true)' "$conv")" || {
  printf '%s: could not read %s\n' "$SELF" "$conv" >&2
  exit 3
}

if [ "$opted" != "true" ]; then
  not_opted_in
fi

if [ "$sub" = "opted-in" ]; then
  exit 0
fi

# show: recorded value, else the schema field's default. A setting with neither is reported as a line that starts
# with "!" so the shell can fail loudly instead of printing a hole.
lines="$(jq -r --slurpfile schema "$SCHEMA" --arg fmt "$fmt_cat" --arg trace "$trace_cat" '
  (($schema[0].categories // {}) + ($schema[0].opt_in_categories // {})) as $specs
  | (.categories // {}) as $c
  | def eff($cat; $field):
      (($c[$cat].values // {})[$field]) // (($specs[$cat].values // {})[$field].default);
  [ ["template", $fmt, "template"],
    ["ref_source", $fmt, "ref_source"],
    ["ref_pattern", $fmt, "ref_pattern"],
    ["on_unresolved", $fmt, "on_unresolved"],
    ["trace_mode", $trace, "mode"],
    ["trailer_key", $trace, "trailer_key"],
    ["subject_max_length", $fmt, "subject_max_length"] ]
  | .[]
  | . as [$key, $cat, $field]
  | eff($cat; $field) as $v
  | if $v == null then (if $key == "subject_max_length" then "~\($key)" else "!\($key)" end) else "\($key)=\($v)" end' "$conv")" || {
  printf '%s: could not read %s\n' "$SELF" "$conv" >&2
  exit 3
}

# The one setting with no schema default: ask the template script what budget it derives with when none is given.
# A template that is only {summary} has no prefix, so max_summary_length is exactly that budget.
if printf '%s\n' "$lines" | grep -q '^~subject_max_length$'; then
  budget="$(bash "$here/commit-template.sh" derive '{summary}' 2>/dev/null | sed -n 's/^max_summary_length=//p')"
  case "$budget" in
    ''|*[!0-9]*)
      printf '%s: cannot read the default subject length from commit-template.sh\n' "$SELF" >&2
      exit 3
      ;;
  esac
  lines="$(printf '%s\n' "$lines" | sed "s/^~subject_max_length\$/subject_max_length=$budget/")"
fi

if printf '%s\n' "$lines" | grep -q '^!'; then
  missing="$(printf '%s\n' "$lines" | grep '^!' | sed 's/^!//' | tr '\n' ' ')"
  printf '%s: no recorded value and no schema default for: %s\n' "$SELF" "$missing" >&2
  exit 3
fi

printf '%s\n' "$lines"
exit 0

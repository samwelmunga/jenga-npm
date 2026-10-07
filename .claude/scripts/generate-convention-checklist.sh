#!/usr/bin/env bash
# generate-convention-checklist.sh - turn a project's conventions.json into pre-flight checklist items (E69_S03)
#
# Stage 1 (E69_S03_T03): the pure renderer. `--print` renders conventions.json into registry items on stdout and
# touches nothing. Stage 2 (E69_S03_T04): the default invocation merges those items into the project registry,
# seeding it if needed, and writes it atomically; `--check` reports whether a run would change it.
#
# Usage:
#   scripts/generate-convention-checklist.sh [--conventions <file>]           update <configs>/checklists.json
#   scripts/generate-convention-checklist.sh --check [--conventions <file>]   exit 0 up to date, 1 stale
#   scripts/generate-convention-checklist.sh --print [--conventions <file>]   print the rendered items only
#
# Input: the project's conventions.json (default "<configs>/conventions.json", with <configs> located through
# scripts/resolve-root.sh get configs; JENGA_PROJECT_ROOT is honoured). It is validated with
# scripts/validate-conventions.sh FIRST: an invalid file stops the run with that validator's lines on stderr, exit 1
# and nothing on stdout. A missing file, or one with no recorded category, prints [] and exits 0.
#
# Data: templates/conventions-checklist-map.json, located relative to this script (so it works from a consumer
# install at node_modules/@jenga-ai/agent/). Which item each category produces, at which phase and with which
# strength is data there, not logic here; the map's _comment documents its fields. Category order is the order of
# the keys in templates/conventions-schema.json.
#
# Output: one JSON array on stdout, one item per recorded category, each
#   { "id": "conv-<category>", "text", "situations", "kind", ["verify",] "enforcement", "tick_scope",
#     "provenance": { "source": "convention", "category": "<category-id>" } }
# Output is deterministic (fixed key order, fixed item order, one formatter): two runs print identical bytes. The
# formatter expands objects and keeps arrays of scalars on one line, which is this repository's registry style.
#
# Rendering rules
#   - Variant: the first alternative whose "enabled" is true and whose "requires" values are all recorded replaces
#     the entry's own fields; otherwise the entry's own fields when its "requires" values are all recorded;
#     otherwise its "fallback". An entry with "enabled": false is skipped. A category absent from conventions.json
#     produces no item (removing a stale item is the merge stage's job).
#   - Placeholders, substituted in ONE pass (substituted text is never re-scanned): {summary}; {values.<field>}
#     (text only); {q:summary} / {q:values.<field>} (shell-quoted).
#   - A convention's own "strength" (advisory or confirm, checked by validate-conventions.sh) overrides the map's
#     enforcement for that item.
#
# Strength rule (epic E69, Decision 4): every emitted item is advisory or confirm. If the map or a convention ever
# yields anything else (block included) the run refuses with exit 1 and prints no items. This is defence in depth
# on top of validate-conventions.sh.
#
# verify quoting rule: a user-supplied value reaches a verify command ONLY through {q:...}, which wraps the value in
# single quotes and rewrites every embedded ' as '\'' (the POSIX-safe form). A value can therefore never end the
# quoted word it sits in, so the map's wrapper (for example `bash -c {q:values.lint_command}`) receives it as ONE
# argument. An unquoted {summary} or {values.*} placeholder in a verify_template is refused (exit 1).
#
# Stage 2: the registry (E69_S03_T04)
#   Target: "<configs>/checklists.json" (<configs> from scripts/resolve-root.sh get configs), the PROJECT instance.
#   Never the shipped templates/checklists.json (preflight-checklists.md section 8).
#
#   Managed-item boundary (the contract): an item is managed if and only if its id starts with "conv-" AND its
#   provenance.source is "convention". Only managed items are replaced, added or removed. Every other item
#   (hand-written, source "authored", agent-suggested "suggested", or a conv- id with no or another provenance) is
#   carried through untouched, in its original relative order. If a rendered id collides with a non-managed item
#   the run stops with exit 1 naming the id and changes nothing.
#
#   Placement: managed items go after all non-managed items, in category order. A convention removed from
#   conventions.json removes its conv- item on the next run. "Changed" means the resulting items array differs
#   (content or order) from the live one; when it does not, nothing is written, so a second run is a byte-identical
#   no-op. When it does, the whole file is serialised once by the single formatter, which is also this
#   repository's own registry style, so an existing file in that style is not reformatted.
#
#   Seeding: with no registry file and at least one rendered item, the registry is created from the shipped default
#   (templates/checklists.json, located relative to this script; test seam JENGA_CHECKLISTS_DEFAULT_FILE) PLUS the
#   generated items. The default's items MUST be carried because scripts/checklist.sh selects one whole file and
#   never merges (preflight-checklists.md section 9): an instance holding only conv- items would silently drop them.
#   With no registry and nothing rendered, no file is created ("nothing to do", exit 0).
#
#   Atomic write: runs under scripts/with-lock.sh <registry> -- ... . The merged result is written to a candidate
#   file in the registry's own directory, validated with scripts/validate-checklists.sh, and only on PASS renamed
#   over the registry. On FAIL the candidate is removed, the validator's lines go to stderr, the live file is left
#   byte-identical and the exit code is 1. A registry that fails validation is never left on disk. If the lock
#   cannot be acquired the command is not run: exit 2, nothing written.
#
#   --check never writes and takes no lock. It builds and validates the candidate in a temp directory.
#
#   stdout: one summary line, "conventions checklist: N added, N updated, N removed, N unchanged" (counts of managed
#   items), plus a note when the registry was seeded.
#
# Exit codes: 0 ok / up to date; 1 refused or failed (invalid conventions, map problem, strength rule, id
# collision, invalid candidate, or --check found the registry stale); 2 lock not acquired (from with-lock.sh);
# 3 usage error.
#
# Environment (tests): JENGA_CONVENTIONS_CHECKLIST_MAP reads the map from this file; JENGA_CONVENTIONS_SCHEMA is
# honoured by validate-conventions.sh and read here for the category order; JENGA_CHECKLISTS_DEFAULT_FILE names the
# shipped default used for seeding; WITH_LOCK_* are with-lock.sh's own variables.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). Needs jq and python3.

set -u

SELF="$(basename "$0")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP="${JENGA_CONVENTIONS_CHECKLIST_MAP:-$here/../templates/conventions-checklist-map.json}"
DEFAULT_REGISTRY="${JENGA_CHECKLISTS_DEFAULT_FILE:-$here/../templates/checklists.json}"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$here/../templates/conventions-schema.json}"

die() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s [--print | --check] [--conventions <file>]\n' "$SELF" >&2
}

command -v jq >/dev/null 2>&1 || die "jq is required but was not found on PATH"

# --- jq programs ---------------------------------------------------------------------------------------------

# The single formatter used for everything this script prints or writes.
IFS= read -r -d '' JQ_FMT <<'JQ' || true
def isscalar: type != "array" and type != "object";
def fmt($ind):
  if type == "object" then
    if length == 0 then "{}" else
      "{\n" + ([to_entries[] | $ind + "  " + (.key | tojson) + ": " + (.value | fmt($ind + "  "))] | join(",\n")) + "\n" + $ind + "}"
    end
  elif type == "array" then
    if length == 0 then "[]"
    elif all(.[]; isscalar) then "[" + ([.[] | tojson] | join(", ")) + "]"
    else "[\n" + ([.[] | $ind + "  " + fmt($ind + "  ")] | join(",\n")) + "\n" + $ind + "]" end
  else tojson end;
JQ

IFS= read -r -d '' JQ_RENDER <<'JQ' || true
def scalar($what):
  if type == "string" then .
  elif type == "boolean" or type == "number" then tostring
  else error("unsupported value type for " + $what) end;
def sq: "'" + gsub("'"; "'\\''") + "'";
def has_vals($e): . as $req | all($req[]?; . as $k | ($e.values | has($k)) and (($e.values[$k] | type) != "string" or ($e.values[$k] | test("^\\s*<[^<>]*>\\s*$") | not)));
def subst($e; $verify):
  (if $verify and test("\\{(summary\\}|values\\.)")
     then error("verify_template contains an unquoted placeholder (use {q:values.<field>})")
     else . end)
  | gsub("\\{(?<q>q:)?(?<p>summary|values\\.[A-Za-z0-9_]+)\\}";
      (.q != null) as $quoted
      | .p as $p
      | (if $p == "summary" then $e.summary else $e.values[$p | ltrimstr("values.")] end) as $v
      | (if $v == null then "" else ($v | scalar($p)) end)
      | if $quoted then sq else . end);
def strip_meta: del(.alternatives, .fallback, .requires, .item_id, .enabled);
def fix_kind: if .kind == "judgment" then del(.verify_template) else . end;
def pick($m; $e):
  ([ $m.alternatives[]? | select(.enabled == true and (.requires | has_vals($e))) ] | first) as $alt
  | if $alt != null then (($m | strip_meta) + ($alt | del(.id, .enabled, .note, .requires))) | fix_kind
    elif ($m.requires | has_vals($e)) then ($m | strip_meta) | fix_kind
    elif $m.fallback != null then (($m | strip_meta) + $m.fallback) | fix_kind
    else error("map entry " + $m.item_id + " needs values this convention did not record and has no fallback") end;

($conv[0].categories // {}) as $cats
| [ $order[] | . as $cat
    | select($cats | has($cat))
    | $cats[$cat] as $e
    | ($map[0].categories[$cat]) as $m
    | (if $m == null then error("no map entry for category " + $cat) else . end)
    | select($m.enabled != false)
    | (if $m.item_id != ("conv-" + $cat) then error("map entry for " + $cat + " has item_id " + ($m.item_id | tojson) + ", expected conv-" + $cat) else . end)
    | pick($m; $e) as $v
    | ($e.strength // $v.enforcement) as $strength
    | (if ($strength == "advisory" or $strength == "confirm") then . else error("refusing: " + $m.item_id + " would have enforcement " + ($strength | tojson) + " (only advisory and confirm are allowed)") end)
    | (if ($v.kind != "judgment" and $v.kind != "machine") then error("map entry " + $m.item_id + " has an unknown kind") else . end)
    | { id: $m.item_id,
        text: ($v.text_template | subst($e; false)),
        situations: $v.situations,
        kind: $v.kind }
      + (if $v.kind == "machine"
           then { verify: (if $v.verify_template == null then error("map entry " + $m.item_id + " is a machine item with no verify_template") else ($v.verify_template | subst($e; true)) end) }
           else {} end)
      + { enforcement: $strength,
          tick_scope: $v.tick_scope,
          provenance: { source: "convention", category: $cat } }
  ]
JQ

# --- stage 1: render -----------------------------------------------------------------------------------------

# render_items <conventions-file>: prints the item array on stdout, or a message on stderr and returns 1.
render_items() {
  local conv="$1" order err out

  if [ ! -f "$conv" ]; then
    printf '[]\n'
    return 0
  fi

  # Validate first; its own lines (stderr) are the user-facing message. stdout carries only PASS/FAIL.
  if ! bash "$here/validate-conventions.sh" "$conv" >/dev/null; then
    printf '%s: conventions file is invalid, nothing generated\n' "$SELF" >&2
    return 1
  fi

  [ -f "$MAP" ] || { printf '%s: mapping file not found: %s\n' "$SELF" "$MAP" >&2; return 1; }
  jq -e . "$MAP" >/dev/null 2>&1 || { printf '%s: mapping file is not valid JSON: %s\n' "$SELF" "$MAP" >&2; return 1; }
  order="$(jq -c '.categories | keys_unsorted' "$SCHEMA" 2>/dev/null)" \
    || { printf '%s: cannot read the category list from %s\n' "$SELF" "$SCHEMA" >&2; return 1; }

  err="$(mktemp "${TMPDIR:-/tmp}/gen-conv-err.XXXXXX")" || return 1
  if ! out="$(jq -n -r --slurpfile conv "$conv" --slurpfile map "$MAP" --argjson order "$order" \
      "$JQ_FMT $JQ_RENDER | fmt(\"\")" 2>"$err")"; then
    printf '%s: %s\n' "$SELF" "$(sed -e 's/^jq: error (at [^)]*): //' "$err" | head -1)" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

# --- stage 2: merge, seed, write -----------------------------------------------------------------------------

IFS= read -r -d '' JQ_MERGE <<'JQ' || true
def ismanaged:
  type == "object" and ((.id | type) == "string") and (.id | startswith("conv-"))
  and ((.provenance | type) == "object") and (.provenance.source == "convention");
def owned_ids: map(select(type == "object" and ((.id | type) == "string")) | .id);
(if (type != "object" or ((.items | type) != "array")) then error("registry is not a JSON object with an items array") else . end)
| . as $doc
| $gen[0] as $new
| ($doc.items | map(select(ismanaged))) as $old
| ($doc.items | map(select(ismanaged | not))) as $keep
| ($keep | owned_ids) as $keepids
| [ $new[] | .id | select(. as $i | $keepids | index($i)) ] as $coll
| (if ($coll | length) > 0
     then error("id collision: " + ($coll | join(", ")) + " already exists as an item this generator does not own; nothing changed")
     else . end)
| ($old | map({key: .id, value: .}) | from_entries) as $oldby
| ($new | map(.id)) as $newids
| { candidate: ($doc | .items = ($keep + $new)),
    added: ([$new[] | select($oldby[.id] == null)] | length),
    updated: ([$new[] | select($oldby[.id] != null and $oldby[.id] != .)] | length),
    removed: ([$old[] | select(. as $o | ($newids | index($o.id)) == null)] | length),
    unchanged: ([$new[] | select($oldby[.id] != null and $oldby[.id] == .)] | length),
    changed: ($doc.items != ($keep + $new)) }
JQ

WORK=""
CAND=""
cleanup() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$CAND" ] && rm -f "$CAND"
  return 0
}

# apply_registry <write|check> <conventions-file> <registry>: stage 2. Must run under the registry lock when writing.
apply_registry() {
  local mode="$1" conv="$2" registry="$3"
  local gen n base seeded=0 added updated removed unchanged changed note=""

  gen="$(render_items "$conv")" || return 1
  n="$(printf '%s' "$gen" | jq 'length')" || return 1

  if [ -f "$registry" ]; then
    base="$registry"
  else
    if [ "$n" -eq 0 ]; then
      printf 'conventions checklist: nothing to do (no conventions recorded, no registry created)\n'
      return 0
    fi
    base="$DEFAULT_REGISTRY"
    [ -f "$base" ] || { printf '%s: shipped default registry not found: %s\n' "$SELF" "$base" >&2; return 1; }
    seeded=1
    note=" (registry seeded from the shipped default)"
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/gen-conv.XXXXXX")" || return 1
  trap cleanup EXIT
  printf '%s\n' "$gen" > "$WORK/gen.json"

  if ! jq -c --slurpfile gen "$WORK/gen.json" "$JQ_MERGE" "$base" > "$WORK/stats.json" 2> "$WORK/err"; then
    if ! jq -e . "$base" >/dev/null 2>&1; then
      bash "$here/validate-checklists.sh" "$base" >/dev/null
      printf '%s: the registry is not valid JSON, nothing changed\n' "$SELF" >&2
    else
      printf '%s: %s\n' "$SELF" "$(sed -e 's/^jq: error (at [^)]*): //' "$WORK/err" | head -1)" >&2
    fi
    return 1
  fi

  IFS=$'\t' read -r added updated removed unchanged changed < <(jq -r '[.added, .updated, .removed, .unchanged, .changed] | @tsv' "$WORK/stats.json")
  local summary
  summary="conventions checklist: $added added, $updated updated, $removed removed, $unchanged unchanged$note"

  if [ "$seeded" -eq 0 ] && [ "$changed" != "true" ]; then
    printf '%s\n' "$summary"
    return 0
  fi

  # Candidate: beside the registry for a write (so the final rename is atomic), in the temp dir for --check.
  local cand
  if [ "$mode" = "write" ]; then
    CAND="$registry.candidate.$$"
    cand="$CAND"
  else
    cand="$WORK/candidate.json"
  fi
  jq -r "$JQ_FMT .candidate | fmt(\"\")" "$WORK/stats.json" > "$cand" || return 1
  printf '\n' >> "$cand"

  if ! bash "$here/validate-checklists.sh" "$cand" >/dev/null; then
    printf '%s: the merged registry failed validation; the live registry was not touched\n' "$SELF" >&2
    return 1
  fi

  if [ "$mode" = "check" ]; then
    printf '%s (stale: a run would change %s)\n' "$summary" "$registry"
    return 1
  fi

  mv -f "$cand" "$registry" || { printf '%s: could not replace %s\n' "$SELF" "$registry" >&2; return 1; }
  CAND=""
  printf '%s\n' "$summary"
}

# --- argument parsing and dispatch ---------------------------------------------------------------------------

mode=""
conv_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) [ -z "$mode" ] || { usage; exit 3; }; mode="print" ;;
    --check) [ -z "$mode" ] || { usage; exit 3; }; mode="check" ;;
    --apply-locked) [ -z "$mode" ] || { usage; exit 3; }; mode="apply" ;;  # internal: the body run under the lock
    --conventions)
      [ "$#" -ge 2 ] || { usage; exit 3; }
      conv_file="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s: unknown argument: %s\n' "$SELF" "$1" >&2; usage; exit 3 ;;
  esac
  shift
done

[ -n "$mode" ] || mode="write"

configs="$(bash "$here/resolve-root.sh" get configs)" || die "could not resolve the project configs directory via resolve-root.sh"
[ -n "$conv_file" ] || conv_file="$configs/conventions.json"
registry="$configs/checklists.json"

case "$mode" in
  print) render_items "$conv_file" || exit 1 ;;
  check) apply_registry check "$conv_file" "$registry"; exit $? ;;
  apply) apply_registry write "$conv_file" "$registry"; exit $? ;;
  write)
    # The lock file lives beside the registry, so its directory must exist. With no configs directory and no
    # conventions file there is nothing to record: say so without creating anything.
    if [ ! -d "$configs" ]; then
      if [ -f "$conv_file" ]; then
        mkdir -p "$configs" || die "cannot create $configs"
      else
        printf 'conventions checklist: nothing to do (no conventions recorded, no registry created)\n'
        exit 0
      fi
    fi
    exec bash "$here/with-lock.sh" "$registry" -- bash "$here/$SELF" --apply-locked --conventions "$conv_file"
    ;;
esac

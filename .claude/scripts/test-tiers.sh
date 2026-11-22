#!/usr/bin/env bash
################################################################################
# test-tiers.sh - one tier tag per bats file: propose, apply, check, list
# (E95_S02_T01)
#
# Every top-level tests/*.bats file carries exactly one bats file tag naming its
# tier, written as the line
#
#     # bats file_tags=tier:<name>
#
# so that bats 1.14's `--filter-tags tier:<name>` can select by tier. Tiers:
# fast, unit, integration, slow, manual.
#
# Usage:
#   test-tiers.sh propose [--root <dir>]
#   test-tiers.sh apply   [--root <dir>]
#   test-tiers.sh check   [--root <dir>]
#   test-tiers.sh list    (--tier <a>[,<b>...] | --exclude-tier <a>[,<b>...]) [--root <dir>]
#   test-tiers.sh --help
#
# <dir> defaults to the root scripts/resolve-root.sh resolves (the repo root),
# else the current directory. Only <dir>/tests/*.bats is considered (top level,
# not recursive), always in byte (LC_ALL=C) order.
#
# ---------------------------------------------------------------------------
# THE TIER RULE (normative; first matching rule wins)
#
#   1. tier:manual - skills/j-test/scripts/manual-only.sh reports the file
#      manual-only (asked, not re-implemented): it already carries tier:manual
#      (reason `tagged`, E95_S02_T04) or E77_S02's legacy marker
#      `# jenga:manual-only: <reason>` (reason `legacy-marker`).
#      Duration never makes a file manual.
#   2. tier:fast   - the file already carries a written `tier:fast` tag, except
#      the files in FAST_EXCLUDE below (tests/pages-workflow.bats needs PyYAML and
#      failed the E95_S01 measurement), which fall through to rule 3. The tag is
#      the fast tier's only source of truth since E95_S02_T03 retired the
#      E95_S01 list it was first seeded from; an untagged file is never
#      proposed fast (making a file fast is a deliberate hand edit).
#   3. by the latest `scope: file` record for the path in
#      <dir>/project/logs/test-timings.jsonl (latest by `date`, keyed by path,
#      not blob):
#        duration <= UNIT_MAX_MS (30 s)          -> tier:unit
#        duration <= INTEGRATION_MAX_MS (300 s)  -> tier:integration
#        duration >  INTEGRATION_MAX_MS          -> tier:slow
#      A file above manual_only_threshold_seconds (project/configs/
#      test-config.json, default 600) stays tier:slow, with `candidate-manual`
#      in the reason column for a person to decide. Never promoted to manual.
#   4. untimed (no record) -> UNTIMED_DEFAULT_TIER (integration), reason
#      `untimed`: never fast (cost unproven), never slow (slow is measured cost).
#
# ---------------------------------------------------------------------------
# SUBCOMMANDS
#
#   propose  Dry run. One `<path>\ttier:<name>\t<reason>` line per file, where
#            <reason> names the rule that fired and the latest duration_ms (or
#            `untimed`). Writes nothing.
#   apply    Writes the proposal: inserts exactly one tag line after the shebang
#            (line 1 when there is no shebang), before everything else. A file
#            that already has any `tier:` tag is never changed; it is reported as
#            `already-tagged\t<path>\t<tags>`. Ends with one `count\ttier:<name>\t<n>`
#            line per tier written and `count\talready-tagged\t<n>`. Idempotent.
#   check    One `<path>\t<problem>` line per file with a problem, where <problem>
#            is `no-tier`, `multiple-tiers:<a>,<b>`, `unknown-tier:<x>` or
#            `legacy-marker-without-tier-manual`. Exit 1 when any line is
#            printed, 0 otherwise. Machine-readable (E95_S05's lint reuses it).
#   list     Prints the paths whose written tag is in --tier, or not in
#            --exclude-tier (an untagged file counts as "not excluded", so a
#            missing tag never drops a file from a broad run). Runs no bats.
#
# EXIT CODES
#   0  ok   1  check found a problem   2  usage error, missing root/tests dir,
#   unreadable input or a failing helper (jq, manual-only.sh)
#
# READS FILES ONLY, except `apply`, which edits <dir>/tests/*.bats. It never runs
# bats, a test or a package manager. bash 3.2 compatible.
################################################################################

set -u
export LC_ALL=C

SCRIPT_NAME="test-tiers.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---- the rule's constants -------------------------------------------------
UNIT_MAX_MS=30000
INTEGRATION_MAX_MS=300000
UNTIMED_DEFAULT_TIER="integration"
DEFAULT_MANUAL_THRESHOLD_SECONDS=600
FAST_EXCLUDE="tests/pages-workflow.bats"
TIERS="fast unit integration slow manual"
TAG_PREFIX="# bats file_tags="

err() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; }

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed -e '/^set -u/d' -e '/^#\{20,\}$/d' -e 's/^# \{0,1\}//'
}

die_usage() { err "$1"; usage >&2; exit 2; }

is_tier() {
  case " $TIERS " in *" $1 "*) return 0 ;; esac
  return 1
}

# ---- argument parsing -----------------------------------------------------
[ "$#" -ge 1 ] || die_usage "missing subcommand"
CMD="$1"; shift
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  propose|apply|check|list) ;;
  *) die_usage "unknown subcommand: $CMD" ;;
esac

ROOT=""
LIST_MODE=""
LIST_TIERS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || die_usage "--root needs a directory"; ROOT="$2"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --tier|--exclude-tier)
      [ "$CMD" = "list" ] || die_usage "$1 is only valid with list"
      [ -z "$LIST_MODE" ] || die_usage "give one of --tier or --exclude-tier, once"
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "$1 needs a tier list"
      LIST_MODE="$1"; LIST_TIERS="$2"; shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [ "$CMD" = "list" ]; then
  [ -n "$LIST_MODE" ] || die_usage "list needs --tier or --exclude-tier"
  _old_ifs="$IFS"; IFS=','
  for _t in $LIST_TIERS; do
    is_tier "$_t" || { IFS="$_old_ifs"; die_usage "unknown tier: $_t (tiers: $TIERS)"; }
  done
  IFS="$_old_ifs"
fi

if [ -z "$ROOT" ]; then
  ROOT="$("$SCRIPT_DIR/resolve-root.sh" root 2>/dev/null)" || ROOT=""
  [ -n "$ROOT" ] || ROOT="$PWD"
fi
[ -d "$ROOT/tests" ] || { err "no tests/ directory under root: $ROOT"; exit 2; }
ROOT="$(cd -- "$ROOT" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-tiers.XXXXXX")" || { err "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# files: root-relative paths, byte order
( cd "$ROOT" && find tests -maxdepth 1 -type f -name '*.bats' ) | sort > "$TMP/files"

# ---- tag reading ----------------------------------------------------------
# file_tags: writes $TMP/filetags, one `<path>\t<tiers>` line per file in
# $TMP/files (<tiers> comma separated, empty when untagged), in one awk pass.
# Mirrors bats' own reading: a comment line `# bats file_tags=a,b` anywhere.
file_tags() {
  : > "$TMP/tagged"
  if [ -s "$TMP/files" ]; then
    # shellcheck disable=SC2016 # the awk program is single-quoted on purpose
    ( cd "$ROOT" && tr '\n' '\0' < "$TMP/files" | xargs -0 awk '
      FNR == 1 { if (cur != "" && out != "") print cur "\t" out; cur = FILENAME; out = "" }
      /^[[:space:]]*#[[:space:]]*bats[[:space:]]+file_tags=/ {
        line = $0
        sub(/^[[:space:]]*#[[:space:]]*bats[[:space:]]+file_tags=/, "", line)
        n = split(line, parts, ",")
        for (i = 1; i <= n; i++) {
          t = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
          if (t ~ /^tier:/) { sub(/^tier:/, "", t); out = (out == "" ? t : out "," t) }
        }
      }
      END { if (cur != "" && out != "") print cur "\t" out }
    ' ) > "$TMP/tagged" || { err "cannot read tests under $ROOT"; exit 2; }
  fi
  awk -F '\t' 'FILENAME == ARGV[1] { tg[$1] = $2; next } { print $0 "\t" (($0 in tg) ? tg[$0] : "") }' \
    "$TMP/tagged" "$TMP/files" > "$TMP/filetags"
}

# ---- the proposal ---------------------------------------------------------
build_proposal() {
  local log="$ROOT/project/logs/test-timings.jsonl" cfg="$ROOT/project/configs/test-config.json"
  local manual_s="$DEFAULT_MANUAL_THRESHOLD_SECONDS" helper v

  if [ -f "$cfg" ]; then
    v="$(jq -r '.manual_only_threshold_seconds // empty' "$cfg" 2>/dev/null)" || v=""
    case "$v" in ''|*[!0-9]*) ;; *) manual_s="$v" ;; esac
  fi

  : > "$TMP/timings"
  if [ -f "$log" ]; then
    jq -r -s '
      [ .[] | select(type == "object" and .scope == "file" and (.suite | type) == "string"
                     and (.duration_ms | type) == "number") ]
      | group_by(.suite)[] | max_by(.date // "") | [.suite, (.duration_ms | floor | tostring)] | @tsv
    ' "$log" > "$TMP/timings" || { err "cannot read timings log: $log"; exit 2; }
  fi

  # Rule 2's input: the files whose written tag already includes tier:fast.
  file_tags
  awk -F '\t' '("," $2 ",") ~ /,fast,/ { print $1 }' "$TMP/filetags" > "$TMP/fast"

  helper="$SCRIPT_DIR/../skills/j-test/scripts/manual-only.sh"
  [ -f "$helper" ] || { err "missing helper: $helper"; exit 2; }
  bash "$helper" list --root "$ROOT" > "$TMP/manual" || { err "manual-only.sh list failed for $ROOT"; exit 2; }

  awk -F '\t' -v unit_max="$UNIT_MAX_MS" -v int_max="$INTEGRATION_MAX_MS" \
      -v manual_max="$((manual_s * 1000))" -v untimed="$UNTIMED_DEFAULT_TIER" -v fast_excl="$FAST_EXCLUDE" '
    FILENAME == ARGV[1] { dur[$1] = $2; next }
    FILENAME == ARGV[2] { fast[$1] = 1; next }
    FILENAME == ARGV[3] { manual[$1] = ($2 == "tier:manual") ? "tagged" : "legacy-marker"; next }
    {
      p = $0
      d = (p in dur) ? "duration_ms=" dur[p] : "untimed"
      if (p in manual) { print p "\ttier:manual\t" manual[p] " (" d ")"; next }
      excluded = 0
      n = split(fast_excl, ex, " ")
      for (i = 1; i <= n; i++) if (ex[i] == p) excluded = 1
      if ((p in fast) && !excluded) { print p "\ttier:fast\tfast-tag (" d ")"; next }
      note = ((p in fast) && excluded) ? "fast-tag-excluded; " : ""
      if (!(p in dur)) { print p "\ttier:" untimed "\t" note "untimed"; next }
      ms = dur[p] + 0
      if (ms <= unit_max)      print p "\ttier:unit\t" note "duration<=" unit_max/1000 "s (" d ")"
      else if (ms <= int_max)  print p "\ttier:integration\t" note "duration<=" int_max/1000 "s (" d ")"
      else if (ms > manual_max) print p "\ttier:slow\t" note "duration>" int_max/1000 "s candidate-manual>" manual_max/1000 "s (" d ")"
      else                     print p "\ttier:slow\t" note "duration>" int_max/1000 "s (" d ")"
    }
  ' "$TMP/timings" "$TMP/fast" "$TMP/manual" "$TMP/files"
}

# ---- subcommands ----------------------------------------------------------
cmd_propose() { build_proposal; }

cmd_apply() {
  local path tier reason tags f
  build_proposal > "$TMP/proposal" || exit 2
  file_tags
  : > "$TMP/applied"
  : > "$TMP/already"
  # shellcheck disable=SC2034 # reason is read to consume the third column
  while IFS="$(printf '\t')" read -r path tier reason; do
    [ -n "$path" ] || continue
    tags="$(awk -F '\t' -v p="$path" '$1 == p { print $2; exit }' "$TMP/filetags")"
    if [ -n "$tags" ]; then
      printf 'already-tagged\t%s\ttier:%s\n' "$path" "$tags"
      echo "$path" >> "$TMP/already"
      continue
    fi
    f="$ROOT/$path"
    awk -v tag="$TAG_PREFIX$tier" '
      NR == 1 && /^#!/ { print; print tag; done = 1; next }
      NR == 1 { print tag; done = 1 }
      { print }
      END { if (!done) print tag }
    ' "$f" > "$TMP/edit" || { err "cannot rewrite $path"; exit 2; }
    cat "$TMP/edit" > "$f" || { err "cannot write $path"; exit 2; }
    echo "$tier" >> "$TMP/applied"
  done < "$TMP/proposal"
  for t in $TIERS; do
    printf 'count\ttier:%s\t%s\n' "$t" "$(grep -cx "tier:$t" "$TMP/applied")"
  done
  printf 'count\talready-tagged\t%s\n' "$(wc -l < "$TMP/already" | tr -d ' ')"
}

# The loops below start no process per file (E95_S02_T09): on a machine where
# every process start is scanned, one fork per file cost 38-44 s for 408 files.
# `${tags//,/ }` unquoted is split and globbed exactly like the former
# `$(printf '%s\n' "$tags" | tr ',' ' ')`, so the word list is unchanged.

cmd_check() {
  local path tags t found=0 helper n rest field nl manual_paths
  helper="$SCRIPT_DIR/../skills/j-test/scripts/manual-only.sh"
  [ -f "$helper" ] || { err "missing helper: $helper"; exit 2; }
  bash "$helper" list --root "$ROOT" > "$TMP/manual" || { err "manual-only.sh list failed for $ROOT"; exit 2; }
  file_tags
  # The manual-only paths, read once and framed by newlines, so that a quoted
  # `case` pattern is a literal whole-line match (what `grep -qxF` was).
  nl=$'\n'
  manual_paths="$nl$(cut -f1 "$TMP/manual")$nl"
  while IFS="$(printf '\t')" read -r path tags; do
    if [ -z "$tags" ]; then
      printf '%s\tno-tier\n' "$path"; found=1
    else
      # n = the number of non-empty comma-separated fields (what `grep -c .` counted).
      n=0; rest="$tags,"
      while [ -n "$rest" ]; do
        field="${rest%%,*}"; rest="${rest#*,}"
        [ -n "$field" ] && n=$((n + 1))
      done
      if [ "$n" -gt 1 ]; then printf '%s\tmultiple-tiers:%s\n' "$path" "$tags"; found=1; fi
      # shellcheck disable=SC2086 # unquoted on purpose: split like the former $(... | tr ',' ' ')
      for t in ${tags//,/ }; do
        is_tier "$t" || { printf '%s\tunknown-tier:%s\n' "$path" "$t"; found=1; }
      done
    fi
    if case "$manual_paths" in *"$nl$path$nl"*) true ;; *) false ;; esac; then
      case ",$tags," in *,manual,*) ;; *) printf '%s\tlegacy-marker-without-tier-manual\n' "$path"; found=1 ;; esac
    fi
  done < "$TMP/filetags"
  [ "$found" -eq 0 ]
}

cmd_list() {
  local path tags t hit want
  want=",$LIST_TIERS,"
  file_tags
  while IFS="$(printf '\t')" read -r path tags; do
    hit=0
    # shellcheck disable=SC2086 # unquoted on purpose: split like the former $(... | tr ',' ' ')
    for t in ${tags//,/ }; do
      case "$want" in *",$t,"*) hit=1 ;; esac
    done
    if [ "$LIST_MODE" = "--tier" ]; then
      [ "$hit" -eq 1 ] && printf '%s\n' "$path"
    else
      [ "$hit" -eq 0 ] && printf '%s\n' "$path"
    fi
  done < "$TMP/filetags"
  return 0
}

case "$CMD" in
  propose) cmd_propose ;;
  apply)   cmd_apply ;;
  check)   cmd_check ;;
  list)    cmd_list ;;
esac

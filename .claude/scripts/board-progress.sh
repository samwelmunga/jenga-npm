#!/usr/bin/env bash
# scripts/board-progress.sh - status counts per scope for the scrum board, printed as JSON (epic E92, task E92_S01_T02).
#
# Contract: project/documentation/progress-visualisation.md (schema_version 1). Where this script and that document
# disagree, the script wins and the document is corrected in the same change.
#
# Usage:
#   board-progress.sh --epic <id>  [--items] [--root <dir>]
#   board-progress.sh --story <id> [--items] [--root <dir>]
#   board-progress.sh --ids <id>[,<id>...] [--items] [--root <dir>]   (task, story and epic ids, any mix; repeatable)
#   board-progress.sh --all [--items] [--root <dir>]                  (every epic, story and task on the board)
#   board-progress.sh --backlog [--items] [--root <dir>]              (the items queued in project/todo.md, see below)
#   board-progress.sh <scope> --summary [--root <dir>]                (compact plain-text block instead of JSON, see below)
#   board-progress.sh --by-parent [--root <dir>]                      (totals per epic and per story in one pass, see below)
#
# --by-parent (E92_S05_T02): one pass for j.status, which needs a bar for every epic and every story and must not re-read
# the board once per item. Prints {"schema_version":1,"scope":{"type":"by-parent"},"epics":[{"id","level":"stories",
# "totals"}],"stories":[{"id","level":"tasks","totals"}],"warnings":[]}: per epic the totals over its stories (each story
# by its own epic_id), per story the totals over its tasks (each task by its own story_id), in numeric id order, with the
# same totals object and the same status table and denominator rule as every other mode (it reuses the load stage and the
# bucket/total arithmetic; there is no second implementation). An epic with no stories and a story with no tasks are
# listed with all-zero totals; the mode exits 3 only when the board has no epic file at all. It is a scope of its own: it
# cannot be combined with another scope flag, --items or --summary (usage error, exit 2).
#
# --summary (E92_S05_T01): replaces the JSON with a compact plain-text overview, one line per level the scope holds
# (tasks, stories, epics, in that order), built by the same render pass from the same totals and the same status table as
# the JSON, so the two cannot disagree:
#   tasks    8/10 done · 1 in progress · 1 red · 0 pending · ⊘ 2 rejected (not counted)
# done/denominator first, then in_progress, failed and pending always, then ` · N unknown` and the rejected note only
# when greater than 0. The rejected count is a note and is never part of done/denominator. The words in progress, failed,
# unknown and the rejected note come from scripts/lib/progress-labels.sh in the effective language (JENGA_PROGRESS_LANG;
# default en); `done` and `pending` and the level names are fixed words because that library has no key for them. The
# block carries no colour and no ESC byte, and is byte-identical across runs. Warnings follow the block as
# `warning: <kind> <id>: <detail>` lines (control bytes in the detail become `?`). Exit codes are those of the JSON
# mode (empty scope 3, unknown id 2); --items has no meaning here and is ignored.
#
# --backlog (E92_S01_T04): the backlog is everything queued in the real entries of the todo file (JENGA_TODO_FILE, else
# <root>/project/todo.md when --root is given, else project/todo.md): blank, `#` and `<!-- -->` lines dropped (the
# real_entries() filter of todo_manager.sh, mirrored in miniature as render-ranked-list.sh does). The trailing id of
# `<mission title>: <id>` names a task, a story (and its tasks) or an epic (and its stories and tasks). An entry without
# a trailing id is a `todo_unresolved_entry` warning, an id without a board file a `todo_unknown_id` warning.
# Board orphans (`orphan_task`, `orphan_story`) are warned under every scope. No warning changes the exit code.
#
# Exit codes: 0 ok (JSON on stdout, nothing on stderr); 1 internal error; 2 usage error, unknown or malformed id, or
# an unresolvable board; 3 empty scope (valid request, zero items). On every non-zero exit the message goes to stderr
# and stdout stays empty. The script makes no model call, writes no file and no board status, and needs no jq.
#
# How: the three board directories come from one `resolve-root.sh list` call (no project/... path is hardcoded; --root
# is exported as JENGA_PROJECT_ROOT). One awk process reads the frontmatter of every epic, story and task file (the
# file list arrives on its stdin and awk opens the files itself, so 1599 task files are one pass, not 1599 greps),
# indexes the items by a width-normalised key (E01 is E1) and selects the scope by each item's own story_id/epic_id.
# Ids are ordered by board_id_sort (scripts/lib/board-ids.sh). A second awk renders counts, totals, warnings and the
# JSON with printf. Compatible with macOS bash 3.2 and BSD awk.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/board-ids.sh"
if [ ! -f "$LIB" ]; then
  echo "board-progress.sh: shared board-ID library not found: $LIB" >&2
  exit 1
fi
# shellcheck source=lib/board-ids.sh
. "$LIB"

# ==================== STATUS TABLE BEGIN ====================================================================
# The ONE status-to-bucket mapping (section 4 of the contract). One row per status, in the order of
# templates/SCRUM_BOARD_SCHEMA.md "Status Values"; the row order is also the order of "counts" in the JSON.
# Format: <status>|<bucket>. A status not listed here is the "unknown" bucket (counted, warned, never dropped).
# Nothing else in this script maps a status to a bucket.
STATUS_TABLE='Pending|pending
In Progress|in_progress
Passed|done
Passed with remarks|done
Failed|failed
Rejected|rejected
Blocked|failed
Backlog|pending
Done|done
Merged|done
Publicized|done
Privatized|done
Deployed to Stage|done
Deployed to Prod|done'
# ==================== STATUS TABLE END ======================================================================

usage() {
  cat >&2 <<'USAGE'
Usage: board-progress.sh <scope> [--items] [--root <dir>]
       board-progress.sh --by-parent [--root <dir>]
  --epic <id>     one epic: its stories and its tasks
  --story <id>    one story: its tasks
  --ids <list>    explicit ids, comma separated (a space after a comma is fine; the flag may repeat); any mix of
                  task, story and epic ids; each is counted at its own level, duplicates once
  --all           the whole board: epics, stories and tasks
  --backlog       the board items named by the real entries of the todo file (JENGA_TODO_FILE, else project/todo.md)
  --items        also list {id, status} per counted item, in numeric id order
  --summary       print a compact plain-text block (one line per level, then warning lines) instead of JSON
  --by-parent     totals per epic (over its stories) and per story (over its tasks), one pass; no --items or --summary
  --root <dir>    working-file anchor (default: scripts/resolve-root.sh)
Prints JSON (schema_version 1), or with --summary a plain-text block, on stdout. Exit: 0 ok, 1 internal, 2 usage or
unknown id, 3 empty scope.
USAGE
}

die() { # <code> <message>
  printf 'board-progress.sh: %s\n' "$2" >&2
  exit "$1"
}

die_usage() {
  printf 'board-progress.sh: %s\n' "$1" >&2
  usage
  exit 2
}

# ---- arguments --------------------------------------------------------------------------------------------------
SCOPE="" TARGET="" ITEMS=0 SUMMARY=0 ROOT_OVERRIDE="" IDS_FLAGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --epic|--story)
      [ $# -ge 2 ] || die_usage "$1 needs an id argument"
      [ -z "$SCOPE" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and $1)"
      SCOPE="${1#--}"; TARGET="$2"; shift 2 ;;
    --epic=*|--story=*)
      [ -z "$SCOPE" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and ${1%%=*})"
      SCOPE="${1%%=*}"; SCOPE="${SCOPE#--}"; TARGET="${1#*=}"; shift ;;
    --ids|--ids=*)
      if [ "$1" = "--ids" ]; then
        [ $# -ge 2 ] || die_usage "--ids needs an id list argument"
        _v="$2"; shift 2
      else
        _v="${1#*=}"; shift
      fi
      [ -z "$SCOPE" ] || [ "$SCOPE" = "ids" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and --ids)"
      SCOPE="ids"
      IDS_FLAGS="$IDS_FLAGS$_v
" ;;
    --all)
      [ -z "$SCOPE" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and --all)"
      SCOPE="all"; shift ;;
    --backlog)
      [ -z "$SCOPE" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and --backlog)"
      SCOPE="backlog"; shift ;;
    --by-parent)
      [ -z "$SCOPE" ] || die_usage "exactly one scope flag is allowed (got --$SCOPE and --by-parent)"
      SCOPE="by-parent"; shift ;;
    --items) ITEMS=1; shift ;;
    --summary) SUMMARY=1; shift ;;
    --root)
      [ $# -ge 2 ] || die_usage "--root needs a directory argument"
      ROOT_OVERRIDE="$2"; shift 2 ;;
    --root=*) ROOT_OVERRIDE="${1#*=}"; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$SCOPE" ] || die_usage "a scope flag is required (--epic, --story, --ids, --backlog, --all or --by-parent)"
if [ "$SCOPE" = "by-parent" ]; then
  [ "$ITEMS" -eq 0 ] || die_usage "--by-parent cannot be combined with --items"
  [ "$SUMMARY" -eq 0 ] || die_usage "--by-parent cannot be combined with --summary"
fi
case "$SCOPE" in
  epic)  [[ $TARGET =~ $BOARD_ID_EPIC_RE ]]  || die 2 "malformed epic id '$TARGET' (expected E<digits>)" ;;
  story) [[ $TARGET =~ $BOARD_ID_STORY_RE ]] || die 2 "malformed story id '$TARGET' (expected E<digits>_S<digits>)" ;;
  ids)
    # Each --ids value is split on commas and every element is trimmed. A value that is only whitespace is no value at
    # all (so `--ids ""` is an empty list), but an empty element inside a non-empty value (`E1,,E2`, `E1,`) is malformed.
    while IFS= read -r _v; do
      [ -n "${_v//[[:space:]]/}" ] || continue
      _rest="$_v,"
      while [ -n "$_rest" ]; do
        _el="${_rest%%,*}"; _rest="${_rest#*,}"
        _el="${_el#"${_el%%[![:space:]]*}"}"; _el="${_el%"${_el##*[![:space:]]}"}"
        board_id_kind "$_el" >/dev/null \
          || die 2 "malformed id '$_el' (expected E<digits>, E<digits>_S<digits> or E<digits>_S<digits>_T<digits>)"
        TARGET="$TARGET${TARGET:+,}$_el"
      done
    done <<EOF
$IDS_FLAGS
EOF
    [ -n "$TARGET" ] || die 2 "empty --ids list (expected one or more ids)" ;;
esac

# ---- summary labels (only --summary needs them) ----------------------------------------------------------------
SUM_PROG="" SUM_FAIL="" SUM_UNK="" SUM_REJ=""
if [ "$SUMMARY" -eq 1 ]; then
  LABELS_LIB="$SCRIPT_DIR/lib/progress-labels.sh"
  [ -f "$LABELS_LIB" ] || die 1 "shared progress label library not found: $LABELS_LIB"
  # shellcheck source=lib/progress-labels.sh
  . "$LABELS_LIB"
  SUM_PROG="$(progress_label in_progress)" && SUM_FAIL="$(progress_label failed)" \
    && SUM_UNK="$(progress_label unknown)" && SUM_REJ="$(progress_label rejected_note)" \
    || die 1 "cannot resolve the progress labels"
fi

# ---- board directories ------------------------------------------------------------------------------------------
if [ -n "$ROOT_OVERRIDE" ]; then
  JENGA_PROJECT_ROOT="$ROOT_OVERRIDE"
  export JENGA_PROJECT_ROOT
fi
resolved="$(bash "$SCRIPT_DIR/resolve-root.sh" list 2>&1)" \
  || die 2 "cannot resolve the board root: $(printf '%s' "$resolved" | head -n 1)"
EPICS_DIR="" STORIES_DIR="" TASKS_DIR=""
while IFS= read -r _line; do
  case "$_line" in
    epics=*)   EPICS_DIR="${_line#epics=}" ;;
    stories=*) STORIES_DIR="${_line#stories=}" ;;
    tasks=*)   TASKS_DIR="${_line#tasks=}" ;;
  esac
done <<EOF
$resolved
EOF
LIST_DIRS=""
for _d in "$EPICS_DIR" "$STORIES_DIR" "$TASKS_DIR"; do
  if [ -n "$_d" ] && [ -d "$_d" ]; then LIST_DIRS="$LIST_DIRS$_d
"; fi
done
[ -n "$LIST_DIRS" ] || die 2 "unresolvable board: none of the epics, stories or tasks directories exists"

# ---- backlog: the real entries of the todo file ----------------------------------------------------------------
# Output, one line per real entry: `@T<TAB>line<TAB>ID` when the entry ends in an id (`<mission title>: <id>`; any
# width, task, story or epic, upper-cased) and `@U<TAB>line<TAB>text` when it does not. The filter mirrors
# todo_manager.sh's real_entries() (blank lines, `#` lines and `<!-- -->` lines dropped) in miniature, as
# render-ranked-list.sh does, rather than shelling out to a script that hardcodes project/todo.md.
read -r -d '' TODO_AWK <<'AWK'
{ line = $0; sub(/\r$/, "", line) }
line ~ /^[ \t]*$/ { next }
line ~ /^[ \t]*#/ { next }
line ~ /^[ \t]*<!--/ { next }
{
  text = line; sub(/^[ \t]+/, "", text); sub(/[ \t]+$/, "", text); gsub(/\t/, " ", text)
  if (match(text, /:[ \t]*[Ee][0-9]+(_[Ss][0-9]+(_[Tt][0-9]+)?)?$/)) {
    ref = substr(text, RSTART + 1, RLENGTH - 1); sub(/^[ \t]+/, "", ref)
    print "@T\t" NR "\t" toupper(ref)
  } else print "@U\t" NR "\t" text
}
AWK

TODO_RECORDS=""
if [ "$SCOPE" = "backlog" ]; then
  if [ -n "${JENGA_TODO_FILE:-}" ]; then TODO_FILE="$JENGA_TODO_FILE"
  elif [ -n "$ROOT_OVERRIDE" ]; then TODO_FILE="${ROOT_OVERRIDE%/}/project/todo.md"
  else TODO_FILE="project/todo.md"
  fi
  [ -f "$TODO_FILE" ] || die 3 "empty scope: the backlog is empty, the todo file does not exist: $TODO_FILE"
  TODO_RECORDS="$(LC_ALL=C awk "$TODO_AWK" "$TODO_FILE")" \
    || die 1 "failed to read the todo file: $TODO_FILE"
  [ -n "$TODO_RECORDS" ] || die 3 "empty scope: the backlog is empty, the todo file has no real entries: $TODO_FILE"
fi

# ---- load stage: one awk over every item's frontmatter ----------------------------------------------------------
read -r -d '' LOAD_AWK <<'AWK'
function nz(s) { sub(/^0+/, "", s); if (s == "") s = "0"; return s }
# Width-normalised key: E01_S02 and E1_S2 are the same item.
function norm(id,   n, p, r) {
  n = split(id, p, "_")
  r = "E" nz(substr(p[1], 2))
  if (n >= 2) r = r "_S" nz(substr(p[2], 2))
  if (n >= 3) r = r "_T" nz(substr(p[3], 2))
  return r
}
function val(line, klen,   v, a) {
  v = substr(line, klen + 1)
  sub(/^[ \t]+/, "", v)
  sub(/[ \t\r]+$/, "", v)
  if (length(v) >= 2) {
    a = substr(v, 1, 1)
    if ((a == "\"" || a == "'") && substr(v, length(v), 1) == a) v = substr(v, 2, length(v) - 2)
  }
  return v
}
function load(file,   line, n, id, st, sid, eid, base, level, key, i) {
  n = 0; id = ""; st = ""; sid = ""; eid = ""
  while ((getline line < file) > 0) {
    n++
    sub(/\r$/, "", line)
    if (n == 1) { if (line !~ /^---[ \t]*$/) break; continue }
    if (line ~ /^---[ \t]*$/) break
    if (line ~ /^id:/) id = val(line, 3)
    else if (line ~ /^status:/) st = val(line, 7)
    else if (line ~ /^story_id:/) sid = val(line, 9)
    else if (line ~ /^epic_id:/) eid = val(line, 8)
  }
  close(file)
  if (id == "") {
    base = file; sub(/.*\//, "", base)
    if (match(base, /^E[0-9]+(_S[0-9]+(_T[0-9]+)?)?/)) id = substr(base, 1, RLENGTH)
  }
  if (id ~ /^E[0-9]+$/) level = "epic"
  else if (id ~ /^E[0-9]+_S[0-9]+$/) level = "story"
  else if (id ~ /^E[0-9]+_S[0-9]+_T[0-9]+$/) level = "task"
  else return
  if (level == "task" && sid == "") { i = index(id, "_T"); sid = substr(id, 1, i - 1) }
  if (level != "epic" && eid == "") { i = index(id, "_S"); eid = substr(id, 1, i - 1) }
  key = norm(id)
  if (key in lv) { if (file >= fl[key]) return }
  lv[key] = level; iid[key] = id; stat[key] = st; fl[key] = file
  rs[key] = sid; re[key] = eid
  ps[key] = (sid ~ /^E[0-9]+_S[0-9]+$/) ? norm(sid) : ""
  pe[key] = (eid ~ /^E[0-9]+$/) ? norm(eid) : ""
}
function fail(code, msg) { print "E\t" code "\t" msg; failed = 1; exit }
# The 5th field is the id of the item's parent (a story's epic, a task's story) when that parent has a board file at the
# right level, else empty; only the by-parent render reads it.
function member(k,   d, par) {
  par = ""
  if (lv[k] == "task" && (ps[k] in lv) && lv[ps[k]] == "story") par = iid[ps[k]]
  else if (lv[k] == "story" && (pe[k] in lv) && lv[pe[k]] == "epic") par = iid[pe[k]]
  print "M\t" lv[k] "\t" iid[k] "\t" stat[k] "\t" par
  count++
  if (lv[k] == "task") {
    d = ""
    if (!(ps[k] in lv) || lv[ps[k]] != "story") d = "story " (rs[k] == "" ? "(none)" : rs[k]) " has no board file"
    if (!(pe[k] in lv) || lv[pe[k]] != "epic") d = d (d == "" ? "" : "; ") "epic " (re[k] == "" ? "(none)" : re[k]) " has no board file"
    if (d != "") print "W\torphan_task\t" iid[k] "\t" d
  } else if (lv[k] == "story") {
    if (!(pe[k] in lv) || lv[pe[k]] != "epic")
      print "W\torphan_story\t" iid[k] "\tepic " (re[k] == "" ? "(none)" : re[k]) " has no board file"
  }
}
index($0, "@T\t") == 1 { split($0, tf, "\t"); tn++; tline[tn] = tf[2]; tref[tn] = tf[3]; next }
index($0, "@U\t") == 1 { split($0, uf, "\t"); un++; ulnum[un] = uf[2]; uline[un] = uf[3]; next }
{ load($0) }
# One backlog entry ref: resolve it against the index (task -> itself; story -> itself and its tasks; epic -> itself,
# its stories and its tasks, membership by each child's own ids). Prints the member lines, once per item.
function resolve_ref(id, ln,   k, want, j) {
  k = norm(id)
  want = (id ~ /^E[0-9]+$/) ? "epic" : ((id ~ /_T[0-9]+$/) ? "task" : "story")
  if (!(k in lv) || lv[k] != want) {
    if (!(k in unk)) {
      unk[k] = 1
      print "W\ttodo_unknown_id\t" id "\tno " want " file carries this id (todo line " ln ")"
      orph[++no] = "line " ln " " id " (no board file)"
    }
    return
  }
  if (!(k in seen)) { seen[k] = 1; member(k) }
  if (want == "story") {
    for (j in lv) if (lv[j] == "task" && ps[j] == k && !(j in seen)) { seen[j] = 1; member(j) }
  } else if (want == "epic") {
    for (j in lv) if ((lv[j] == "story" || lv[j] == "task") && pe[j] == k && !(j in seen)) { seen[j] = 1; member(j) }
  }
}
END {
  if (failed) exit
  t = norm(target)
  if (scope == "epic") {
    if (!(t in lv) || lv[t] != "epic") fail(2, "unknown epic id: " target)
    for (k in lv) if ((lv[k] == "story" || lv[k] == "task") && pe[k] == t) member(k)
  } else if (scope == "story") {
    if (!(t in lv) || lv[t] != "story") fail(2, "unknown story id: " target)
    for (k in lv) if (lv[k] == "task" && ps[k] == t) member(k)
  } else if (scope == "ids") {
    # Validate every id before the first member line is printed, so an unknown id leaves no partial output.
    n = split(target, tl, ",")
    for (i = 1; i <= n; i++) {
      id = tl[i]
      want = (id ~ /^E[0-9]+$/) ? "epic" : ((id ~ /_T[0-9]+$/) ? "task" : "story")
      k = norm(id)
      if (!(k in lv) || lv[k] != want) fail(2, "unknown id: " id)
    }
    for (i = 1; i <= n; i++) { k = norm(tl[i]); if (!(k in seen)) { seen[k] = 1; member(k) } }
  } else if (scope == "all") {
    for (k in lv) member(k)
  } else if (scope == "by-parent") {
    for (k in lv) { member(k); if (lv[k] == "epic") ne++ }
    if (ne == 0) fail(3, "empty scope: the board has no epic")
  } else if (scope == "backlog") {
    # Orphans first (so they are known when the scope turns out empty), then the members. Unresolved entries are
    # reported in line order, unknown ids at their first mention.
    for (i = 1; i <= un; i++) {
      print "W\ttodo_unresolved_entry\t\tline " ulnum[i] ": " uline[i] " (no trailing id)"
      orph[++no] = "line " ulnum[i] " '" uline[i] "' (no trailing id)"
    }
    for (i = 1; i <= tn; i++) resolve_ref(tref[i], tline[i])
  }
  if (count == 0) {
    if (scope == "backlog") {
      msg = "empty scope: no entry of the todo file resolves to a board item"
      for (i = 1; i <= no; i++) msg = msg (i == 1 ? "; orphans: " : "; ") orph[i]
      fail(3, msg)
    }
    if (scope == "all") fail(3, "empty scope: the board has no items")
    fail(3, "empty scope: " scope " " target " has no " (scope == "epic" ? "stories or tasks" : "tasks"))
  }
}
AWK

# ---- render stage: counts, totals, warnings, JSON ---------------------------------------------------------------
read -r -d '' RENDER_AWK <<'AWK'
function jesc(s,   i, c, o) {
  if (s in jcache) return jcache[s]
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") o = o "\\\\"
    else if (c == "\"") o = o "\\\""
    else if (c == "\t") o = o "\\t"
    else if (c < " ") o = o "?"
    else o = o c
  }
  jcache[s] = o
  return o
}
function bucket(s) { return (s in tbuck) ? tbuck[s] : "unknown" }
# Plain text for the summary: control bytes (ESC included) become "?".
function plain(s,   i, c, o) {
  o = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); o = o ((c < " " || c == "\177") ? "?" : c) }
  return o
}
BEGIN { FS = "\t"; sec = 0 }
$0 == "@@" { sec++; next }
sec == 0 { split($0, a, "|"); tn++; tstat[tn] = a[1]; tbuck[a[1]] = a[2]; next }
sec == 1 { no++; order[no] = $0; next }
sec == 2 {
  if ($1 == "M") { lvl[$3] = $2; st[$3] = $4; ism[$3] = 1; par[$3] = $5 }
  else if ($1 == "W") { nw[$3]++; wk[$3, nw[$3]] = $2; wd[$3, nw[$3]] = $4 }
  next
}
function block(L, name,   i, id, s, b, nu, u, j, t, first, ni, first2) {
  split("", cnt); split("", tot); split("", u); nu = 0; ni = 0
  for (i = 1; i <= no; i++) {
    id = order[i]
    if (lvl[id] != L) continue
    s = st[id]; b = bucket(s)
    if (!(s in cnt)) { cnt[s] = 0; if (b == "unknown") u[++nu] = s }
    cnt[s]++; tot[b]++; ni++
  }
  for (i = 2; i <= nu; i++) { t = u[i]; for (j = i - 1; j >= 1 && u[j] > t; j--) u[j + 1] = u[j]; u[j + 1] = t }
  if (summary) {
    # The same cnt/tot just computed above, rendered as one line (no second pass over the items).
    printf "%-8s %d/%d done \302\267 %d %s \302\267 %d %s \302\267 %d pending", name, tot["done"] + 0, tot["done"] + tot["in_progress"] + tot["failed"] + tot["pending"], tot["in_progress"] + 0, lbl_prog, tot["failed"] + 0, lbl_fail, tot["pending"] + 0
    if (tot["unknown"] > 0) printf " \302\267 %d %s", tot["unknown"], lbl_unk
    if (tot["rejected"] > 0) { t = lbl_rej; sub(/%d/, tot["rejected"], t); printf " \302\267 %s", t }
    printf "\n"
    return
  }
  printf "    \"%s\": {\n      \"counts\": {", name
  first = 1
  for (i = 1; i <= tn; i++) if (cnt[tstat[i]] > 0) {
    printf "%s\n        \"%s\": %d", (first ? "" : ","), jesc(tstat[i]), cnt[tstat[i]]; first = 0
  }
  for (i = 1; i <= nu; i++) { printf "%s\n        \"%s\": %d", (first ? "" : ","), jesc(u[i]), cnt[u[i]]; first = 0 }
  printf "%s},\n", (first ? "" : "\n      ")
  printf "      \"totals\": {\n"
  printf "        \"done\": %d,\n        \"in_progress\": %d,\n        \"failed\": %d,\n        \"pending\": %d,\n", tot["done"] + 0, tot["in_progress"] + 0, tot["failed"] + 0, tot["pending"] + 0
  printf "        \"rejected\": %d,\n        \"unknown\": %d,\n        \"denominator\": %d\n      }", tot["rejected"] + 0, tot["unknown"] + 0, tot["done"] + tot["in_progress"] + tot["failed"] + tot["pending"]
  if (items) {
    printf ",\n      \"items\": ["
    first2 = 1
    for (i = 1; i <= no; i++) if (lvl[order[i]] == L) {
      printf "%s\n        { \"id\": \"%s\", \"status\": \"%s\" }", (first2 ? "" : ","), jesc(order[i]), jesc(st[order[i]]); first2 = 0
    }
    printf "%s]", (first2 ? "" : "\n      ")
  }
  printf "\n    }"
}
function render_levels(   nl, ls, i, j, p, present, fl) {
  nl = split("task:tasks story:stories epic:epics", ls, " "); fl = 1
  for (i = 1; i <= nl; i++) {
    split(ls[i], p, ":")
    present = 0
    for (j = 1; j <= no; j++) if (lvl[order[j]] == p[1]) { present = 1; break }
    if (!present && index(" " force_levels " ", " " p[1] " ") == 0) continue
    if (!summary) printf "%s\n", (fl ? "" : ",")
    block(p[1], p[2]); fl = 0
  }
  return fl
}
# The totals object, as block() prints it: same keys, same bucket arithmetic, the denominator rule of the contract.
function totals_obj(t, ind) {
  printf "{\n%s  \"done\": %d,\n%s  \"in_progress\": %d,\n%s  \"failed\": %d,\n%s  \"pending\": %d,\n", ind, t["done"] + 0, ind, t["in_progress"] + 0, ind, t["failed"] + 0, ind, t["pending"] + 0
  printf "%s  \"rejected\": %d,\n%s  \"unknown\": %d,\n%s  \"denominator\": %d\n%s}", ind, t["rejected"] + 0, ind, t["unknown"] + 0, ind, t["done"] + t["in_progress"] + t["failed"] + t["pending"], ind
}
# One list of parents (L = the parents' level, CL = the children's level): every parent in id order with the totals of the
# children whose parent it is. An item is bucketed exactly once, by the same bucket() as everywhere else.
function parent_list(key, L, CL, clabel,   i, id, p, b, first, k) {
  split("", ptot)
  for (i = 1; i <= no; i++) {
    id = order[i]
    if (lvl[id] != CL || par[id] == "") continue
    ptot[par[id], bucket(st[id])]++
  }
  printf "  \"%s\": [", key
  first = 1
  for (i = 1; i <= no; i++) {
    id = order[i]
    if (lvl[id] != L) continue
    split("", tt)
    for (k in bk) tt[k] = ptot[id, k] + 0
    printf "%s\n    {\n      \"id\": \"%s\",\n      \"level\": \"%s\",\n      \"totals\": ", (first ? "" : ","), jesc(id), clabel
    totals_obj(tt, "      ")
    printf "\n    }"
    first = 0
  }
  printf "%s],\n", (first ? "" : "\n  ")
}
function by_parent_end(   i, j, id, fw) {
  bk["done"] = 1; bk["in_progress"] = 1; bk["failed"] = 1; bk["pending"] = 1; bk["rejected"] = 1; bk["unknown"] = 1
  printf "{\n  \"schema_version\": 1,\n  \"scope\": {\n    \"type\": \"by-parent\"\n  },\n"
  parent_list("epics", "epic", "story", "stories")
  parent_list("stories", "story", "task", "tasks")
  printf "  \"warnings\": ["
  fw = 1
  for (i = 1; i <= no; i++) {
    id = order[i]
    for (j = 1; j <= nw[id]; j++) {
      printf "%s\n    {\n      \"kind\": \"%s\",\n      \"id\": \"%s\",\n      \"detail\": \"%s\"\n    }", (fw ? "" : ","), wk[id, j], jesc(id), jesc(wd[id, j]); fw = 0
    }
    if ((id in ism) && bucket(st[id]) == "unknown") {
      printf "%s\n    {\n      \"kind\": \"unknown_status\",\n      \"id\": \"%s\",\n      \"detail\": \"%s\"\n    }", (fw ? "" : ","), jesc(id), jesc("status \"" st[id] "\" is not in the status table"); fw = 0
    }
  }
  printf "%s]\n}\n", (fw ? "" : "\n  ")
}
function summary_end(   i, j, id, line) {
  render_levels()
  for (i = 1; i <= no; i++) {
    id = order[i]
    for (j = 1; j <= nw[id]; j++) {
      line = wk[id, j] (id == "" ? "" : " " id) ": " wd[id, j]
      print "warning: " plain(line)
    }
    if ((id in ism) && bucket(st[id]) == "unknown") print "warning: " plain("unknown_status " id ": status \"" st[id] "\" is not in the status table")
  }
}
END {
  if (summary) { summary_end(); exit }
  if (scope_type == "by-parent") { by_parent_end(); exit }
  printf "{\n  \"schema_version\": 1,\n  \"scope\": {\n    \"type\": \"%s\",\n    \"ids\": [", scope_type
  ni = split(scope_ids, sid, ","); fi = 1
  for (i = 1; i <= ni; i++) if (sid[i] != "") { printf "%s\"%s\"", (fi ? "" : ", "), jesc(sid[i]); fi = 0 }
  printf "]\n  },\n  \"levels\": {"
  fl = render_levels()
  printf "%s},\n  \"warnings\": [", (fl ? "" : "\n  ")
  fw = 1
  for (i = 1; i <= no; i++) {
    id = order[i]
    for (j = 1; j <= nw[id]; j++) {
      printf "%s\n    {\n      \"kind\": \"%s\",\n      \"id\": \"%s\",\n      \"detail\": \"%s\"\n    }", (fw ? "" : ","), wk[id, j], jesc(id), jesc(wd[id, j]); fw = 0
    }
    if ((id in ism) && bucket(st[id]) == "unknown") {
      printf "%s\n    {\n      \"kind\": \"unknown_status\",\n      \"id\": \"%s\",\n      \"detail\": \"%s\"\n    }", (fw ? "" : ","), jesc(id), jesc("status \"" st[id] "\" is not in the status table"); fw = 0
    }
  }
  printf "%s]\n}\n", (fw ? "" : "\n  ")
}
AWK

# One pass: the file list goes to awk on stdin, awk reads the frontmatter itself.
raw="$({ printf '%s' "$LIST_DIRS" | while IFS= read -r _d; do
           find "$_d" -maxdepth 1 -type f -name '*.md' -print
         done
         if [ -n "$TODO_RECORDS" ]; then printf '%s\n' "$TODO_RECORDS"; fi
       } | LC_ALL=C awk -v scope="$SCOPE" -v target="$TARGET" "$LOAD_AWK")" \
  || die 1 "failed to read the board"

TAB="$(printf '\t')"
NL='
'
case "$raw" in
  E"$TAB"*|*"$NL"E"$TAB"*)
    _first="$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "E" { print; exit }')"
    _rest="${_first#E"$TAB"}"
    _code="${_rest%%"$TAB"*}"
    _msg="${_rest#*"$TAB"}"
    case "$_code" in 2|3) die "$_code" "$_msg" ;; *) die 1 "$_msg" ;; esac ;;
esac

# The ids to order are the counted items plus (backlog only) the ids with no board file, which exist only to carry their
# warning. Unresolved todo entries carry an empty id, which sorts first: one empty line ahead of the ordered ids.
ids="$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "M" || ($1 == "W" && $2 == "todo_unknown_id") { print $3 }' | board_id_sort)" \
  || die 1 "failed to order the ids"
if printf '%s\n' "$raw" | awk -F'\t' '$1 == "W" && $2 == "todo_unresolved_entry" { f = 1 } END { exit !f }'; then
  ids="$NL$ids"
fi

case "$SCOPE" in
  epic)  FORCE_LEVELS="task story" ;;
  story) FORCE_LEVELS="task" ;;
  all)   FORCE_LEVELS="task story epic" ;;
  *)     FORCE_LEVELS="" ;;   # ids and backlog: only the levels that hold an item
esac

json="$({
  printf '%s\n@@\n%s\n@@\n%s\n' "$STATUS_TABLE" "$ids" "$raw"
} | LC_ALL=C awk -v scope_type="$SCOPE" -v scope_ids="$TARGET" -v items="$ITEMS" -v force_levels="$FORCE_LEVELS" -v summary="$SUMMARY" -v lbl_prog="$SUM_PROG" -v lbl_fail="$SUM_FAIL" -v lbl_unk="$SUM_UNK" -v lbl_rej="$SUM_REJ" "$RENDER_AWK")" \
  || die 1 "failed to render the progress output"

[ -n "$json" ] || die 1 "empty progress output"
printf '%s\n' "$json"

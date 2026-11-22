#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/generate-wrapper.sh - a reviewed wrapper script for a captured compute step
# (epic E103, task E103_S04_T02)
#
# A captured step judged `compute` holds a command such as `npm install @vendor/sdk`. A workflow compute step can
# only run a script under an allow-listed root (scripts/workflow/resolve-compute-command.sh), so the command is put
# in a wrapper script at <workflows>/scripts/<workflow-id>/<step-id>.sh, where <workflows> is
# `scripts/resolve-root.sh get workflows` (never hardcoded) and <step-id> is the definition's step id (`step_003`).
# The user sees the file's exact content and confirms it; only then is it written. The decision is recorded in the
# recording as record-answer.sh's `wrapper` kind, and emit-workflow.sh turns a confirmed wrapper into a `confirm`
# step directly followed by the compute step that runs it (its WRAPPERS section). A declined wrapper turns the step
# into a `confirm` step.
#
# This script NEVER runs the captured command or the wrapper, and never reads or writes the recorder's
# active-recording pointer: the recording is always named by its explicit path.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   generate-wrapper.sh show    [--timeout <seconds>|none] <recording> <step>
#   generate-wrapper.sh write   --confirm <sha256> [--timeout <seconds>|none] [--replace] <recording> <step>
#   generate-wrapper.sh decline <recording> <step>
#   generate-wrapper.sh pending <recording>
#   generate-wrapper.sh -h | --help | help          this usage on stdout, exit 0
#
#   <step>   the recording's step id (`step-003`), the definition's (`step_003`) or the review row number (`3`).
#
# show     Derives the wrapper and prints the review below. Writes nothing.
# write    Derives the wrapper again and writes it ONLY when --confirm names the sha256 that `show` printed (the
#          content the user saw), with mode 755, whole or not at all (a same-directory temp file and one mv). Then
#          the written path must resolve through scripts/workflow/resolve-compute-command.sh with exit 0, and the
#          confirmation is recorded with `record-answer.sh <recording> <step-id> wrapper -` (body below). If either
#          fails, the file is rolled back (removed, or the previous content restored) and the exit is 10. An existing
#          file with other content is replaced only with --replace (exit 7 otherwise); one with the same content is
#          kept as it is. Prints the wrapper's anchor-relative path.
# decline  Records `wrapper: declined` and changes the step's type to confirm (`step-type confirm --replace`), so
#          the step is emitted as a confirm step. A wrapper this script wrote earlier for the step, still holding the
#          recorded content, is removed; a file with other content is left alone and named on stderr.
# pending  Lists, one `<step-id><TAB><state><TAB><first line of the text>` line each, the included compute steps
#          whose wrapper is not settled: `undecided` (no wrapper decision), `missing` (confirmed, file gone),
#          `modified` (the file differs from the confirmed sha256), `stale` (the step's text or parameters changed
#          since the confirmation, so the derived content differs) or `invalid` (no wrapper can be derived; `show`
#          says why). A compute step whose text already starts with a relative script path needs no wrapper and is
#          not listed. Exit 0 when nothing is listed, 9 otherwise.
#
# ---------------------------------------------------------------------------
# THE WRAPPER (derived deterministically from the step's recorded text and its `parameters` annotation)
# ---------------------------------------------------------------------------
#   The text must be one non-empty line; a leading `$ ` prompt and surrounding backticks are dropped (as
#   classify-command.sh does), nothing else is changed. Refused (exit 5): more than one line, the word `eval`, a
#   positional or special parameter of its own ($1, ${2}, $@, $*, $#), unbalanced quotes, a redaction marker left
#   with no input name, or an `${inputs.<name>}` reference to a name the step's parameters do not declare.
#   1. Every confirmed literal of the step's `parameters: confirmed` annotation (`<name>=<literal>`) becomes
#      `${inputs.<name>}`, longer literals first, in one pass; the k-th bare `<name>` replaces the k-th
#      `<redacted>` / `<redacted private key>` marker (emit-workflow.sh's PARAMETERS rule).
#   2. Each `${inputs.<name>}` then becomes the positional parameter of that input, numbered in order of first
#      appearance, and is NEVER interpolated into the body: outside quotes it is written `"${1}"`, inside double
#      quotes `${1}`, inside single quotes `'"${1}"'` (the quote is closed and reopened), inside $'...' `'"${1}"$'`.
#      So every expansion of a run input is inside double quotes, and nothing is ever eval'd.
#   The file is:
#       #!/usr/bin/env bash
#       # Generated by j.workflow-capture (generate-wrapper.sh) for workflow <id>, step <step-id>.
#       # (three more comment lines; the last names the arguments, `Arguments: 1=<name> 2=<name>` or `none`)
#       set -euo pipefail
#       if [ "$#" -ne <k> ]; then
#         printf '%s\n' '<step-id>.sh: expected <k> argument(s): <names>' >&2
#         exit 64
#       fi
#       <the command, verbatim apart from step 2>
#   The definition passes the inputs as the compute step's args, `${inputs.<name>}` in positional order.
#
# TIMEOUT. A compute step runs with a 60 s default (scripts/workflow/run-compute.sh). A command known to run long -
# its first word, after any NAME=value prefixes, one of npm yarn pnpm bun npx bunx pip pip3 pipx brew cargo go gem
# composer poetry uv make cmake docker apt apt-get, `python -m pip`, or git clone/fetch/pull/submodule - gets
# timeout_seconds 600. --timeout <seconds> sets it, --timeout none drops it. It is part of the recorded decision,
# not of the file.
#
# ---------------------------------------------------------------------------
# THE REVIEW (show stdout)
# ---------------------------------------------------------------------------
#   step      <recording step id> (<definition step id>)
#   workflow  <workflow id>
#   path      <anchor-relative path>
#   args      <names in positional order> | -
#   timeout   <seconds> | -
#   on-disk   new | unchanged | differs
#   recorded  none | confirmed <sha256> | declined
#   sha256    <sha256 of the content>
#   ===== BEGIN <step-id>.sh sha256:<hex> =====
#   <the file's bytes, unchanged>
#   ===== END <step-id>.sh sha256:<hex> =====
#
# THE RECORDED BODY (record-answer.sh's `wrapper` kind, value confirmed), one line each, in this order:
#   path=<anchor-relative path>   sha256=<hex>   args=<names separated by one space, may be empty>
#   timeout_seconds=<n>           (only when a timeout is set)
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success (show printed the review, write wrote or kept the file and recorded it, decline recorded it,
#       pending found nothing to settle)
#   2   usage error: unknown sub-command or option, a missing argument, a bad --timeout or --confirm value
#   3   the recording does not exist or is not readable
#   4   the step cannot take a wrapper: no such step, it is excluded (deviation: out-of-process), or it is not
#       judged compute (its step-type annotation)
#   5   no wrapper can be derived from the step (see THE WRAPPER); or the recording's name gives no valid workflow id
#   6   the environment is incomplete: jq, a sha256 tool, resolve-root.sh, resolve-compute-command.sh, the schema or
#       a recorder script
#   7   write: a different file exists at the path (pass --replace), or the path or its directory is a symlink
#   8   write without --confirm; nothing was written
#   9   write: --confirm does not match the derived content (show it again); pending: steps are listed
#   10  write: the file could not be written, does not resolve through resolve-compute-command.sh, or the decision
#       could not be recorded; everything was rolled back. decline: the decision could not be recorded.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe under
# `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER_DIR="$SCRIPT_DIR/../../j-workflow-recorder/scripts"
FORMAT_LIB="$RECORDER_DIR/recording-format.sh"
ANSWER_SCRIPT="$RECORDER_DIR/record-answer.sh"
# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
PKG_ROOT="$(jenga_package_root "$SCRIPT_DIR" 2>/dev/null)" || true
RESOLVE_ROOT="$PKG_ROOT/scripts/resolve-root.sh"
RESOLVE_COMPUTE="$PKG_ROOT/scripts/workflow/resolve-compute-command.sh"
WORKFLOW_LIB="$PKG_ROOT/scripts/workflow/lib.sh"

RECORDING_SUFFIX='_RECORDING.md'
DEFAULT_LONG_TIMEOUT=600
LONG_RUNNERS='npm yarn pnpm bun npx bunx pip pip3 pipx brew cargo go gem composer poetry uv make cmake docker apt apt-get'

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() { sed -n '/^# USAGE/,/^# Compatible with macOS/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

TMP_FILES=""
cleanup() {
  local f
  for f in $TMP_FILES; do rm -f "$f"; done
  return 0
}
trap cleanup EXIT INT TERM

# ---- environment -------------------------------------------------------------------------------------------------
require_env() {
  command -v jq >/dev/null 2>&1 || die 6 "jq is required"
  if command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
  else die 6 "a sha256 tool (shasum or sha256sum) is required"; fi
  [ -r "$FORMAT_LIB" ] || die 6 "cannot read $FORMAT_LIB"
  [ -f "$ANSWER_SCRIPT" ] || die 6 "cannot find $ANSWER_SCRIPT"
  [ -f "$RESOLVE_ROOT" ] || die 6 "cannot find resolve-root.sh under ${PKG_ROOT:-the package root}/scripts"
  [ -f "$RESOLVE_COMPUTE" ] || die 6 "cannot find $RESOLVE_COMPUTE"
  [ -f "$WORKFLOW_LIB" ] || die 6 "cannot find $WORKFLOW_LIB"
  # shellcheck source=/dev/null
  . "$FORMAT_LIB"
  # shellcheck source=/dev/null
  . "$WORKFLOW_LIB" || die 6 "could not load $WORKFLOW_LIB"
  local schema
  schema="$(workflow_schema_path 2>/dev/null)" || die 6 "could not locate templates/workflow-schema.json"
  ID_PATTERN="$(jq -r '.top_level.id_pattern // empty' "$schema" 2>/dev/null)"
  [ -n "$ID_PATTERN" ] || die 6 "$schema carries no top_level.id_pattern"
}

sha_of_file() { $SHA_CMD "$1" | awk '{print $1}'; }

# ---- the recording -----------------------------------------------------------------------------------------------
REC=""; BASE=""; WF_ID=""
load_recording() {
  REC="$1"
  [ -f "$REC" ] || die 3 "no such recording: $REC"
  [ -r "$REC" ] || die 3 "recording is not readable: $REC"
  rec_has_steps_section "$REC" || die 4 "$REC has no steps section"
  BASE="$(basename "$REC")"
  case "$BASE" in
    *"$RECORDING_SUFFIX") WF_ID="${BASE%"$RECORDING_SUFFIX"}" ;;
    *) die 5 "$BASE does not end in $RECORDING_SUFFIX, so no workflow id can be derived from it" ;;
  esac
  printf '%s\n' "$WF_ID" | grep -Eq "$ID_PATTERN" || \
    die 5 "the workflow id \"$WF_ID\" derived from $BASE does not match the schema's id_pattern $ID_PATTERN"
}

# ann <step-id> <value|text> <kind>: prints the annotation; returns 1 when there is none.
ann() {
  local out rc
  out="$(bash "$ANSWER_SCRIPT" "--$2" "$REC" "$1" "$3" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) printf '%s' "$out"; return 0 ;;
    1) return 1 ;;
    *) die 4 "record-answer.sh --$2 failed (exit $rc) reading $3 on $1 in $REC" ;;
  esac
}

# step_text <step-id>: the step's recorded text, verbatim (the reader emit-workflow.sh uses).
step_text() {
  local open
  open="$(rec_step_open_line "$REC" "$1")" || return 1
  if rec_is_escaped_format "$REC"; then
    awk -v start="$open" -v ap="$REC_ANSWER_MARKER_PREFIX" -v se="$REC_STEP_END_PREFIX" '
      NR < start + 3 { next }
      index($0, ap) == 1 || index($0, se) == 1 { exit }
      $0 == "" { blank++; next }
      { while (blank > 0) { print ""; blank-- } print }
    ' "$REC" | rec_unescape_body
  else
    awk -v start="$open" -v ap="$REC_ANSWER_MARKER_PREFIX" -v se="$REC_STEP_END_PREFIX" '
      NR < start + 3 { next }
      index($0, ap) == 1 || index($0, se) == 1 { exit }
      $0 == "" { blank++; next }
      { while (blank > 0) { print ""; blank-- } print }
    ' "$REC"
  fi
}

# normalise_step <arg>: prints the recording step id (step-003) or exits 2.
normalise_step() {
  case "$1" in
    step-[0-9]*) printf '%s' "$1" ;;
    step_[0-9]*) printf '%s' "$1" | tr '_' '-' ;;
    *[!0-9]*|'') die 2 "a step is step-<nnn>, step_<nnn> or a row number, not \"$1\"" ;;
    *) printf 'step-%03d' "$((10#$1))" ;;
  esac
}

# is_path_command <text>: true when the text already starts with a relative script path (emit-workflow.sh fills
# such a compute step itself, so it needs no wrapper).
is_path_command() {
  local w1
  w1="$(printf '%s\n' "$1" | sed -n '1p')"
  w1="${w1#"${w1%%[![:space:]]*}"}"
  w1="${w1%%[[:space:]]*}"
  case "$w1" in */*) ;; *) return 1 ;; esac
  case "/$w1/" in */../*|//*) return 1 ;; esac
  printf '%s\n' "$w1" | grep -Eq '^[A-Za-z0-9._@+/-]+$'
}

# ---- derivation --------------------------------------------------------------------------------------------------
# derive <step-id>: sets STEP, WF_STEP, REL_PATH, ABS_PATH, ARG_NAMES, CONTENT_FILE, SHA, AUTO_TIMEOUT, or exits.
STEP=""; WF_STEP=""; REL_PATH=""; ABS_PATH=""; WF_DIR=""; ANCHOR=""; ARG_NAMES=""; CONTENT_FILE=""; SHA=""
AUTO_TIMEOUT=""
derive() {
  local text n_lines params lits_json bares cmd refs name k idx body
  STEP="$1"
  rec_step_open_line "$REC" "$STEP" >/dev/null 2>&1 || die 4 "no step \"$STEP\" in $BASE"
  if [ "$(ann "$STEP" value deviation || true)" = "out-of-process" ]; then
    die 4 "$STEP is excluded (deviation: out-of-process); it is never emitted, so it takes no wrapper"
  fi
  [ "$(ann "$STEP" value step-type || true)" = "compute" ] || \
    die 4 "$STEP is not judged compute (record its type with record-review.sh decide ... type compute first)"
  WF_STEP="$(printf '%s' "$STEP" | tr '-' '_')"

  WF_DIR="$(bash "$RESOLVE_ROOT" get workflows 2>/dev/null)" && [ -n "$WF_DIR" ] || \
    die 6 "could not resolve the workflows directory with resolve-root.sh get workflows"
  ANCHOR="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" && [ -n "$ANCHOR" ] || \
    die 6 "could not resolve the project anchor with resolve-root.sh root"
  local wf_rel
  wf_rel="$(bash "$RESOLVE_ROOT" --relative get workflows 2>/dev/null)" && [ -n "$wf_rel" ] || \
    die 6 "could not resolve the workflows directory relative to the anchor"
  case "$wf_rel" in /*|../*|*/../*) die 6 "the workflows directory $WF_DIR is not inside the project anchor $ANCHOR" ;; esac
  wf_rel="${wf_rel#./}"
  REL_PATH="$wf_rel/scripts/$WF_ID/$WF_STEP.sh"
  ABS_PATH="$WF_DIR/scripts/$WF_ID/$WF_STEP.sh"

  text="$(step_text "$STEP")" || die 4 "could not read the text of $STEP"
  n_lines="$(printf '%s\n' "$text" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$n_lines" -eq 1 ] || die 5 "$STEP must hold exactly one command line to become a wrapper (it has $n_lines non-empty lines)"
  cmd="$(printf '%s\n' "$text" | awk 'NF { print; exit }')"
  cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$cmd" in '$ '*) cmd="${cmd:2}" ;; esac
  case "$cmd" in '`'*'`') cmd="${cmd#\`}"; cmd="${cmd%\`}" ;; esac
  cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$cmd" ] || die 5 "$STEP has no command"
  if printf '%s' "$cmd" | tr -d '\t' | grep -q '[[:cntrl:]]'; then die 5 "$STEP holds a control character"; fi
  if printf '%s\n' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_.-])eval([^A-Za-z0-9_.-]|$)'; then
    die 5 "$STEP uses eval; a wrapper never evaluates text, so it cannot become a compute step"
  fi
  if printf '%s\n' "$cmd" | grep -Eq '\$([0-9@*#]|\{[#]?[0-9@*#])'; then
    die 5 "$STEP refers to a positional or special parameter (\$1, \$@, \$*, \$#); the wrapper's arguments are its run inputs only"
  fi

  # 1. confirmed literals and bare names (emit-workflow.sh's PARAMETERS rule) -> ${inputs.<name>}
  params="$(ann "$STEP" text parameters || true)"
  [ "$(ann "$STEP" value parameters || true)" = "confirmed" ] || params=""
  lits_json="$(printf '%s\n' "$params" | awk 'index($0, "=") > 1 { print }' | \
    jq -R 'index("=") as $i | {name: .[0:$i], lit: .[$i + 1:]}' | jq -sc 'sort_by(-(.lit | length))')" || \
    die 6 "could not read the parameters of $STEP with jq"
  bares="$(printf '%s\n' "$params" | awk 'NF && index($0, "=") == 0 { print }')"
  cmd="$(jq -rn --arg t "$cmd" --argjson lits "$lits_json" '
    reduce range(0; $lits | length) as $i ($t; split($lits[$i].lit) | join("\u0002" + ("\u0004" * ($i + 1)) + "\u0002"))
    | gsub("\u0002(?<c>\u0004+)\u0002"; "${inputs." + $lits[(.c | length) - 1].name + "}")')" || \
    die 6 "could not apply the parameters of $STEP with jq"
  for name in $bares; do
    cmd="$(printf '%s' "$cmd" | awk -v n="$name" '{
      line = $0; i = index(line, "<redacted"); best = 0; len = 0
      a = index(line, "<redacted private key>"); b = index(line, "<redacted>")
      if (a > 0 && (b == 0 || a < b)) { best = a; len = length("<redacted private key>") }
      else if (b > 0) { best = b; len = length("<redacted>") }
      if (best > 0) line = substr(line, 1, best - 1) "${inputs." n "}" substr(line, best + len)
      print line }')"
  done
  case "$cmd" in *'<redacted>'*|*'<redacted private key>'*)
    die 5 "$STEP still holds a redaction marker with no input name; name it as a parameter in the review (params <name>)" ;;
  esac

  # 2. every reference must be declared; positional order = order of first appearance
  refs="$(printf '%s\n' "$cmd" | grep -oE '\$\{inputs\.[a-z][a-z0-9_]*\}' | sed -e 's/^\${inputs\.//' -e 's/}$//' | \
    awk '!seen[$0]++')"
  if printf '%s\n' "$cmd" | sed -E 's/\$\{inputs\.[a-z][a-z0-9_]*\}//g' | grep -q '\${inputs\.'; then
    die 5 "$STEP holds a malformed \${inputs....} reference"
  fi
  local declared
  declared="$(printf '%s\n' "$params" | awk 'NF { i = index($0, "="); print (i > 0 ? substr($0, 1, i - 1) : $0) }')"
  for name in $refs; do
    printf '%s\n' "$declared" | grep -Fxq -- "$name" || \
      die 5 "$STEP refers to \${inputs.$name}, which its parameters do not declare; confirm it in the review (params ... $name)"
  done
  ARG_NAMES="$(printf '%s\n' "$refs" | awk 'NF' | tr '\n' ' ' | sed 's/ $//')"

  body="$(printf '%s\n' "$cmd" | awk -v names="$ARG_NAMES" '
    BEGIN { k = split(names, nm, " "); for (i = 1; i <= k; i++) pos[nm[i]] = i }
    {
      s = $0; out = ""; st = 0; i = 1; L = length(s)
      while (i <= L) {
        c = substr(s, i, 1)
        if (c == "$" && substr(s, i, 9) == "${inputs." && match(substr(s, i), /^\$\{inputs\.[a-z][a-z0-9_]*\}/)) {
          ref = substr(s, i, RLENGTH); nm1 = substr(ref, 10, RLENGTH - 10); p = pos[nm1]
          if (st == 0) out = out "\"${" p "}\""
          else if (st == 2) out = out "${" p "}"
          else if (st == 1) out = out "'\''\"${" p "}\"'\''"
          else out = out "'\''\"${" p "}\"$'\''"
          i += RLENGTH; continue
        }
        if (st == 0) {
          if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
          if (c == "$" && substr(s, i + 1, 1) == "'\''") { st = 3; out = out "$'\''"; i += 2; continue }
          if (c == "'\''") st = 1
          else if (c == "\"") st = 2
        } else if (st == 1) {
          if (c == "'\''") st = 0
        } else if (st == 2) {
          if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
          if (c == "\"") st = 0
        } else {
          if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
          if (c == "'\''") st = 0
        }
        out = out c; i++
      }
      if (st != 0) exit 3
      print out
    }')" || die 5 "$STEP has unbalanced quotes; it cannot be wrapped safely as it stands"

  local nargs argdesc
  nargs=0; argdesc=""
  for name in $ARG_NAMES; do nargs=$((nargs + 1)); argdesc="$argdesc $nargs=$name"; done
  [ -n "$argdesc" ] || argdesc=" none"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '# Generated by j.workflow-capture (generate-wrapper.sh) for workflow %s, step %s.\n' "$WF_ID" "$WF_STEP"
    printf '%s\n' '# The command below is the captured step, verbatim; the user reviewed this file and confirmed it before it'
    printf '%s\n' '# was written. Run inputs arrive as positional arguments and are only ever expanded inside double quotes.'
    printf '# Arguments:%s\n' "$argdesc"
    printf '%s\n' 'set -euo pipefail'
    printf 'if [ "$#" -ne %s ]; then\n' "$nargs"
    printf "  printf '%%s\\\\n' '%s.sh: expected %s argument(s):%s' >&2\n" "$WF_STEP" "$nargs" "$argdesc"
    printf '%s\n' '  exit 64'
    printf '%s\n' 'fi'
    printf '%s\n' "$body"
  } > "$CONTENT_FILE" || die 6 "could not write a temporary file"
  SHA="$(sha_of_file "$CONTENT_FILE")"

  # timeout for commands known to run long
  local w rest b0 b1 b2
  rest="$cmd"
  while printf '%s\n' "$rest" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+'; do
    rest="$(printf '%s\n' "$rest" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')"
  done
  set -f; set -- $rest; set +f
  b0="${1:-}"; b1="${2:-}"; b2="${3:-}"
  AUTO_TIMEOUT=""
  for w in $LONG_RUNNERS; do [ "$b0" = "$w" ] && AUTO_TIMEOUT="$DEFAULT_LONG_TIMEOUT"; done
  case "$b0 $b1" in git\ clone|git\ fetch|git\ pull|git\ submodule) AUTO_TIMEOUT="$DEFAULT_LONG_TIMEOUT" ;; esac
  case "$b0 $b1 $b2" in python\ -m\ pip|python3\ -m\ pip) AUTO_TIMEOUT="$DEFAULT_LONG_TIMEOUT" ;; esac
  return 0
}

# on_disk_state: new | unchanged | differs (for ABS_PATH against CONTENT_FILE)
on_disk_state() {
  if [ ! -e "$ABS_PATH" ] && [ ! -L "$ABS_PATH" ]; then printf 'new'; return; fi
  if [ -f "$ABS_PATH" ] && [ ! -L "$ABS_PATH" ] && cmp -s "$ABS_PATH" "$CONTENT_FILE"; then printf 'unchanged'; return; fi
  printf 'differs'
}

recorded_state() {
  local v
  v="$(ann "$STEP" value wrapper)" || { printf 'none'; return; }
  if [ "$v" = "confirmed" ]; then
    printf 'confirmed %s' "$(ann "$STEP" text wrapper | sed -n 's/^sha256=//p')"
  else
    printf '%s' "$v"
  fi
}

# ---- arguments ---------------------------------------------------------------------------------------------------
SUB="${1:-}"
case "$SUB" in
  -h|--help|help) usage; trap - EXIT INT TERM; exit 0 ;;
  show|write|decline|pending) shift ;;
  "") usage >&2; die 2 "a sub-command is required: show, write, decline or pending" ;;
  *) usage >&2; die 2 "unknown sub-command \"$SUB\"" ;;
esac
TIMEOUT_OPT=""; CONFIRM=""; REPLACE=0; POS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$SUB" = show ] || [ "$SUB" = write ] || die 2 "--timeout belongs to show and write"
      [ "$#" -ge 2 ] || die 2 "--timeout needs a number of seconds or none"
      case "$2" in none) ;; ''|*[!0-9]*|0*) die 2 "--timeout must be a positive integer or none, not \"$2\"" ;; esac
      TIMEOUT_OPT="$2"; shift 2 ;;
    --confirm)
      [ "$SUB" = write ] || die 2 "--confirm belongs to write"
      [ "$#" -ge 2 ] || die 2 "--confirm needs the sha256 that show printed"
      printf '%s\n' "$2" | grep -Eq '^[0-9a-f]{64}$' || die 2 "--confirm wants the 64-hex sha256 that show printed"
      CONFIRM="$2"; shift 2 ;;
    --replace) [ "$SUB" = write ] || die 2 "--replace belongs to write"; REPLACE=1; shift ;;
    -h|--help) usage; trap - EXIT INT TERM; exit 0 ;;
    -*) die 2 "unknown option $1" ;;
    *) POS="$POS
$1"; shift ;;
  esac
done
POS="$(printf '%s\n' "$POS" | awk 'NF')"
NPOS="$(printf '%s\n' "$POS" | awk 'NF { n++ } END { print n + 0 }')"
case "$SUB" in
  pending) [ "$NPOS" -eq 1 ] || die 2 "pending takes one recording" ;;
  *) [ "$NPOS" -eq 2 ] || die 2 "$SUB takes a recording and a step" ;;
esac
REC_ARG="$(printf '%s\n' "$POS" | sed -n '1p')"
STEP_ARG="$(printf '%s\n' "$POS" | sed -n '2p')"

require_env
load_recording "$REC_ARG"
CONTENT_FILE="$(mktemp "${TMPDIR:-/tmp}/generate-wrapper.XXXXXX")" || die 6 "could not create a temporary file"
TMP_FILES="$TMP_FILES $CONTENT_FILE"

effective_timeout() {
  case "$TIMEOUT_OPT" in
    none) printf '' ;;
    '') printf '%s' "$AUTO_TIMEOUT" ;;
    *) printf '%s' "$TIMEOUT_OPT" ;;
  esac
}

# ---- show --------------------------------------------------------------------------------------------------------
cmd_show() {
  derive "$(normalise_step "$STEP_ARG")"
  local t
  t="$(effective_timeout)"
  printf 'step      %s (%s)\n' "$STEP" "$WF_STEP"
  printf 'workflow  %s\n' "$WF_ID"
  printf 'path      %s\n' "$REL_PATH"
  printf 'args      %s\n' "${ARG_NAMES:--}"
  printf 'timeout   %s\n' "${t:--}"
  printf 'on-disk   %s\n' "$(on_disk_state)"
  printf 'recorded  %s\n' "$(recorded_state)"
  printf 'sha256    %s\n' "$SHA"
  printf '===== BEGIN %s.sh sha256:%s =====\n' "$WF_STEP" "$SHA"
  cat "$CONTENT_FILE"
  printf '===== END %s.sh sha256:%s =====\n' "$WF_STEP" "$SHA"
}

# ---- write -------------------------------------------------------------------------------------------------------
cmd_write() {
  [ -n "$CONFIRM" ] || die 8 "write needs --confirm <sha256>: the user must see the content (show) and confirm it first; nothing was written"
  derive "$(normalise_step "$STEP_ARG")"
  [ "$CONFIRM" = "$SHA" ] || \
    die 9 "the wrapper for $STEP now derives to sha256 $SHA, not the confirmed $CONFIRM; show it again and confirm what is shown. Nothing was written."
  local t dir state made_dirs="" backup="" d tmp body replace_flag=""
  t="$(effective_timeout)"
  dir="$(dirname "$ABS_PATH")"
  for d in "$WF_DIR/scripts" "$dir"; do
    [ -L "$d" ] && die 7 "$d is a symlink; refusing to write a wrapper through it"
  done
  [ -L "$ABS_PATH" ] && die 7 "$ABS_PATH is a symlink; refusing to write through it"
  state="$(on_disk_state)"
  if [ "$state" = "differs" ]; then
    [ -f "$ABS_PATH" ] || die 7 "$ABS_PATH exists and is not a regular file"
    [ "$REPLACE" -eq 1 ] || die 7 "$REL_PATH already exists with other content; pass --replace to overwrite it. Nothing was written."
  fi

  rollback() {
    if [ -n "$backup" ]; then mv -f "$backup" "$ABS_PATH" 2>/dev/null; backup=""
    elif [ "$state" = "new" ]; then rm -f "$ABS_PATH"; fi
    for d in $made_dirs; do rmdir "$d" 2>/dev/null; done
    return 0
  }

  if [ "$state" != "unchanged" ]; then
    for d in "$WF_DIR" "$WF_DIR/scripts" "$dir"; do
      if [ ! -d "$d" ]; then mkdir "$d" 2>/dev/null || { rollback; die 10 "could not create $d; nothing was written"; }; made_dirs="$d $made_dirs"; fi
    done
    tmp="$dir/.$WF_STEP.sh.tmp.$$"
    TMP_FILES="$TMP_FILES $tmp"
    cp "$CONTENT_FILE" "$tmp" 2>/dev/null && chmod 755 "$tmp" 2>/dev/null || { rollback; die 10 "could not write $tmp; nothing was written"; }
    if [ "$state" = "differs" ]; then
      backup="$dir/.$WF_STEP.sh.bak.$$"
      cp -p "$ABS_PATH" "$backup" 2>/dev/null || { rollback; die 10 "could not back up $ABS_PATH; nothing was written"; }
      TMP_FILES="$TMP_FILES $backup"
    fi
    mv -f "$tmp" "$ABS_PATH" 2>/dev/null || { rollback; die 10 "could not move the wrapper into place; nothing was written"; }
  else
    chmod 755 "$ABS_PATH" 2>/dev/null || die 10 "could not make $ABS_PATH executable"
  fi

  local rc=0 rerr
  rerr="$(cd "$ANCHOR" && bash "$RESOLVE_COMPUTE" "$REL_PATH" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rollback
    die 10 "$REL_PATH does not resolve through resolve-compute-command.sh (exit $rc: $rerr); the wrapper was rolled back"
  fi

  body="path=$REL_PATH
sha256=$SHA
args=$ARG_NAMES"
  [ -z "$t" ] || body="$body
timeout_seconds=$t"
  if ann "$STEP" value wrapper >/dev/null; then replace_flag="--replace"; fi
  if ! rerr="$(printf '%s\n' "$body" | bash "$ANSWER_SCRIPT" $replace_flag "$REC" "$STEP" wrapper - 2>&1 >/dev/null)"; then
    rollback
    die 10 "the confirmation could not be recorded ($rerr); the wrapper was rolled back"
  fi
  [ -z "$backup" ] || rm -f "$backup"
  printf '%s\n' "$REL_PATH"
}

# ---- decline -----------------------------------------------------------------------------------------------------
cmd_decline() {
  STEP="$(normalise_step "$STEP_ARG")"
  rec_step_open_line "$REC" "$STEP" >/dev/null 2>&1 || die 4 "no step \"$STEP\" in $BASE"
  if [ "$(ann "$STEP" value deviation || true)" = "out-of-process" ]; then
    die 4 "$STEP is excluded (deviation: out-of-process); it is never emitted, so it takes no wrapper"
  fi
  local prev_sha="" prev_path="" flag="" rerr
  if [ "$(ann "$STEP" value wrapper || true)" = "confirmed" ]; then
    prev_sha="$(ann "$STEP" text wrapper | sed -n 's/^sha256=//p')"
    prev_path="$(ann "$STEP" text wrapper | sed -n 's/^path=//p')"
  fi
  ann "$STEP" value wrapper >/dev/null && flag="--replace"
  rerr="$(bash "$ANSWER_SCRIPT" $flag "$REC" "$STEP" wrapper declined 2>&1 >/dev/null)" || \
    die 10 "could not record the declined wrapper on $STEP: $rerr"
  flag=""
  ann "$STEP" value step-type >/dev/null && flag="--replace"
  rerr="$(bash "$ANSWER_SCRIPT" $flag "$REC" "$STEP" step-type confirm 2>&1 >/dev/null)" || \
    die 10 "recorded the declined wrapper, but could not change $STEP to a confirm step: $rerr"
  if [ -n "$prev_path" ]; then
    local anchor abs
    anchor="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" || anchor=""
    abs="$anchor/$prev_path"
    if [ -n "$anchor" ] && [ -f "$abs" ] && [ ! -L "$abs" ]; then
      if [ "$(sha_of_file "$abs")" = "$prev_sha" ]; then
        rm -f "$abs" && err "removed the wrapper written earlier for $STEP: $prev_path"
        rmdir "$(dirname "$abs")" 2>/dev/null || true
      else
        err "left $prev_path in place: its content is not the one confirmed earlier"
      fi
    fi
  fi
  printf '%s\n' "$STEP"
}

# ---- pending -----------------------------------------------------------------------------------------------------
cmd_pending() {
  local sid text first state wv rec_sha rec_path anchor listed=0 dsha
  anchor="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" || die 6 "could not resolve the project anchor with resolve-root.sh root"
  for sid in $(rec_step_ids "$REC"); do
    [ "$(ann "$sid" value deviation || true)" = "out-of-process" ] && continue
    [ "$(ann "$sid" value step-type || true)" = "compute" ] || continue
    text="$(step_text "$sid")" || continue
    wv="$(ann "$sid" value wrapper || true)"
    if [ -z "$wv" ] && is_path_command "$text"; then continue; fi
    first="$(printf '%s\n' "$text" | awk 'NF { print; exit }')"
    state=""
    if [ "$wv" != "confirmed" ]; then
      state="undecided"
    else
      rec_sha="$(ann "$sid" text wrapper | sed -n 's/^sha256=//p')"
      rec_path="$(ann "$sid" text wrapper | sed -n 's/^path=//p')"
      if [ ! -f "$anchor/$rec_path" ] || [ -L "$anchor/$rec_path" ]; then state="missing"
      elif [ "$(sha_of_file "$anchor/$rec_path")" != "$rec_sha" ]; then state="modified"
      else
        dsha="$( ( derive "$sid" >/dev/null 2>&1 && printf '%s' "$SHA" ) )" || dsha=""
        if [ -z "$dsha" ]; then state="invalid"
        elif [ "$dsha" != "$rec_sha" ]; then state="stale"; fi
      fi
    fi
    if [ -n "$state" ]; then
      printf '%s\t%s\t%s\n' "$sid" "$state" "$first"
      listed=1
    fi
  done
  [ "$listed" -eq 0 ] || exit 9
  return 0
}

case "$SUB" in
  show) cmd_show ;;
  write) cmd_write ;;
  decline) cmd_decline ;;
  pending) cmd_pending ;;
esac
exit 0

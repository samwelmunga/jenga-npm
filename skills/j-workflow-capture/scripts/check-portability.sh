#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/check-portability.sh - warn about what would not run elsewhere (E103_S05_T01)
#
# A captured workflow is meant to run in another project. Parametrisation (detect-parameters.sh) turns the values it
# recognises into run inputs; this script is the check at emission that whatever is LEFT in the definition would
# still run in another project. It reads an emitted (or about-to-be-emitted) workflow definition and reports three
# kinds of finding, each with the step id and the offending text. It decides nothing: the review offers each finding
# as a parameter or a fix, and the user may accept one explicitly, which `accept` records through record-answer.sh.
# Never reads or writes the recorder's active-recording pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   check-portability.sh check [options] <definition.json>
#   check-portability.sh accept --recording <recording> <step-id> <kind> <text>
#   check-portability.sh shipped-skills [--framework-root <dir>]
#   check-portability.sh -h | --help | help            this usage on stdout, exit 0
#
#   check options (each defaults from the project or the install, so the agent normally passes none but --recording):
#     --recording <path>      the recording the definition was emitted from; findings accepted on it are reported as
#                             `accepted` instead of `open`
#     --framework-root <dir>  where the shipped skill catalog lives   default: the package this script belongs to
#     --project-root <dir>    the project's root     default: `git rev-parse --show-toplevel` of the cwd, else cwd
#     --project-name <name>   the project's name     default: the basename of the project root
#     --repo <owner/name>     the repository         default: parsed from `git remote get-url origin`
#   An empty value ("") switches that name off.
#
#   check prints one line per finding, in step order, then first-appearance order, each (step, kind, text) once:
#       <step-id> TAB <kind> TAB <text> TAB open|accepted
#   and nothing for a clean definition.
#
# ---------------------------------------------------------------------------
# THE THREE KINDS
# ---------------------------------------------------------------------------
#   unshipped-skill  a skill a step names that a consumer of this framework does not have. Named by a skill step's
#                    `skill` field, by a `j.<x>` or `/j-<x>` token, or by a `skills/<dir>/` reference in any of the
#                    step's strings. The SHIPPED SET IS DERIVED, never listed here (see shipped-skills).
#   absolute-path    an absolute path of two segments or more, or a `~/` path: the shape detect-parameters.sh proposes
#                    as a `<x>_path` input, so whatever survives to here was not made a parameter.
#   project-name     the project root's basename, the repository name or its owner/name slug, as a whole word,
#                    case-insensitive. Text already reported as an absolute path is not reported again.
# Strings scanned: every string value of every step, at any depth, except the `id` and `type` keys. A `${inputs.x}`
# reference matches none of the three.
#
# ---------------------------------------------------------------------------
# shipped-skills - THE SHIPPED SET, FROM THE REPOSITORY'S OWN SOURCES
# ---------------------------------------------------------------------------
# The catalog is <framework-root>/skills/<dir>/SKILL.md. When <framework-root> is a git toplevel holding a
# `.publicignore` (this framework's own private repository), each catalog entry is also classified by
# scripts/check-publicignore-match.sh, the single source of blocklist semantics (it agrees with the public mirror's
# dry-run ship list), and only PUBLIC entries count. Otherwise (an installed package, which holds only what shipped)
# every catalog entry is shipped. A name maps to directories as: `j.x` -> j-x or x, `/j-x` -> j-x or x, anything else
# as written, `skills/<dir>/` -> <dir>; it is shipped when one of those is in the set (the finding's text is the name
# or reference as written). Prints the shipped directory names, one per line.
#
# ---------------------------------------------------------------------------
# accept - RECORD THAT THE USER ACCEPTS A FINDING
# ---------------------------------------------------------------------------
# The definition's step id `step_003` is the recording's `step-003` (emit-workflow.sh's rule 5); either form is
# accepted. The acceptance is written with `record-answer.sh <recording> step-003 portability -`, kind `portability`,
# value `accepted`, body one `<kind> <text>` line per accepted finding of that step: an earlier acceptance on the
# same step is kept and the new line added (written with --replace), and accepting the same finding twice changes
# nothing. emit-workflow.sh does not read this kind, so an acceptance never changes the emitted definition.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   check: no open finding (accepted ones may be listed). accept / shipped-skills: success
#   1   check: at least one open finding
#   2   usage error (accept: also an unknown kind or an empty text)
#   3   the definition or the recording does not exist or is not readable
#   4   the definition is not a workflow definition (not JSON, or no steps array)
#   5   accept: the step is not in the recording, or record-answer.sh refused the write (its message on stderr)
#   6   jq, record-answer.sh or the skill catalog could not be found, or the publicignore matcher failed
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RA="$SCRIPT_DIR/../../j-workflow-recorder/scripts/record-answer.sh"
KINDS='unshipped-skill absolute-path project-name'

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  check-portability.sh check [--recording <path>] [--framework-root <dir>] [--project-root <dir>]
                             [--project-name <name>] [--repo <owner/name>] <definition.json>
  check-portability.sh accept --recording <recording> <step-id> <kind> <text>
  check-portability.sh shipped-skills [--framework-root <dir>]
  check-portability.sh -h | --help | help

Reports what in a workflow definition would not run in another project: skills that are not shipped
(unshipped-skill), absolute paths (absolute-path) and the project or repository name (project-name), one
"<step-id> TAB <kind> TAB <text> TAB open|accepted" line each; exit 1 while one is open. accept records the
user's acceptance of a finding with record-answer.sh (kind portability). Contract and exit codes: this
script's header.
USAGE
}

need_jq() { command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"; }

# shipped_skills <framework-root>: the shipped skill directory names, one per line (see the header).
shipped_skills() {
  local froot="${1%/}" f d top
  [ -d "$froot/skills" ] || die 6 "no skill catalog at $froot/skills"
  local dirs=()
  for f in "$froot"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    d="${f%/SKILL.md}"; dirs+=("${d##*/}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  top="$(git -C "$froot" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -f "$froot/.publicignore" ] && [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$froot" && pwd -P)" ]; then
    local matcher="$froot/scripts/check-publicignore-match.sh" paths=() out
    [ -f "$matcher" ] || die 6 "cannot find $matcher"
    for d in "${dirs[@]}"; do paths+=("skills/$d/SKILL.md"); done
    out="$(bash "$matcher" "${paths[@]}")" || die 6 "check-publicignore-match.sh failed"
    printf '%s\n' "$out" | awk -F '\t' '$1 == "PUBLIC" { p = $2; sub(/^skills\//, "", p); sub(/\/SKILL\.md$/, "", p); print p }'
  else
    printf '%s\n' "${dirs[@]}"
  fi
}

# The finding detector. Input: the definition. Args: $shipped (array of dirs), $names (array of project names).
# Output: "<step-id>\t<kind>\t<text>" lines.
JQ_FIND='
  def rxq: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}/-])"; "\\\(.c)");
  def word($v): "(?<![A-Za-z0-9_.@/-])" + ($v | rxq) + "(?![A-Za-z0-9_/-])";
  def claim($v): split($v) | join("\u0001");
  def dirs_of: if test("^skills/") then [split("/")[1]] else sub("^/"; "") end
               | if (. | type) == "array" then . elif test("^j[.]") then ["j-" + .[2:], .[2:]]
                               elif test("^j-") then [., .[2:]] else [.] end;
  def shipped: dirs_of | any(.[]; . as $d | $shipped | index([$d]) != null);
  def strs: [paths(strings) as $p | select(($p | length) > 1 or ($p[0] != "id" and $p[0] != "type"))
             | getpath($p)];
  .steps[] | (.id | tostring) as $id | (strs | join("\n")) as $all
  | ( [ (if .type == "skill" and (.skill | type) == "string" then .skill else empty end),
        ($all | scan("(?<![A-Za-z0-9_./-])(?:j[.]|/j-)[a-z][a-z0-9-]*[a-z0-9]")),
        ($all | scan("(?<![A-Za-z0-9_./-])skills/[a-z0-9][a-z0-9-]*/")) ]
      | map(select(shipped | not)) | map([$id, "unshipped-skill", .]) ),
    ( [$all | scan("(?<![A-Za-z0-9_.~/:@-])(?:~(?:/[A-Za-z0-9._@+~-]+)+|(?:/[A-Za-z0-9._@+~-]+){2,})") | sub("[.]+$"; "")]
      as $abs
      | ($abs | map([$id, "absolute-path", .])),
        (reduce $abs[] as $a ($all; claim($a)) as $rest
         | [ $names[] as $n | $rest | match(word($n); "gi") | .string ] | map([$id, "project-name", .])) )
  | .[] | @tsv
'

cmd_check() {
  local rec="" froot="$DEFAULT_FRAMEWORK_ROOT" root="" root_set=0 pname="" pname_set=0 repo="" repo_set=0 def=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recording) [ "$#" -ge 2 ] || die 2 "--recording needs a value"; rec="$2"; shift 2 ;;
      --framework-root) [ "$#" -ge 2 ] || die 2 "--framework-root needs a value"; froot="$2"; shift 2 ;;
      --project-root) [ "$#" -ge 2 ] || die 2 "--project-root needs a value"; root="$2"; root_set=1; shift 2 ;;
      --project-name) [ "$#" -ge 2 ] || die 2 "--project-name needs a value"; pname="$2"; pname_set=1; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || die 2 "--repo needs a value"; repo="$2"; repo_set=1; shift 2 ;;
      -*) usage >&2; die 2 "unknown option: $1" ;;
      *) [ -z "$def" ] || die 2 "only one definition, got \"$def\" and \"$1\""; def="$1"; shift ;;
    esac
  done
  [ -n "$def" ] || { usage >&2; die 2 "check needs a definition file"; }
  need_jq
  [ -f "$def" ] && [ -r "$def" ] || die 3 "no readable definition at $def"
  jq -e '(.steps | type) == "array"' "$def" >/dev/null 2>&1 || die 4 "$def is not a workflow definition (JSON with a steps array)"
  if [ -n "$rec" ]; then
    [ -f "$rec" ] && [ -r "$rec" ] || die 3 "no readable recording at $rec"
    [ -f "$RA" ] || die 6 "cannot find $RA"
  fi

  if [ "$root_set" -eq 0 ]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
    [ -n "$root" ] || root="$(pwd -P)"
  fi
  root="${root%/}"
  if [ "$pname_set" -eq 0 ]; then pname="$(basename "${root:-/}")"; [ "$pname" = "/" ] && pname=""; fi
  if [ "$repo_set" -eq 0 ] && [ -n "$root" ]; then
    local url
    url="$(git -C "$root" remote get-url origin 2>/dev/null)" || url=""
    url="${url%.git}"; url="${url%/}"
    repo="$(printf '%s\n' "$url" | sed -n 's#.*[:/]\([A-Za-z0-9_.-][A-Za-z0-9_.-]*/[A-Za-z0-9_.-][A-Za-z0-9_.-]*\)$#\1#p')"
  fi
  local reponame="${repo##*/}"

  local list shipped names findings
  list="$(shipped_skills "$froot")" || exit 6
  shipped="$(printf '%s\n' "$list" | jq -Rn '[inputs | select(. != "")]')"
  # Longest first, so a slug is reported before the repository name it contains.
  names="$(printf '%s\n' "$repo" "$reponame" "$pname" | jq -Rn '[inputs | select(. != "")] | unique | sort_by(-length)')"
  findings="$(jq -r --argjson shipped "$shipped" --argjson names "$names" "$JQ_FIND" "$def")" || die 4 "could not scan $def"
  [ -n "$findings" ] || return 0

  local open=0 seen="" step kind text state acc
  while IFS="$(printf '\t')" read -r step kind text; do
    case "$seen" in *"<$step|$kind|$text>"*) continue ;; esac
    seen="$seen<$step|$kind|$text>"
    state=open
    if [ -n "$rec" ]; then
      acc="$(bash "$RA" --text "$rec" "$(rec_step "$step")" portability 2>/dev/null)" || acc=""
      if printf '%s\n' "$acc" | grep -Fxq -- "$kind $text"; then state=accepted; fi
    fi
    [ "$state" = open ] && open=1
    printf '%s\t%s\t%s\t%s\n' "$step" "$kind" "$text" "$state"
  done <<EOF
$findings
EOF
  return "$open"
}

# rec_step <id>: the recording's step id for a definition's step id (step_003 -> step-003).
rec_step() { printf '%s' "$1" | tr '_' '-'; }

cmd_accept() {
  local rec=""
  local args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recording) [ "$#" -ge 2 ] || die 2 "--recording needs a value"; rec="$2"; shift 2 ;;
      --) shift; while [ "$#" -gt 0 ]; do args+=("$1"); shift; done ;;
      -*) usage >&2; die 2 "unknown option: $1" ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$rec" ] || { usage >&2; die 2 "accept needs --recording <path>"; }
  [ "${#args[@]}" -eq 3 ] || { usage >&2; die 2 "accept needs <step-id> <kind> <text>"; }
  local step kind text
  step="$(rec_step "${args[0]}")"; kind="${args[1]}"; text="${args[2]}"
  case " $KINDS " in *" $kind "*) ;; *) die 2 "unknown kind \"$kind\" (one of: $KINDS)" ;; esac
  [ -n "$text" ] || die 2 "the finding's text is empty"
  case "$text" in *$'\n'*|*$'\t'*) die 2 "the finding's text holds a tab or a newline" ;; esac
  [ -f "$rec" ] && [ -r "$rec" ] || die 3 "no readable recording at $rec"
  [ -f "$RA" ] || die 6 "cannot find $RA"

  local line="$kind $text" prev rc=0
  prev="$(bash "$RA" --text "$rec" "$step" portability 2>/dev/null)" || prev=""
  if [ -n "$prev" ] && printf '%s\n' "$prev" | grep -Fxq -- "$line"; then return 0; fi
  if [ -n "$prev" ]; then
    printf '%s\n%s\n' "$prev" "$line" | bash "$RA" --replace "$rec" "$step" portability - >/dev/null || rc=$?
  else
    printf '%s\n' "$line" | bash "$RA" "$rec" "$step" portability - >/dev/null || rc=$?
  fi
  [ "$rc" -eq 0 ] || die 5 "record-answer.sh refused the acceptance of $kind \"$text\" on $step (exit $rc)"
}

cmd_shipped() {
  local froot="$DEFAULT_FRAMEWORK_ROOT"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --framework-root) [ "$#" -ge 2 ] || die 2 "--framework-root needs a value"; froot="$2"; shift 2 ;;
      *) usage >&2; die 2 "unknown argument: $1" ;;
    esac
  done
  shipped_skills "$froot"
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
sub="$1"; shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  check) cmd_check "$@"; exit $? ;;
  accept) cmd_accept "$@"; exit $? ;;
  shipped-skills) cmd_shipped "$@"; exit $? ;;
  *) usage >&2; die 2 "unknown sub-command: $sub" ;;
esac

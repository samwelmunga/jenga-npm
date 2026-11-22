#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/extract-steps.sh - candidate steps from a finished process
# (epic E103, task E103_S02_T02)
#
# Reads ONE file that resolve-source.sh resolved (a Claude Code session transcript, or pasted text), lists the
# user's prompts numbered with timestamps so the USER picks the range that makes up the process (the agent never
# guesses it), and emits the candidate-steps file for that range in the format render-review-table.sh's header
# defines. User prompts are the steps; tool calls and assistant text are evidence attached to the step they follow,
# never steps of their own. Read-only on its input; it never sets, changes or reads the recorder's active-recording
# pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   extract-steps.sh list  [--current] [--kind <k>] [--json] <file>
#   extract-steps.sh range <from> <to> [--current] [--kind <k>] [--out <file>] <file>
#   extract-steps.sh -h | --help | help          this usage on stdout, exit 0
#
#   list          the prompts, one per line: "<n>  <timestamp>  <excerpt>" (n right-aligned to 3, timestamp
#                 YYYY-MM-DDTHH:MM:SSZ or "-" for pasted text, excerpt with whitespace collapsed, cut to 100
#                 characters). With --json: a JSON array of {n, timestamp, text} instead. A one-line note on stderr
#                 says how many prompts there are and, with --current, what was cut.
#   range         the candidate-steps file for prompts <from>..<to> (inclusive, 1 <= from <= to <= count),
#                 renumbered 1..k: row n is recording step step-%03d. On stdout, or with --out written atomically
#                 (a temporary file in the same directory, renamed into place, mode 600). Each row carries, beside
#                 the contract's n, text and evidence, two traceability fields render-review-table.sh ignores:
#                 "prompt" (the number list printed) and "timestamp" (or null). The top level adds "range".
#   --current     the file is the CURRENT session's transcript (resolve-source.sh form "current"): the capture
#                 invocation and everything after it are cut before numbering (see CURRENT SESSION).
#   --kind <k>    auto (default) | transcript | pasted. auto: a name ending in .jsonl, or a first non-blank line
#                 that is a JSON object, is a transcript; anything else is pasted text. Pass --kind transcript when
#                 resolve-source.sh said source "session-transcript"; leave auto for pasted content, since a pasted
#                 export of a session may itself be a transcript.
#   --out <file>  range only: write here instead of stdout. Its directory must exist.
#
# ---------------------------------------------------------------------------
# WHAT A PROMPT IS (transcript)
# ---------------------------------------------------------------------------
# A line of type "user" that is not "isMeta", not "isSidechain", whose "origin.kind" is "human" when an origin is
# present (task notifications and peer messages are not), and whose content is not a tool result. Its text is the
# string content, or the "text" items of an array content joined by newlines, with every embedded
# <system-reminder> block removed and outer whitespace trimmed. Then:
#   starts with <command-message> or <command-name>: /x and <command-args>a  becomes "/x a" (a slash command)
#   <bash-input>cmd</bash-input>                                         becomes "! cmd"
#   starts with <local-command-stdout|stderr|caveat>, <task-notification>, <system-reminder>, <bash-stdout|stderr>
#   or <user-prompt-submit-hook>                                         is not a prompt
#   empty after all this                                                  is not a prompt
# Shapes measured on this host's own transcripts on 2026-11-20 (structure only, no content was read).
#
# EVIDENCE: every non-sidechain "assistant" line between a prompt and the next one adds, in order,
#   "assistant: <text>"              each text item, whitespace collapsed, cut to 200 characters
#   "tool <Name>: <summary>"         each tool call; the summary is ONE input field (command, file_path, path,
#                                    notebook_path, pattern, url, query, skill and args, description, subject), else
#                                    only the input's key names; cut to 160 characters
# Tool results are never carried. At most 40 evidence items per step; a final "... <n> more" item says how many
# were left out. Evidence before the first prompt is dropped.
#
# SECRETS: a secret-looking value in a step's text or evidence is replaced by <redacted> before anything is
# written: a private-key block, URL user information, a bearer token, a "<name containing token, secret, password,
# passwd, pwd, api key, credential or private key>=<value>" (or ":") pair, and well-known token shapes (sk-...,
# ghp_..., github_pat_..., xox?-..., AKIA..., AIza...). A step whose text was redacted gets a first evidence item
# saying so, so the review proposes it as a secret parameter. A step's text is otherwise the prompt verbatim.
#
# ---------------------------------------------------------------------------
# CURRENT SESSION (--current)
# ---------------------------------------------------------------------------
# The capture invocation is the LAST of these structural markers in the transcript:
#   a non-sidechain assistant "Skill" tool call whose input.skill is j-workflow-capture or j.workflow-capture
#   (also with a "<plugin>:" prefix), owned by the prompt before it; or
#   a prompt that starts with /j-workflow-capture, /j.workflow-capture or j.workflow-capture.
# That prompt and every prompt after it are cut (the review conversation is never a candidate). No marker: exit 10;
# the end of the process is never guessed. Known limit: if the skill is invoked again during the capture
# conversation, the later invocation is the one used.
#
# ---------------------------------------------------------------------------
# PASTED TEXT
# ---------------------------------------------------------------------------
# When any line starts with a numbered marker ("1." or "1)" followed by text), each numbered item is one step: the
# marker is removed and the following non-blank lines up to the next item are added to its text, one per line,
# trimmed. Text before the first item becomes "context: ..." evidence of step 1. Otherwise every non-blank line is
# one step, with a leading bullet ("-", "*", "+", "•", "[ ]", "[x]") removed. Pasted steps have no timestamp.
#
# ---------------------------------------------------------------------------
# LAYOUT CHECKS (transcript) - the discipline of scripts/task-usage.sh --check-layout
# ---------------------------------------------------------------------------
# Run over the whole file before anything is printed; the first failing check decides the exit code, the message
# on stderr names the line and what was expected, and stdout stays empty. A partial result is never written.
#   4  a non-blank line is not a JSON object
#   5  a line has no string "type"
#   6  no line of type "user"; or a user line whose "message.content" is neither a string nor an array of objects
#      with a string "type", or that has no string "timestamp"
#   7  an assistant line whose "message.content" is neither an array nor a string
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success
#   2   usage error (unknown sub-command or option, a missing or non-positive range bound, from > to, --current
#       with pasted text, --out outside range)
#   3   environment: jq missing, render-review-table.sh missing, the file missing or unreadable
#   4-7 unrecognised transcript layout (see LAYOUT CHECKS)
#   8   no prompts: nothing in the file (after the current-session cut) is a prompt or a pasted step
#   9   the range is outside 1..<count>; the message gives the count
#  10   --current: no capture invocation found, so where the process ends cannot be told
#  11   the output could not be written (--out directory missing, rename failed) or the built file failed
#       render-review-table.sh --check; nothing was written
# Every message goes to stderr; on a non-zero exit stdout is empty and no output file is created or changed.
#
# Compatible with macOS bash 3.2 and safe under `set -u`. Content is data: nothing in it is evaluated.
# ---------------------------------------------------------------------------

set -u

SELF="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
RT="$HERE/render-review-table.sh"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  extract-steps.sh list  [--current] [--kind auto|transcript|pasted] [--json] <file>
  extract-steps.sh range <from> <to> [--current] [--kind auto|transcript|pasted] [--out <file>] <file>
  extract-steps.sh -h | --help | help

Lists the user prompts of a session transcript (or the steps of pasted text) numbered with timestamps, and emits
the candidate-steps file for the range the user picked: one step per prompt, tool calls and assistant text as
evidence only. --current cuts the capture invocation and everything after it. Layout checks, the prompt rule and
the exit codes: this script's header.
USAGE
}

CMD=""
FROM=""
TO=""
CURRENT=0
KIND="auto"
JSON=0
OUT=""
FILE=""
POS=()

[ "$#" -gt 0 ] || { usage >&2; die 2 "needs a sub-command: list or range"; }
case "$1" in
  -h|--help|help) usage; exit 0 ;;
  list|range) CMD="$1"; shift ;;
  *) usage >&2; die 2 "unknown sub-command: $1" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --current) CURRENT=1; shift ;;
    --json) JSON=1; shift ;;
    --kind) [ "$#" -ge 2 ] || die 2 "--kind needs a value"; KIND="$2"; shift 2 ;;
    --kind=*) KIND="${1#--kind=}"; shift ;;
    --out) [ "$#" -ge 2 ] || die 2 "--out needs a file"; OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) usage >&2; die 2 "unknown option: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done

case "$KIND" in auto|transcript|pasted) ;; *) die 2 "--kind must be auto, transcript or pasted, got \"$KIND\"" ;; esac

npos=0
[ -n "${POS[*]:-}" ] && npos="${#POS[@]}"
if [ "$CMD" = "list" ]; then
  [ -z "$OUT" ] || die 2 "--out belongs to range"
  [ "$npos" -eq 1 ] || { usage >&2; die 2 "list takes exactly one file"; }
  FILE="${POS[0]}"
else
  [ "$JSON" -eq 0 ] || die 2 "--json belongs to list"
  [ "$npos" -eq 3 ] || { usage >&2; die 2 "range takes <from> <to> <file>"; }
  FROM="${POS[0]}"; TO="${POS[1]}"; FILE="${POS[2]}"
  for b in "$FROM" "$TO"; do
    case "$b" in ''|*[!0-9]*|0*) die 2 "range bounds must be positive whole numbers, got \"$b\"" ;; esac
  done
  [ "$FROM" -le "$TO" ] || die 2 "range: <from> ($FROM) is after <to> ($TO)"
fi

command -v jq >/dev/null 2>&1 || die 3 "jq is required and was not found on PATH"
[ -f "$RT" ] || die 3 "render-review-table.sh not found next to this script: $RT"
[ -f "$FILE" ] || die 3 "no such file: $FILE"
[ -r "$FILE" ] || die 3 "file is not readable: $FILE"

if [ "$KIND" = "auto" ]; then
  KIND="pasted"
  case "$FILE" in
    *.jsonl) KIND="transcript" ;;
    *)
      first="$(awk 'NF { print; exit }' "$FILE")"
      if [ -n "$first" ] && printf '%s\n' "$first" | jq -e 'type == "object"' >/dev/null 2>&1; then
        KIND="transcript"
      fi
      ;;
  esac
fi
[ "$KIND" = "transcript" ] || [ "$CURRENT" -eq 0 ] || die 2 "--current applies to a session transcript, not pasted text"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/extract-steps.XXXXXX")" || die 11 "could not create a temporary directory"
trap 'rm -rf "$WORK"' EXIT
umask 077

# ---- shared jq definitions ---------------------------------------------------------------------------------------
JQ_DEFS='
  def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  def squash: gsub("\\s+"; " ") | trim;
  def cut($k): if length > $k then .[0:$k] + "..." else . end;
  def redact:
    gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "<redacted private key>")
    | gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/\\s:@]+:[^/\\s@]+@"; "\(.s)<redacted>@")
    | gsub("(?<b>[Bb][Ee][Aa][Rr][Ee][Rr]\\s+)[A-Za-z0-9._~+/=-]{8,}"; "\(.b)<redacted>")
    | gsub("(?<k>[A-Za-z0-9_.-]*(?:api[_-]?key|apikey|token|secret|password|passwd|pwd|credential|private[_-]?key)[A-Za-z0-9_.-]*)(?<sep>[ \\t]*[=:][ \\t]*)(?<q>[\"'"'"']?)(?!<redacted>)[^\\s\"'"'"',;]+"; "\(.k)\(.sep)\(.q)<redacted>"; "i")
    | gsub("(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})"; "<redacted>");
  def redact_note($orig): if . != $orig then ["note: a secret-looking value in this step was replaced by <redacted>; propose it as a secret parameter"] else [] end;
  def cap_evidence: if length > 40 then .[0:40] + ["... \(length - 40) more"] else . end;
'

# ---- transcript: layout checks, prompts, evidence, current-session cut --------------------------------------------
JQ_TRANSCRIPT='
  def err($c; $m): {error: {code: $c, message: $m}};
  def noise: ["local-command-stdout","local-command-stderr","local-command-caveat","task-notification",
              "system-reminder","bash-stdout","bash-stderr","user-prompt-submit-hook"];
  def normalise_prompt:
    gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") | trim
    | if test("^<command-(message|name)>") then
        ([capture("<command-name>(?<n>[\\s\\S]*?)</command-name>")] | .[0].n // "" | trim) as $n
        | ([capture("<command-args>(?<a>[\\s\\S]*?)</command-args>")] | .[0].a // "" | trim) as $a
        | if $n == "" then null
          else ($n | if startswith("/") then . else "/" + . end) + (if $a == "" then "" else " " + $a end) end
      elif test("^<bash-input>") then
        ([capture("^<bash-input>(?<c>[\\s\\S]*?)</bash-input>")] | .[0].c // "" | trim) as $c
        | if $c == "" then null else "! " + $c end
      elif test("^<[A-Za-z-]+>") and ((capture("^<(?<t>[A-Za-z-]+)>").t) as $t | any(noise[]; . == $t)) then null
      elif . == "" then null
      else . end;
  def prompt_text:
    if .type != "user" or .isMeta == true or .isSidechain == true then null
    elif (.origin | type) == "object" and .origin.kind != "human" then null
    else .message.content as $c
      | if ($c | type) == "string" then ($c | normalise_prompt)
        elif any($c[]; .type == "tool_result") then null
        else ([$c[] | select(.type == "text") | .text | strings] | join("\n") | normalise_prompt) end
    end;
  def is_capture_skill: tostring | test("(^|[:/])j[.-]workflow-capture$");
  def is_capture_prompt: test("^/?j[.-]workflow-capture(\\s|$)");
  def assistant_items: .message.content | if type == "string" then [{type: "text", text: .}] elif type == "array" then . else [] end;
  def is_marker_assistant: any(assistant_items[]; .type == "tool_use" and .name == "Skill" and ((.input.skill // "") | is_capture_skill));
  def tool_summary:
    (.input // {}) as $in
    | if ($in | type) != "object" then ""
      else ($in.command // $in.file_path // $in.path // $in.notebook_path // $in.pattern // $in.url // $in.query
            // (if $in.skill != null then ($in.skill | tostring) + (if $in.args != null then " " + ($in.args | tostring) else "" end) else null end)
            // $in.description // $in.subject // null) as $v
        | if $v != null then ($v | tostring) else "(" + ($in | keys | join(", ")) + ")" end
      end;
  def evidence_items:
    assistant_items[]
    | if .type == "text" and ((.text // "") | type) == "string" and ((.text // "") | test("\\S")) then "assistant: " + (.text | redact | squash | cut(200))
      elif .type == "tool_use" then "tool " + ((.name // "?") | tostring) + ": " + (tool_summary | redact | squash | cut(160))
      else empty end;

  [inputs | sub("\r$"; "")] | to_entries
  | [ .[] | select(.value | test("\\S")) | {ln: (.key + 1)} + (.value | try {ok: true, v: fromjson} catch {ok: false}) ] as $lines
  | ([$lines[] | select((.ok and (.v | type) == "object") | not)] | .[0]) as $b4
  | if $b4 != null then err(4; "unrecognised transcript layout: line \($b4.ln) is not a JSON object (every line of a session transcript is one)")
    else
      ([$lines[] | select((.v.type | type) != "string")] | .[0]) as $b5
      | if $b5 != null then err(5; "unrecognised transcript layout: line \($b5.ln) has no string \"type\" field")
        else
          [$lines[] | select(.v.type == "user")] as $users
          | ([$users[] | select(
                (.v.message | type) != "object"
                or ((.v.message.content | type) as $t | $t != "string" and $t != "array")
                or ((.v.message.content | type) == "array" and any(.v.message.content[]; (type != "object") or ((.type | type) != "string")))
                or ((.v.timestamp | type) != "string"))] | .[0]) as $b6
          | if ($users | length) == 0 then err(6; "unrecognised transcript layout: no line of type \"user\", so there are no prompts to read")
            elif $b6 != null then err(6; "unrecognised transcript layout: line \($b6.ln) is a user line without a string \"timestamp\" or a \"message.content\" that is a string or an array of typed objects")
            else
              ([$lines[] | select(.v.type == "assistant" and ((.v.message.content | type) as $t | $t != "string" and $t != "array"))] | .[0]) as $b7
              | if $b7 != null then err(7; "unrecognised transcript layout: line \($b7.ln) is an assistant line whose \"message.content\" is neither an array nor a string")
                else
                  reduce ($lines[] | .v) as $o ({prompts: [], marker: null};
                    ($o | prompt_text) as $p
                    | if $p != null then
                        ($p | redact) as $r
                        | .prompts += [{text: $r, timestamp: $o.timestamp, evidence: ($r | redact_note($p))}]
                        | if ($p | is_capture_prompt) then .marker = ((.prompts | length) - 1) else . end
                      elif $o.type == "assistant" and $o.isSidechain != true then
                        (if ($o | is_marker_assistant) then .marker = ([(.prompts | length) - 1, 0] | max) else . end)
                        | if (.prompts | length) > 0 then ((.prompts | length) - 1) as $i | .prompts[$i].evidence += [$o | evidence_items] else . end
                      else . end)
                  | if $current and .marker == null then err(10; "current session: no capture invocation (a Skill call or a /j-workflow-capture prompt) was found in the transcript, so where the process ends cannot be told")
                    else
                      (if $current then .marker else (.prompts | length) end) as $m
                      | {prompts: [.prompts[0:$m] | to_entries[] | {n: (.key + 1), timestamp: .value.timestamp, text: .value.text, evidence: (.value.evidence | cap_evidence)}],
                         cut: (if $current then {at: ($m + 1), dropped: ((.prompts | length) - $m)} else null end)}
                    end
                end
            end
        end
    end
'

# ---- pasted text: numbered items, else one step per line ---------------------------------------------------------
JQ_PASTED='
  def item_re: "^\\s*[0-9]+[.)]\\s+\\S";
  [inputs | sub("\r$"; "") | sub("\\s+$"; "")] as $L
  | (if any($L[]; test(item_re)) then
      reduce $L[] as $l ({items: [], pre: []};
        if ($l | test(item_re)) then .items += [($l | sub("^\\s*[0-9]+[.)]\\s+"; ""))]
        elif ($l | test("\\S")) then
          if (.items | length) == 0 then .pre += [$l | trim]
          else ((.items | length) - 1) as $i | .items[$i] += "\n" + ($l | trim) end
        else . end)
      | .pre as $pre
      | [.items | to_entries[] | {text: .value, ctx: (if .key == 0 and ($pre | length) > 0 then ["context: " + ($pre | join(" ") | redact | squash | cut(200))] else [] end)}]
    else
      [$L[] | select(test("\\S")) | sub("^\\s*(?:[-*+•]|\\[[ xX]\\])\\s+"; "") | trim | {text: ., ctx: []}]
    end)
  | {prompts: [to_entries[] | .value.text as $o | (.value.text | redact) as $r
               | {n: (.key + 1), timestamp: null, text: $r, evidence: (($r | redact_note($o)) + .value.ctx)}],
     cut: null}
'

PARSED="$WORK/parsed.json"
if [ "$KIND" = "transcript" ]; then
  cur=false; [ "$CURRENT" -eq 1 ] && cur=true
  jq -R -n -c --argjson current "$cur" "$JQ_DEFS$JQ_TRANSCRIPT" "$FILE" >"$PARSED" 2>"$WORK/jq.err" \
    || die 4 "unrecognised transcript layout: the file could not be read as lines of JSON ($(head -c 300 "$WORK/jq.err"))"
else
  jq -R -n -c "$JQ_DEFS$JQ_PASTED" "$FILE" >"$PARSED" 2>"$WORK/jq.err" \
    || die 8 "the pasted text could not be read ($(head -c 300 "$WORK/jq.err"))"
fi

code="$(jq -r '.error.code // empty' "$PARSED")"
if [ -n "$code" ]; then
  die "$code" "$(jq -r '.error.message' "$PARSED"): $FILE"
fi

COUNT="$(jq -r '.prompts | length' "$PARSED")"
if [ "$COUNT" -eq 0 ]; then
  if [ "$CURRENT" -eq 1 ]; then
    die 8 "no prompts before the capture invocation in $FILE; nothing to capture from this session"
  fi
  die 8 "no prompts found in $FILE"
fi

note() {
  local cut
  cut="$(jq -r 'if .cut == null then "" else "; prompt \(.cut.at) (the capture invocation) and the \(.cut.dropped - 1) prompt(s) after it are excluded" end' "$PARSED")"
  if [ "$KIND" = "pasted" ]; then
    printf '%s: %s step(s) in pasted text\n' "$SELF" "$COUNT" >&2
  else
    printf '%s: %s prompt(s)%s\n' "$SELF" "$COUNT" "$cut" >&2
  fi
}

if [ "$CMD" = "list" ]; then
  if [ "$JSON" -eq 1 ]; then
    jq -c '[.prompts[] | {n, timestamp, text}]' "$PARSED" || die 11 "could not render the list"
  else
    jq -r "$JQ_DEFS"'.prompts[] | "\(.n | tostring | if length < 3 then ("   " + .)[-3:] else . end)  \(.timestamp // "-" | sub("\\.[0-9]+Z$"; "Z"))  \(.text | squash | cut(100))"' "$PARSED" \
      || die 11 "could not render the list"
  fi
  note
  exit 0
fi

# ---- range ---------------------------------------------------------------------------------------------------------
if [ "$TO" -gt "$COUNT" ]; then
  die 9 "range $FROM..$TO is outside 1..$COUNT ($COUNT prompt(s) to choose from)"
fi

BUILT="$WORK/candidates.json"
jq --argjson from "$FROM" --argjson to "$TO" '
  {candidate_steps_version: 1,
   range: {from: $from, to: $to},
   steps: [.prompts[($from - 1):$to] | to_entries[]
           | {n: (.key + 1), text: .value.text, evidence: .value.evidence, prompt: .value.n, timestamp: .value.timestamp}]}
' "$PARSED" >"$BUILT" 2>/dev/null || die 11 "could not build the candidate-steps file; nothing was written"

if ! check_err="$(bash "$RT" --check "$BUILT" 2>&1)"; then
  die 11 "the built candidate-steps file failed render-review-table.sh --check; nothing was written: $check_err"
fi

if [ -z "$OUT" ]; then
  cat "$BUILT"
  exit 0
fi

out_dir="$(dirname "$OUT")"
[ -d "$out_dir" ] || die 11 "--out directory does not exist: $out_dir; nothing was written"
tmp_out="$(mktemp "$out_dir/.extract-steps.XXXXXX")" || die 11 "could not create a temporary file in $out_dir; nothing was written"
if ! cat "$BUILT" >"$tmp_out" || ! chmod 600 "$tmp_out" || ! mv -f "$tmp_out" "$OUT"; then
  rm -f "$tmp_out"
  die 11 "could not write $OUT; nothing was written"
fi
printf '%s: wrote %s candidate step(s) (prompts %s..%s) to %s\n' "$SELF" "$((TO - FROM + 1))" "$FROM" "$TO" "$OUT" >&2
exit 0

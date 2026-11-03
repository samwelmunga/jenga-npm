#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hooks/on_recording_step.sh - tier 1 of the session recorder: capture (epic E89, task E89_S02_T03)
#
# A UserPromptSubmit hook. On each user interaction it appends ONE step, VERBATIM, to the recording
# document named by the active-recording pointer. That is its whole job, and the job is phrased that
# narrowly on purpose: this tier's only responsibility is that NOTHING IS EVER LOST. It runs whether or
# not an agent is paying attention, whether or not the turn survived, and whether or not the context was
# summarised.
#
# Specified by workflow-recorder-observation-decision.md, under the documentation root that
# scripts/resolve-root.sh resolves (task E89_S02_T01), which chose the hook route over a resident turn
# loop. Section references below (§4, §5.1, §6, §7, §8, §11) are to that document.
#
# (No path in this file - comments included - is written as a tree-root literal. That is this task's
# final acceptance criterion, which is checked by a mechanical grep rather than by reading, so prose
# that merely MENTIONS such a path would fail it just as code would. The criterion also shapes the
# no-op path; see "THE COST OF THE NO-RECORDING PATH" below.)
#
# Registration in the six settings files - the root settings.json plus the five permission-level
# templates - is a separate task and is deliberately NOT done by the file that defines this behaviour.
#
# ---------------------------------------------------------------------------
# WHY A HOOK AT ALL: THE DURABILITY ARGUMENT (§5)
# ---------------------------------------------------------------------------
# The story this belongs to requires that a recording survive a context summarisation mid-session and
# keep appending to the SAME file. A resident turn loop cannot: its knowledge of the active recording
# lives in conversation state, which is exactly what a summarisation is free to discard.
#
# A hook does not merely survive that - it is INCAPABLE of failing it. A hook is a fresh process per
# event. It holds no state, so it cannot remember a path, so it MUST read the pointer from disk on every
# single invocation. The durability requirement is therefore not a rule this script has to remember to
# follow; it is the only thing this script can do. A summarisation discards conversation state and does
# not touch the pointer directory. That asymmetry is the whole technical case for this design.
#
# The boundary, so it is not mistaken for more: the pointer is SESSION-KEYED. A summarisation keeps the
# same session, hence the same key, hence the same pointer - the required case works. A DIFFERENT
# session computes a different key and will not find the pointer, so a recording does not resume across
# a session restart. Nothing here should be read as providing that.
#
# ---------------------------------------------------------------------------
# THE SESSION-KEY PROBLEM - THE SHARPEST FAILURE MODE IN THIS DESIGN (§5.1)
# ---------------------------------------------------------------------------
# The recorder has two processes that must agree on one session key:
#
#   WRITER: the skill body's "active-recording.sh set", run in the SESSION environment.
#   READER: this hook's "active-recording.sh get", run in a HOOK SUBPROCESS.
#
# If those resolve DIFFERENT keys, get returns exit 3 forever and the recorder silently records nothing.
# No error, no warning, no output - just an empty document that looks like a working recording. That is
# the one defect that would make this whole feature appear to work while doing nothing, so it is the
# thing this script is built around rather than an edge case handled at the end.
#
# active-recording.sh's own probe order is:
#     --session > JENGA_RECORDING_SESSION_ID > CLAUDE_CODE_SESSION_ID > JENGA_SESSION_ID   (exit 7: none)
#
# This hook resolves its key the way the WorktreeCreate registration in settings.json does - prefer the
# environment, else fall back to the stdin payload's .session_id - and NOT the way
# hooks/on_preflight_check.sh does. That script's "SESSION KEYING AND THE RUN ID" section deliberately
# passes no --session and lets the callee read the environment, and it is right to, because its writer
# and its reader share an environment. The recorder's do not. Do not copy that reasoning here.
#
# Three decisions beyond the specification, each load-bearing:
#
#   1. JENGA_SESSION_ID IS DELIBERATELY EXCLUDED from this hook's probe, even though
#      active-recording.sh would accept it. hooks/on_session_end.sh's own comment (around line 53)
#      records that lib/resolve-project-dir.sh invents a FRESH UUID for JENGA_SESSION_ID, so that value
#      "never matches the key the state file was written under". A key source regenerated per process
#      is unusable for cross-process agreement, which is the only thing a key is for here. Neither
#      precedent - WorktreeCreate, on_session_end.sh - consults it either.
#
#   2. THE RESOLVED KEY IS ALWAYS PASSED EXPLICITLY AS --session. This is what makes (1) a mechanism
#      rather than a comment: with --session given, active-recording.sh's probe stops at the first
#      entry and can never fall through to JENGA_SESSION_ID inside this subprocess.
#
#   3. TWO CANDIDATE KEYS ARE TRIED, IN ORDER - not one. When the environment and the payload both
#      yield a key AND THEY DIFFER, this hook tries the environment key first and, on exit 3 (nothing
#      active) or exit 2 (malformed key), retries with the payload key. In the common case - they agree,
#      or only one of them exists - the second candidate is never reached and this costs nothing.
#
#      This is NOT a scan of the pointer directory for "whatever recording happens to be live". Such a
#      scan would let a stale pointer from a dead session hijack an unrelated one, and §5's boundary
#      above explicitly rules it out. Both candidates here are identities OF THIS SESSION, supplied by
#      the harness, so no other session's pointer is reachable through either of them.
#
# WHAT THIS STILL DOES NOT COVER, stated plainly rather than papered over: if the skill body's "set"
# resolved its key from JENGA_SESSION_ID - because neither JENGA_RECORDING_SESSION_ID nor
# CLAUDE_CODE_SESSION_ID was set in the session - that value is a per-process uuid this hook cannot
# reconstruct, and the two will not agree. Measured during this task: CLAUDE_CODE_SESSION_ID IS present
# in this harness's session shell, so the reachable case is the live one. --probe below exists so that
# if this ever does go wrong, it is diagnosable in one command instead of discovered as an empty file.
#
# ---------------------------------------------------------------------------
# THE FOUR SAFETY RULES, AND WHY THEY ARE NOT OPTIONAL HARDENING (§6)
# ---------------------------------------------------------------------------
# UserPromptSubmit sits BETWEEN THE USER AND THE MODEL. It is the one event a hook can use to damage a
# session, and a recorder that gets it wrong is worse than no recorder at all.
#
#   1. NEVER WRITE TO STDOUT. Under Claude Code a UserPromptSubmit hook's stdout is injected into the
#      model's context, so anything echoed pollutes every turn of every session. This is enforced
#      STRUCTURALLY, not by discipline: `exec 1>/dev/null` on the first working line means no branch of
#      this script - present or future, including an error path or a stray debug line - can write to
#      stdout at all. Command substitution still captures a callee's stdout, because $(...) reads that
#      command's own fd 1 and not this script's.
#      (This rule exists because the pattern is live elsewhere: hooks/prompt_router_helper.js writes
#      JSON.stringify(input) to stdout on all four of its exit paths, and lib/inject-settings.js
#      registers that hook in every project scaffolded by `jenga init`. Not this script's to fix - but
#      precisely the thing not to inherit, and one of §7's three reasons for a new script rather than
#      extending that one.)
#
#   2. ALWAYS EXIT 0. A non-zero exit from UserPromptSubmit can block prompt processing and ERASE THE
#      USER'S PROMPT. Enforced structurally too: the body runs as a function whose failure is swallowed,
#      and the script ends in a literal `exit 0`. A broken state file, a missing jq AND python3, an
#      unresolvable root, empty or malformed stdin, a read-only filesystem, a nonexistent recording and
#      a stdin timeout all end the same way - silently, successfully, having recorded nothing.
#      FAIL-OPEN. That is the recorder's class. It is the opposite of hooks/on_preflight_check.sh, which
#      is a fail-CLOSED safety gate that refuses tool calls; §4.2 requires the two classes stay in
#      separate scripts on separate events precisely so the failure modes cannot mix.
#
#   3. SILENT NO-OP WITH NO ACTIVE RECORDING. A user who never runs the recorder must not be able to
#      tell it is installed. So stderr is sent to /dev/null too unless --probe asked for it, which also
#      stops a callee's diagnostics leaking into an ordinary session.
#
#   4. KEEP THE NO-OP PATH CHEAP - AND MEASURE IT. See the next block.
#
# ---------------------------------------------------------------------------
# THE COST OF THE NO-RECORDING PATH, AND THE CONSTRAINT THAT SHAPES IT (§6 rule 4)
# ---------------------------------------------------------------------------
# This hook fires on every user prompt in every session, including every session that never records
# anything. Measured on this machine, 40 iterations each:
#
#     bare-bash floor .................................  9.9 ms/call
#     resolve-root.sh get queue .......................  30.3 ms/call
#     active-recording.sh get (nothing active) ........ 131.7 ms/call
#
# The 131.7 ms independently confirms the ~110-130 ms §4.2 measured, and it is why asking
# active-recording.sh "is anything active" on every prompt is not the no-op path.
#
# §6 rule 4 recommends the ZERO-SUBPROCESS stage 1 that hooks/on_preflight_check.sh uses: no fork, no
# exec, no $(...), locating state by an upward walk for that script's hardcoded workflow.json registry
# path and reading paths.queue out of it with the read builtin. THAT TECHNIQUE IS NOT AVAILABLE HERE,
# and the reason is a hard requirement rather than a preference: this task's final acceptance criterion
# forbids any hardcoded tree-root literal in a file it adds, and the upward walk IS such a literal.
# §6 rule 4 is explicitly advisory ("Advisory, not a hard requirement - but measure it"), the
# acceptance criterion is not, so the criterion wins. The cost of that compliance is one subprocess on
# the no-op path, recorded here rather than left for someone to rediscover.
#
# The cheapest compliant path, in two stages:
#
#   STAGE 1a, zero subprocesses: with JENGA_RECORDING_STATE_DIR set (the test seam, and the only way to
#            name the directory without resolving a root), glob it directly. stdin is drained with the
#            read BUILTIN, and this script's own directory comes from parameter expansion (${0%/*}),
#            not dirname - so this stage genuinely forks nothing.
#   STAGE 1b, one subprocess: resolve-root.sh get queue, then a pure-bash glob. If no pointer file
#            exists, return - having spawned neither python3 nor active-recording.sh.
#   STAGE 2,  only once some pointer file exists: parse the payload, filter, get, append.
#
# The glob matches ANY pointer file rather than this session's digest, because computing that digest
# needs sha256 and therefore a subprocess - the same trade on_preflight_check.sh makes for its own fast
# reject ("a glob, not a digest lookup"). A pointer belonging to another session therefore costs one
# wasted stage 2 whose `get` correctly finds nothing. Cheap and correct, in that order.
#
# MEASURED RESULT for this script, same machine and method, with no recording active anywhere in the
# tree (i.e. the ordinary session, and the only figure that matters for a user who never records):
#
#     bare-bash floor .................................   8.0 ms/call
#     on_recording_step.sh, no recording ..............  32.2 ms/call   <-- this hook's no-op path
#     active-recording.sh get (what it avoids) ........ 117.7 ms/call
#
# So the two-stage fast reject costs about 24 ms over the floor and saves about 86 ms per prompt against
# the naive "just ask get" implementation - a 3.7x improvement, with the residue being the one
# resolve-root.sh call the acceptance criterion requires. §4.2's budget argument is that ~110 ms once
# per USER PROMPT is already noise against seconds of model latency (which is what makes this event
# viable where PreToolUse is not); 32 ms sits comfortably inside that, measured rather than asserted.
#
# CORRECTNESS IS NEVER TRADED FOR THE FAST PATH, only speed - the property on_preflight_check.sh states
# for its own accelerator. If the queue directory cannot be resolved, this hook records nothing for that
# invocation; it does not guess a location. A recorder that writes to a path it invented would be worse
# than one that misses a step.
#
# ---------------------------------------------------------------------------
# WHAT THIS HOOK DOES NOT DECIDE (§8) - AND WHY THAT IS THE POINT
# ---------------------------------------------------------------------------
# NO SEMANTIC FILTERING WHATSOEVER. This hook does not judge which prompts matter, does not skip a
# prompt it considers unimportant, and does not summarise. It captures verbatim.
#
# That is not laziness, it is the division of labour the design rests on. Interpretation - is this a
# deviation, is this a plausible final step, is this merely a clarifying question - is tier 2, performed
# by the Scrum Master against the steps this tier captured, and is specified separately. A shell script
# has no model and cannot make those calls, and a hook that pretended to would produce a record whose
# gaps are invisible. The resulting asymmetry is deliberate and correct: a step captured but never
# interpreted is still in the document, merely uninterpreted. A recording with a gap in its PROSE is
# recoverable. A recording with a gap in its RECORD is not.
#
# The only exclusions here are cheap and deterministic, and each is an absence of content or a statement
# about the recording rather than a step in the process being recorded:
#
#   - no active recording (get exits 3);
#   - an empty or whitespace-only prompt;
#   - a prompt whose FIRST TOKEN is an invocation of the recorder skill itself (j.workflow-recorder,
#     /j-workflow-recorder and the two mixed spellings) - "stop the recording" is scaffolding ABOUT the
#     recording, not a step IN the process. Matched on the first token, so a prompt that merely MENTIONS
#     the skill is recorded normally. Matched case-sensitively against the canonical spellings: a
#     differently-cased invocation is captured as a step, which is harmless - tier 2 can annotate it -
#     and is preferred over the alternative error of dropping a real step.
#
# Why UserPromptSubmit is the event, and PreToolUse is not (§4): the unit of what is being recorded is
# one user interaction, which is exactly one UserPromptSubmit - a one-to-one mapping needing no
# inference. PreToolUse fires on every Bash, Task and Agent call, dozens per interaction, which yields a
# transcript of mechanics rather than a process document; it costs ~10x more on a path that fires ~100x
# more often; and that slot is occupied by a fail-closed gate (rule 2 above). Not a step source here.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   on_recording_step.sh                  the hook. Reads the JSON payload on stdin. Silent, exit 0.
#   on_recording_step.sh --probe          same, plus a diagnosis on STDERR of what it decided and why.
#   on_recording_step.sh -h | --help      print this usage on stderr, exit 0.
#
# Registered as a UserPromptSubmit command hook, with no arguments.
#
# --probe closes §11's one open item. That section records that no live Claude-side UserPromptSubmit
# payload has been captured in this repo - the expected shape is session_id, transcript_path, cwd,
# hook_event_name, prompt, and the load-bearing fields are `prompt` (the step text) and `session_id`
# (the pointer key) - and suggests a throwaway one-shot probe on first run. A permanent, off-by-default
# mode is strictly better than a probe someone has to add and then remember to remove: it is
# repeatable, it needs no edit-and-revert of a registered hook, and it stays available for the whole
# life of the feature. It reports which payload fields arrived, which key source won, the resolved key
# and its digest, and get's exit code - which is to say, it converts this design's one SILENT failure
# into a diagnosable one. Diagnostics go to stderr; rule 1 admits no exception for debugging.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT
# ---------------------------------------------------------------------------
#   JENGA_RECORDING_STATE_DIR     the pointer directory, bypassing root resolution. The test seam, and
#                                 stage 1a's zero-subprocess path. Read by active-recording.sh too, so
#                                 setting it here and there stays consistent by construction.
#   JENGA_RECORDING_SESSION_ID    first session-key candidate. See the session-key block above.
#   CLAUDE_CODE_SESSION_ID        second. JENGA_SESSION_ID is deliberately NOT consulted.
#   JENGA_RECORDING_HOOK_DEBUG    any non-empty value turns on --probe without changing the
#                                 registration - for diagnosing a live session in place.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   always, unconditionally, by rule 2. There is no other exit code and there must never be one.
#       Whether anything was recorded is NOT reported through the exit status; use --probe.
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions) and safe
# under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

# Rule 1, structurally: nothing this script does can reach stdout from here on.
exec 1>/dev/null

# Mirrors active-recording.sh's STATE_SUBDIR. Duplicated because reading it out of that script would
# cost a subprocess on the no-op path, which is the one thing this hook must not spend. The duplication
# is made safe by a test that asserts the two agree, rather than by hoping nobody changes one of them.
STATE_SUBDIR="active-recordings"

# This script's directory, by parameter expansion rather than dirname: stage 1a forks nothing.
SELF_DIR="${0%/*}"
[ "$SELF_DIR" = "$0" ] && SELF_DIR="."
TREE="$SELF_DIR/.."

RESOLVE_ROOT="$TREE/scripts/resolve-root.sh"
RECORDER_SCRIPTS="$TREE/skills/j-workflow-recorder/scripts"
ACTIVE_RECORDING="$RECORDER_SCRIPTS/active-recording.sh"
RECORDING_FILE="$RECORDER_SCRIPTS/recording-file.sh"

PROBE=0
case "${1:-}" in
  --probe) PROBE=1 ;;
  -h|--help|help)
    # Usage on stderr, never stdout (rule 1). sed, not cat, so the shebang and the rule line are skipped.
    sed -n '3,230p' "$0" >&2 2>/dev/null || true
    exit 0
    ;;
esac
[ -n "${JENGA_RECORDING_HOOK_DEBUG:-}" ] && PROBE=1

# Rule 3: silent unless asked. Also keeps a callee's stderr out of an ordinary session.
[ "$PROBE" -eq 1 ] || exec 2>/dev/null

diag() {
  [ "$PROBE" -eq 1 ] && printf 'on_recording_step: %s\n' "$*" >&2
  return 0
}

# True when "$1" holds at least one pointer file. Pure bash, no subprocess - the fast reject.
has_pointer() {
  [ -d "$1" ] || return 1
  set -- "$1"/recording-*.json
  if [ "$#" -eq 1 ] && [ ! -e "$1" ]; then
    return 1
  fi
  return 0
}

# Prints one top-level string field of the payload. jq first (the repo's convention in
# on_session_end.sh and on_preflight_check.sh), python3 as the fallback, empty when neither exists -
# which rule 2 turns into a silent no-op rather than an error. The type check matters: a payload whose
# `prompt` is null or a number must read as absent, not as the string "null".
#
# NOTE ON STDERR, here and at every other callee below: these calls deliberately do NOT append
# 2>/dev/null. Rule 3 is already enforced once, structurally, by the `exec 2>/dev/null` above, and a
# child inherits that fd - so an ordinary run is silent without per-call redirection, while a --probe
# run gets the callee's own diagnostics (a jq parse error, a resolver complaint, a refusal from
# active-recording.sh) instead of having them thrown away at the exact moment someone is debugging.
payload_field() {
  local field="$1" out=""
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$PAYLOAD" | jq -r --arg f "$field" 'if (.[$f] | type) == "string" then .[$f] else empty end')" || out=""
  elif command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get(sys.argv[1], "")
except Exception:
    v = ""
sys.stdout.write(v if isinstance(v, str) else "")
' "$field")" || out=""
  fi
  printf '%s' "$out"
}

# True when the prompt is an invocation of the recorder skill itself. First token only; see §8 block.
is_control_command() {
  local s="$1" first
  # Trim leading whitespace so a prompt that begins with a space or newline is still recognised.
  while :; do
    case "$s" in
      [[:space:]]*) s="${s#?}" ;;
      *) break ;;
    esac
  done
  first="${s%%[[:space:]]*}"
  case "$first" in
    j.workflow-recorder|/j-workflow-recorder|/j.workflow-recorder|j-workflow-recorder) return 0 ;;
  esac
  return 1
}

main() {
  # ---- Stage 1a: drain stdin with the read builtin. Zero subprocesses. ----
  # The timeout keeps an idle, never-closed pipe from stalling a user's prompt (read -t with an integer
  # works on stock macOS bash 3.2); a timeout leaves whatever arrived in the variable, which the JSON
  # parse below rejects if it is not a complete object. The technique is on_session_end.sh's.
  PAYLOAD=""
  if [ ! -t 0 ]; then
    IFS= read -r -t 1 -d '' PAYLOAD 2>/dev/null || true
  fi

  # ---- Stage 1a/1b: locate the pointer directory and fast-reject. ----
  local state_dir="" queue=""
  if [ -n "${JENGA_RECORDING_STATE_DIR:-}" ]; then
    state_dir="$JENGA_RECORDING_STATE_DIR"
  elif [ -f "$RESOLVE_ROOT" ]; then
    queue="$(bash "$RESOLVE_ROOT" get queue)" || queue=""
    [ -n "$queue" ] && state_dir="$queue/$STATE_SUBDIR"
  fi
  if [ -z "$state_dir" ]; then
    diag "no pointer directory could be located (JENGA_RECORDING_STATE_DIR unset and the queue root did not resolve); recorded nothing"
    return 0
  fi
  if ! has_pointer "$state_dir"; then
    diag "fast reject: no recording-*.json in $state_dir, so no recording is active anywhere in this tree"
    return 0
  fi
  diag "pointer directory $state_dir holds at least one pointer; continuing to stage 2"

  # ---- Stage 2: a pointer exists. Only now is anything expensive spent. ----
  [ -x "$ACTIVE_RECORDING" ] || [ -f "$ACTIVE_RECORDING" ] || { diag "active-recording.sh not found at $ACTIVE_RECORDING"; return 0; }
  [ -f "$RECORDING_FILE" ] || { diag "recording-file.sh not found at $RECORDING_FILE"; return 0; }

  local prompt key_env="" key_env_src="" key_payload=""
  prompt="$(payload_field prompt)"
  key_payload="$(payload_field session_id)"

  if [ -n "${JENGA_RECORDING_SESSION_ID:-}" ]; then
    key_env="$JENGA_RECORDING_SESSION_ID"; key_env_src="env:JENGA_RECORDING_SESSION_ID"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    key_env="$CLAUDE_CODE_SESSION_ID"; key_env_src="env:CLAUDE_CODE_SESSION_ID"
  fi

  # §11's verification, reported on every probe run rather than once on first install. Guarded rather
  # than built unconditionally: the command substitutions below would otherwise fork on every stage-2
  # invocation just to assemble a string nothing is going to print.
  if [ "$PROBE" -eq 1 ]; then
    diag "payload: $([ -n "$PAYLOAD" ] && echo present || echo "EMPTY OR UNREADABLE"); prompt field $([ -n "$prompt" ] && echo "present (${#prompt} chars)" || echo MISSING); session_id field $([ -n "$key_payload" ] && echo present || echo MISSING)"
    diag "key candidates: environment=$([ -n "$key_env" ] && echo "$key_env ($key_env_src)" || echo none), payload=$([ -n "$key_payload" ] && echo "$key_payload (payload:.session_id)" || echo none)"
  fi

  # Deterministic exclusions only (§8). Nothing semantic.
  # A prompt holding at least one non-whitespace character is content; anything else is an absence of
  # content and is collapsed to empty so the single check below covers both cases.
  case "$prompt" in
    *[![:space:]]*) : ;;
    *) prompt="" ;;
  esac
  if [ -z "$prompt" ]; then
    diag "excluded: the prompt is empty or whitespace only"
    return 0
  fi
  if is_control_command "$prompt"; then
    diag "excluded: the prompt's first token invokes the recorder skill itself, which is scaffolding about the recording rather than a step in the process"
    return 0
  fi

  # ---- The two candidate keys, in order (§5.1 decision 3). ----
  local cand rec="" used_key="" used_src="" rc
  for cand in env payload; do
    local k="" src=""
    if [ "$cand" = env ]; then
      k="$key_env"; src="$key_env_src"
    else
      k="$key_payload"; src="payload:.session_id"
      # Skip a payload candidate identical to the environment one already tried.
      [ -n "$key_env" ] && [ "$k" = "$key_env" ] && continue
    fi
    [ -n "$k" ] || continue
    rec="$(bash "$ACTIVE_RECORDING" get --session "$k")"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$rec" ]; then
      used_key="$k"; used_src="$src"
      break
    fi
    diag "candidate $src ($k) found no active recording (get exit $rc)"
    rec=""
    # exit 3 (nothing active) and exit 2 (malformed key) are both worth trying the next candidate for;
    # any other code is a real fault in the pointer layer, which rule 2 turns into a silent no-op.
    case "$rc" in
      2|3) : ;;
      *) diag "get failed with exit $rc, which is not a 'nothing active' answer; recorded nothing"; return 0 ;;
    esac
  done

  if [ -z "$rec" ]; then
    diag "NO ACTIVE RECORDING for any candidate key. If a recording IS running, this is the session-key disagreement described in this script's header - compare the key the skill body's 'set' used against the candidates above."
    return 0
  fi
  diag "active recording: $rec (key $used_key via $used_src)"

  # ---- The append. Verbatim, through the one writer that owns the step format. ----
  # The '-' form reads the step text from stdin, which is the multi-line form: nothing is reflowed,
  # escaped or truncated. Command substitution above stripped any trailing newlines from the prompt,
  # which is formatting rather than content; everything else arrives exactly as the user typed it.
  printf '%s' "$prompt" | bash "$RECORDING_FILE" append "$rec" -
  rc=$?
  if [ "$rc" -eq 0 ]; then
    diag "appended one step (${#prompt} chars) to $rec"
  else
    # Fail-open (rule 2): 3 the file is gone, 5 it has no steps section, 6 the write failed. A missed
    # step is bad; erasing the user's prompt to complain about it is worse.
    diag "append failed with exit $rc; recorded nothing for this interaction"
  fi
  return 0
}

main || true

# Rule 2. The only exit in the normal path, and unconditional.
exit 0

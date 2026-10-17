#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hooks/on_preflight_check.sh - the enforcing pre-flight hook (epic E67, task E67_S04_T02)
#
# Makes pre-flight checklist enforcement independent of an agent choosing to call the checker. A gating
# skill is supposed to run scripts/checklist.sh itself and honour the result; this hook is the backstop for
# when it does not. It fires on PreToolUse, reads the situation marker (scripts/checklist-marker.sh) to
# learn which lifecycle phase is active, runs "checklist.sh check <phase>", and REFUSES the tool call when a
# block-enforcement item is unsatisfied.
#
# With no marker present it is a silent no-op: no output, no decision, exit 0, and - see "THE COST OF THE
# NO-MARKER PATH" - no subprocess at all. An ordinary session with no gating skill active behaves exactly as
# it did before this hook existed.
#
# The companion pieces: scripts/checklist.sh owns the registry, the checks and the tick store;
# scripts/checklist-marker.sh owns "which phase is active now"; this hook owns only "should this particular
# tool call be refused". The documentation contract for all three is preflight-checklists.md in the project
# documentation directory (section 9, "The enforcing hook").
#
# ---------------------------------------------------------------------------
# HOW IT IS INVOKED
# ---------------------------------------------------------------------------
# Registered in settings.json under hooks.PreToolUse with the matcher "Bash|Task|Agent". It reads the
# harness's hook payload as one JSON object on stdin and needs only two fields from it:
#   .tool_name          Bash, Task or Agent
#   .tool_input.command the shell command, for a Bash call
# It takes no arguments. Everything else about the decision comes from the marker and the registry.
#
# WHY THE MATCHER IS NARROW. Only Bash and subagent dispatch can actually TAKE a gated action (every
# git commit, git push, npm publish, gh release and mirror.sh run is a Bash call; a developer dispatch is a
# Task/Agent call). Narrowing the matcher means Read, Edit, Grep, Glob and every other tool never spawn this
# hook at all, which matters more for "no measurable session impact" than any micro-optimisation inside it:
# the hook is not merely cheap per call, it is not called on most calls.
# The cost of the narrowing, stated plainly: a board write made through Edit/Write during pre-reconcile is
# NOT gated here. This hook gates irreversible COMMANDS; the skill-level gate remains the layer that covers
# everything else.
#
# ---------------------------------------------------------------------------
# WHAT IT GATES, AND WHY NOT EVERY TOOL CALL
# ---------------------------------------------------------------------------
# Refusing every tool call while a phase is active would be a hard wedge, not enforcement. With a block item
# failing, the agent could not run the item's verify command, could not tick it, and could not even clear the
# marker - every one of those is itself a tool call. The only ways out would be the marker's 60-minute TTL or
# killing the session.
#
# So the hook gates each phase's OWN irreversible operation and nothing else, which leaves every remediation
# path open:
#
#   pre-commit      git ... commit
#   pre-task        subagent dispatch (Task/Agent), git worktree add
#   pre-reconcile   git merge, git worktree remove
#   pre-release     npm publish, gh release, git push, git tag
#   pre-publish     npm publish, gh release, git push, git tag
#   pre-mirror      git push, mirror.sh
#   anything else   the UNION of every row above, plus git reset --hard
#
# The last row is the default for an extension phase this table does not name (pre-deploy, ...), so such a
# phase still gets the standard irreversible-action set gated rather than silently getting no hook at all.
#
# Matching is by deliberately LOOSE case globs (*git*commit*, not an exact command parse) because the error
# is not symmetric: over-matching costs one wasted check, under-matching is missed enforcement. "git -C /p
# commit", "cd x && git commit" and a commit buried in an && chain all have to match, and a loose glob gets
# all three. The accepted cost is that echo "git commit" matches too and triggers a harmless check.
#
# ---------------------------------------------------------------------------
# THE COST OF THE NO-MARKER PATH (the hook's own answer to the question E67_S04_T01 handed it)
# ---------------------------------------------------------------------------
# E67_S04_T01 measured "checklist-marker.sh read" with no marker at 40.4 ms/call (20.4 ms with its test seam
# set, against a 10.8 ms bare-bash floor), almost all of the difference being one "resolve-root.sh get queue"
# subprocess, and left the "is ~40 ms material on the hot path" decision here (see the problem rapport
# E67_S04_T01-marker-noop-cost-claim-and-nested-refresh.md, finding 1). On a hook that fires per tool call it
# is material, so this hook does NOT call the marker script to find out whether a marker exists.
#
# Stage 1 is pure bash with ZERO subprocesses - no fork, no exec, no $(...) command substitution:
#   1. stdin is drained with the read BUILTIN (not cat).
#   2. The candidate marker directories are located without resolve-root.sh: JENGA_CHECKLIST_MARKER_DIR if
#      set, else an upward walk for project/configs/workflow.json then .project/configs/workflow.json (the
#      resolver's own step 2, which is already pure bash in the resolver), honouring JENGA_PROJECT_ROOT
#      first exactly as the resolver does. The walk starts from $PWD, and (E67_S08_T01) also from the
#      directory named by a cd / git -C in the command and from CLAUDE_PROJECT_DIR - see "WHERE THE MARKER IS
#      LOOKED FOR". Extracting that command from the raw payload is pure bash too (parameter expansion, no jq).
#   3. paths.queue is read out of that workflow.json with the read builtin and bash string slicing. No jq.
#   4. If no candidate directory exists and holds a marker-*.json (a glob, not a digest lookup - same
#      reasoning as read's own fast reject), the hook exits 0 silently. The directory is created by the
#      first marker write, so "no directory" is exactly the ordinary session's case.
#
# This is lever (a) of the two T01 offered ("probing a conventional relative path first"). T01 also recorded
# that SOURCING the resolver is not the answer (22.9 vs 24.5 ms: its two internal jq calls dominate, not the
# bash spawn), so that avenue is closed and is not re-explored.
#
# CORRECTNESS IS NEVER TRADED FOR THE FAST PATH, only speed. The pure-bash probe is an ACCELERATOR whose
# failure mode is falling back to the real resolver, never skipping the gate: if paths.queue cannot be read
# in pure bash (a reformatted or minified workflow.json), the hook sets a flag and goes straight to
# "checklist-marker.sh read", which resolves the directory properly. The fast path can make the hook slower.
# It cannot make it blind.
#
# E67_S08_T01 kept that property while adding candidates: every added step is a builtin or a parameter
# expansion (checked by tracing a run with PS4='+$BASHPID ' - one pid throughout). Measured cost is in the
# documentation section named above; the delta over the E67_S04_T02 hook is about half a millisecond.
#
# Only once some marker file exists does the hook spend anything: one jq to pull tool_name and the command
# out of the payload, the union pre-filter above, then one "checklist-marker.sh read" (the authoritative,
# resolver-based, per-session-keyed, TTL-aware lookup) and one jq over its JSON. Measured figures are in the
# documentation section named above.
#
# ---------------------------------------------------------------------------
# WHERE THE MARKER IS LOOKED FOR (E67_S08_T01), AND WHAT THAT DOES NOT CLOSE
# ---------------------------------------------------------------------------
# E67_S04's live check found two ways the single "walk up from $PWD" lookup failed open: a cd inside the
# gated command ("cd <tree> && git commit" from a cwd outside any Jenga tree) is not seen, because the hook
# runs before the command and so sees the cwd as it was before the cd; and a $PWD that no longer exists
# finds no registry and reads as "no marker". The lookup is now the UNION of up to three kinds of tree, in
# this order, de-duplicated by the registry anchor they resolve to:
#
#   1. the cwd: the upward walk from $PWD, exactly as before (unpinned; later calls resolve from $PWD);
#   2. the targets of "cd <dir>" and "git ... -C <dir>" found in the gated command, resolved lexically
#      against the cwd and against each earlier cd in the same command, each pinned to its own tree;
#   3. CLAUDE_PROJECT_DIR (the harness's project dir, which does not depend on the cwd existing), pinned.
#
# A tree is a candidate only if its marker directory holds a marker file. The authoritative per-session read
# then tries the candidates in that order and the first that returns a frame for THIS session wins. A tree
# that was pinned (2, 3) has BOTH later calls - "checklist-marker.sh read" and "checklist.sh check" - run
# with JENGA_PROJECT_ROOT set to that tree. That pinning is the load-bearing detail: both scripts otherwise
# resolve from $PWD, which is precisely what is wrong in these cases, so finding the marker dir in pure bash
# and then asking a $PWD-anchored read about it would find nothing. (The documentation once recorded that
# adding CLAUDE_PROJECT_DIR "would not help" for this reason; that held only while the read was unpinned.)
# JENGA_PROJECT_ROOT and JENGA_CHECKLIST_MARKER_DIR each name one tree outright, so with either set no other
# tree is probed - the resolver itself is already pinned there.
#
# The cd / git -C targets are only parsed when the raw payload mentions cd or -C AND the command matches the
# loose union of gated operations below, so an ordinary command pays one glob and nothing else.
#
# REJECTED ALTERNATIVES.
#   CLAUDE_PROJECT_DIR first, or only: sidesteps the cwd, but the marker is written where the gating skill's
#     resolver finds a registry, and for a developer working in a .claude/worktrees/<task> worktree that is
#     the WORKTREE's own tree, not the session's project dir. A CLAUDE_PROJECT_DIR-only lookup would miss
#     every marker written there - the commonest place enforcement matters.
#   cwd, then fall back only when the cwd yields nothing: a cwd tree that holds only ANOTHER session's marker
#     (concurrent sessions in one tree) is a "maybe", so the fallback never ran and the real marker was
#     shadowed. Probing the union and letting the per-session read decide has no such hole.
#   A real shell parse (a subprocess, or a bash -n round trip): it would end the subprocess-free fast path,
#     and it still could not be evasion-proof (see the limits below).
#
# ACCEPTED LIMITS. This is a best-effort hardening of two COMMON shapes. It is NOT evasion-proof and must
# not be described as such. These all still fail open, deliberately, and are pinned by tests that assert
# they are allowed so that tightening any of them is a conscious change:
#   - bash -c '...' / sh -c '...' / eval: the cd is inside one quoted word, which is not parsed;
#   - a subshell or command substitution whose target is computed inside it;
#   - pushd (and popd, and cd - ): not recognised as a directory change;
#   - a path built from a variable, $(...), a glob or a brace expansion, or written with a backslash escape
#     or an unquoted space: rejected as unresolvable rather than guessed at;
#   - a script or alias that changes directory itself (make, ./deploy.sh, a shell function);
#   - git --git-dir / --work-tree, or a git alias that commits;
#   - a command whose cd or -C appears beyond the first 4000 characters of the command;
#   - a MISSING CWD whose own path has no registry above it AND with no usable CLAUDE_PROJECT_DIR: no tree
#     is left to probe, so the hook is a silent allow (and, with the cwd gone, the harness's own shell prints
#     a getcwd warning before this script even starts - that is not this hook).
# Parenthesised "( cd <literal dir> && git commit )" happens to be seen by the tokeniser, which treats "("
# as a command start; that is incidental, not a guarantee.
# And, as before, none of this applies unless a gating skill wrote a marker at all: the hook backstops a
# skill that ignored the checker, not one that never entered the phase (and the fail-open on a setup error
# in "THE DECISION" above is unchanged).
#
# ---------------------------------------------------------------------------
# SESSION KEYING AND THE RUN ID
# ---------------------------------------------------------------------------
# The hook passes NO --session. checklist-marker.sh's header is explicit that a hook should let the script
# resolve the session key from the environment (--session > JENGA_CHECKLIST_SESSION_ID >
# CLAUDE_CODE_SESSION_ID > JENGA_SESSION_ID) rather than passing the session_id from its stdin payload: the
# two are the same value today, and a payload-supplied key would silently stop matching what the gating
# skill wrote if a future harness ever made them differ.
#
# The run id IS taken from the marker frame and passed to check as --run, and this is load-bearing: a
# run-scoped item the gating skill already ticked would otherwise read as unticked and the hook would refuse
# an operation whose gate legitimately passed. That is the whole reason "write --run" exists.
#
# ---------------------------------------------------------------------------
# THE DECISION
# ---------------------------------------------------------------------------
#   check exit 0    allow, silently. "remind" items are the skill's business; the hook never narrates.
#   check exit 10   REFUSE (a block item is unsatisfied).
#   check exit 11   ask - only confirm items need a decision, and "ask" is exactly what confirm means. A
#                   harness that does not support "ask" degrades to allow, which is the safe direction.
#   check exit 3    allow, silently: an extension phase with no items (rule 6 of "Calling the checker from a
#                   skill").
#   any other       allow, with a loud warning on stderr. DELIBERATE FAIL-OPEN: exits 1/2/4/5 are setup
#                   errors (invalid registry, usage, no python3, internal). Refusing on those would wedge a
#                   user whose python3 is missing out of EVERY git commit with no way past the hook. The
#                   skill-level gate is the layer that refuses to proceed on a setup error; this hook is a
#                   backstop against a failed policy ITEM, not against a broken toolchain. The accepted cost
#                   is that a corrupted registry disables the hook - loudly, never silently.
#
# A refusal is emitted BOTH ways: exit status 2 (the documented PreToolUse blocking status, whose stderr is
# fed back to the model) AND a permissionDecision "deny" JSON object on stdout. Under Claude Code, stdout JSON
# is processed only on exit 0 and ignored on exit 2, so exit 2 plus stderr is what blocks the call; the JSON
# is for a host that reads it, and the refusal never depends on it being understood. "ask" is the opposite
# case: it exits 0 and the JSON is the whole mechanism.
#
# ---------------------------------------------------------------------------
# WHY THIS HOLDS AT PERMISSION LEVEL 5 (UNRESTRICTED)
# ---------------------------------------------------------------------------
# The decision is computed from the marker and the registry and NOTHING ELSE. This script never reads
# .jenga-permission-level.json, settings.json, or any permission state, so there is no code path by which a
# level could relax it, and PreToolUse is evaluated ahead of permission resolution, so a deny is not
# something an autoMode.allow entry can pre-empt. There is deliberately NO environment variable that
# disables this hook: the only way off is unregistering it in settings.json.
#
# THE REAL RISK TO THAT PROPERTY IS NOT THIS SCRIPT, IT IS THE LEVEL SWITCH, and it is why this hook is
# registered in six files rather than one. All five templates/permission-levels/level-*.json are COMPLETE
# settings.json documents, and scripts/jenga-permission-level-switch.sh copies the matching one over
# .claude/settings.json and .agents/settings.json as a WHOLE-FILE OVERWRITE. Per
# skills/jenga-permission-level/SKILL.md: "All 5 templates carry byte-identical defaultMode, env, hooks, and
# permissions.allow; that invariant is what keeps the overwrite safe... any top-level key present in a
# destination file but absent from the templates is silently dropped by a switch." Registering this hook only
# in the root settings.json would therefore mean /jenga-permission-level 5 DELETES it. It is registered in
# the root settings.json and in all five templates, keeping that hooks-block invariant intact.
# If you add, rename or change this registration, change all six files together.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   allow. Includes every no-op (no marker, phase not gating this operation, nothing applies) and both
#       the "ask" decision and every fail-open.
#   2   REFUSE this tool call. The only non-zero exit, and the only one the harness treats as blocking.
# Nothing else is ever returned, deliberately: a hook that exits 1 on its own internal problem would turn a
# bug in this file into a visible error on every tool call.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT (test seams, in the style of scripts/checklist.sh; unset in normal use)
# ---------------------------------------------------------------------------
#   JENGA_CHECKLIST_MARKER_DIR          look for markers here (the same seam checklist-marker.sh uses, and
#                                       the one that skips the upward walk)
#   JENGA_PREFLIGHT_HOOK_SCRIPT_DIR     find checklist-marker.sh and checklist.sh here
#   JENGA_PREFLIGHT_HOOK_DEBUG          non-empty: trace each stage's decision to stderr
# Not test seams (normal interface): JENGA_PROJECT_ROOT, honoured exactly as the root resolver does, and
# CLAUDE_PROJECT_DIR, set by the harness, probed as described in "WHERE THE MARKER IS LOOKED FOR".
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions).
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

PF_SEARCH_DEPTH=25
PF_EXIT_ALLOW=0
PF_EXIT_REFUSE=2

PF_QUEUE_REL=""
PF_SCRIPT_DIR=""
# jq's @tsv separator, named so that no literal tab has to survive an edit of this file.
PF_TAB=$'\t'


pf_trace() {
  [ -n "${JENGA_PREFLIGHT_HOOK_DEBUG:-}" ] || return 0
  printf 'on_preflight_check: %s\n' "$*" >&2
}

pf_warn() {
  printf 'on_preflight_check: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Stage 1 - pure bash, zero subprocesses.
# ---------------------------------------------------------------------------

# Reads paths.queue out of the workflow.json at $1 using only builtins, into PF_QUEUE_REL (empty when it
# could not be read, which makes the caller fall back to the real resolver). The key is matched as the
# quoted string "queue" followed by a colon, so paths whose VALUE contains "queue/" (scrum_triggers,
# developer_triggers, session_handoff, ...) cannot be mistaken for it.
pf_queue_from_registry() {
  local line rest value
  PF_QUEUE_REL=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"queue"'*:*) : ;;
      *) continue ;;
    esac
    rest="${line#*\"queue\"}"
    rest="${rest#*:}"
    while :; do
      case "$rest" in
        " "*|"$PF_TAB"*) rest="${rest#?}" ;;
        *) break ;;
      esac
    done
    case "$rest" in
      '"'*)
        rest="${rest#\"}"
        value="${rest%%\"*}"
        ;;
      *) value="" ;;
    esac
    if [ -n "$value" ]; then
      PF_QUEUE_REL="$value"
      return 0
    fi
  done < "$1"
  return 0
}

# ---------------------------------------------------------------------------
# Marker-directory candidates (E67_S08_T01). See "WHERE THE MARKER IS LOOKED FOR" in the header.
#
# The hook no longer asks "is there a marker under the tree my cwd is in". It collects CANDIDATES - trees that
# might hold this session's marker - and the answer to "is there any marker at all" is "no candidate holds a
# marker file". Four parallel indexed arrays (bash 3.2 has no associative arrays) describe them:
#   PF_CAND_DIR[i]    the marker directory to glob, or "" when only the resolver can say
#   PF_CAND_ROOT[i]   the root to pin the later authoritative calls to with JENGA_PROJECT_ROOT, or "" to let
#                     them resolve from $PWD exactly as they always did (the cwd candidate)
# ---------------------------------------------------------------------------
PF_CAND_DIR=()
PF_CAND_ROOT=()
PF_CAND_COUNT=0
PF_SEEN="|"
PF_MAX_TARGETS=8

# True when "$1" holds at least one marker-*.json.
pf_dir_has_marker() {
  [ -d "$1" ] || return 1
  set -- "$1"/marker-*.json
  if [ "$#" -eq 1 ] && [ ! -e "$1" ]; then
    return 1
  fi
  return 0
}

# pf_probe_tree <start-dir> <kind>
#   kind "cwd"    the original lookup: unpinned candidate, and the one conventional-path fallback when no
#                 registry is found above the start directory.
#   kind "other"  a cd / git -C target or CLAUDE_PROJECT_DIR: pinned to the anchor it resolves to.
# Appends a candidate when that tree's marker directory holds a marker (or cannot be read without the
# resolver). Never errors; a tree that does not resolve to a registry is simply not a candidate.
pf_probe_tree() {
  local start="$1" kind="$2" d depth anchor="" tree="" qdir
  d="$start"
  depth=0
  while [ "$depth" -le "$PF_SEARCH_DEPTH" ]; do
    if [ -f "$d/project/configs/workflow.json" ]; then
      anchor="$d"; tree="project"; break
    fi
    if [ -f "$d/.project/configs/workflow.json" ]; then
      anchor="$d"; tree=".project"; break
    fi
    [ "$d" = "/" ] && break
    d="${d%/*}"
    [ -n "$d" ] || d="/"
    depth=$((depth + 1))
  done

  if [ -z "$anchor" ]; then
    # No registry anywhere above the start directory, so no gating skill can have written a marker through
    # the resolver. For the cwd the resolver's own default layer would still put the tree at $PWD/project, so
    # probe that one conventional spot; for any other start it is simply not a candidate.
    if [ "$kind" = "cwd" ] && pf_dir_has_marker "$start/project/queue/checklist-markers"; then
      PF_CAND_DIR[$PF_CAND_COUNT]="$start/project/queue/checklist-markers"
      PF_CAND_ROOT[$PF_CAND_COUNT]=""
      PF_CAND_COUNT=$((PF_CAND_COUNT + 1))
    fi
    return 0
  fi

  case "$PF_SEEN" in
    *"|$anchor|"*) return 0 ;;
  esac
  PF_SEEN="$PF_SEEN$anchor|"

  pf_queue_from_registry "$anchor/$tree/configs/workflow.json"
  if [ -z "$PF_QUEUE_REL" ]; then
    # Cannot read paths.queue in pure bash: a "maybe", resolved by the real resolver later.
    PF_CAND_DIR[$PF_CAND_COUNT]=""
  else
    case "$PF_QUEUE_REL" in
      /*) qdir="$PF_QUEUE_REL/checklist-markers" ;;
      *)  qdir="$anchor/$PF_QUEUE_REL/checklist-markers" ;;
    esac
    pf_dir_has_marker "$qdir" || return 0
    PF_CAND_DIR[$PF_CAND_COUNT]="$qdir"
  fi
  if [ "$kind" = "cwd" ]; then
    PF_CAND_ROOT[$PF_CAND_COUNT]=""
  else
    PF_CAND_ROOT[$PF_CAND_COUNT]="$anchor"
  fi
  PF_CAND_COUNT=$((PF_CAND_COUNT + 1))
  return 0
}

# Lexically resolves "$2" against base "$1" into PF_RESOLVED ("" when it cannot be done safely). Handles ~, ".",
# ".." and repeated slashes; does not follow symlinks. Rejects any target containing a shell construct this
# hook cannot evaluate in pure bash, so that a variable- or $(...)-built path falls through to "no candidate"
# rather than being guessed at.
pf_resolve_target() {
  local base="$1" t="$2" p part out="" IFS=/
  PF_RESOLVED=""
  case "$t" in
    ""|-|*'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*|*'<'*|*'>'*|*'\'*|*'('*|*')'*) return 0 ;;
  esac
  case "$t" in
    "~") t="${HOME:-}" ;;
    "~/"*) [ -n "${HOME:-}" ] && t="${HOME%/}/${t#\~/}" || return 0 ;;
    "~"*) return 0 ;;
  esac
  [ -n "$t" ] || return 0
  case "$t" in
    /*) p="$t" ;;
    *)  [ -n "$base" ] || return 0; p="$base/$t" ;;
  esac
  set -f
  for part in $p; do
    case "$part" in
      ""|.) : ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  set +f
  [ -n "$out" ] || out="/"
  PF_RESOLVED="$out"
  return 0
}

# Pulls the Bash command text out of the RAW stdin payload without jq, into PF_RAWCMD (empty when there is none).
# Best effort by design: it takes everything after the "command" key up to the end of that JSON string, undoes
# the common JSON escapes, and caps the length. It only has to be good enough to find a leading cd / git -C.
pf_extract_raw_command() {
  local rest="$PF_PAYLOAD"
  PF_RAWCMD=""
  case "$rest" in
    *'"command"'*) : ;;
    *) return 0 ;;
  esac
  rest="${rest#*\"command\"}"
  rest="${rest#*\"}"
  rest="${rest%%\",\"*}"
  rest="${rest%%\"\},\"*}"
  rest="${rest:0:4000}"
  rest="${rest//\\\"/\"}"
  rest="${rest//\\n/ }"
  rest="${rest//\\t/ }"
  rest="${rest//\\\\/\\}"
  PF_RAWCMD="$rest"
}

# Walks PF_RAWCMD for "cd <dir>" and "git ... -C <dir>" and probes each resolved directory as a candidate.
# Only ever called when the command already matches the loose union of gated operations, so an ordinary command
# pays nothing. Pure bash: no fork, no exec, no command substitution.
pf_probe_command_targets() {
  local text="$PF_RAWCMD" tok prev="" cur="" gcur="" ingit=0 want="" quote="" acc="" ntargets=0
  [ -d "$PWD" ] && cur="$PWD"
  # Make operators their own words, so "cd /x&&git commit" and "cd /x;git commit" tokenise.
  text="${text//;/ ; }"
  text="${text//&/ & }"
  text="${text//|/ | }"
  text="${text//(/ ( }"
  text="${text//)/ ) }"
  set -f
  # shellcheck disable=SC2086
  set -- $text
  set +f
  while [ "$#" -gt 0 ] && [ "$ntargets" -lt "$PF_MAX_TARGETS" ]; do
    tok="$1"
    shift
    # Re-join a quoted word that was split on its spaces ("/Users/x/My Projects").
    case "$tok" in
      \"*|\'*)
        quote="${tok:0:1}"
        acc="${tok#?}"
        case "$acc" in
          *"$quote") acc="${acc%?}" ;;
          *)
            while [ "$#" -gt 0 ]; do
              acc="$acc $1"
              shift
              case "$acc" in *"$quote") acc="${acc%?}"; break ;; esac
            done
            ;;
        esac
        tok="$acc"
        ;;
    esac
    case "$tok" in
      ';'|'&'|'|'|'('|')'|'{'|'}') want=""; ingit=0; gcur=""; prev=";"; continue ;;
    esac
    if [ -n "$want" ]; then
      # tok is the target of the cd / -C that came before it.
      case "$want" in
        cd)
          case "$tok" in
            -P|-L|--|-e|-@) continue ;;
          esac
          pf_resolve_target "$cur" "$tok"
          if [ -n "$PF_RESOLVED" ] && [ -d "$PF_RESOLVED" ]; then
            pf_probe_tree "$PF_RESOLVED" other
            ntargets=$((ntargets + 1))
            cur="$PF_RESOLVED"
          else
            # Unresolvable (variable-built, missing, ...): after it the effective directory is unknown, so a
            # later RELATIVE target cannot be resolved honestly.
            cur=""
          fi
          ;;
        gitC)
          pf_resolve_target "${gcur:-$cur}" "$tok"
          if [ -n "$PF_RESOLVED" ] && [ -d "$PF_RESOLVED" ]; then
            pf_probe_tree "$PF_RESOLVED" other
            ntargets=$((ntargets + 1))
            gcur="$PF_RESOLVED"
          fi
          ;;
      esac
      want=""
      prev="$tok"
      continue
    fi
    case "$tok" in
      cd)
        case "$prev" in
          ""|';'|'&'|'|'|'('|'{'|then|do|else) want="cd" ;;
        esac
        ;;
      git) ingit=1; gcur="" ;;
      -C) [ "$ingit" -eq 1 ] && want="gitC" ;;
    esac
    prev="$tok"
  done
  return 0
}

# Collects every candidate marker directory into PF_CAND_*. Order: the cwd, then the cd / git -C targets of the
# command, then CLAUDE_PROJECT_DIR. JENGA_CHECKLIST_MARKER_DIR (a test seam) and JENGA_PROJECT_ROOT (which
# pins the resolver itself) each name ONE tree outright, so with either set nothing else is probed.
pf_collect_candidates() {
  PF_CAND_DIR=()
  PF_CAND_ROOT=()
  PF_CAND_COUNT=0
  PF_SEEN="|"

  if [ -n "${JENGA_CHECKLIST_MARKER_DIR:-}" ]; then
    PF_CAND_DIR[0]="$JENGA_CHECKLIST_MARKER_DIR"
    PF_CAND_ROOT[0]=""
    PF_CAND_COUNT=1
    return 0
  fi

  if [ -n "${JENGA_PROJECT_ROOT:-}" ]; then
    local d="${JENGA_PROJECT_ROOT%/}"
    if [ -f "$d/project/configs/workflow.json" ] || [ -f "$d/.project/configs/workflow.json" ]; then
      pf_probe_tree "$d" cwd
    else
      # JENGA_PROJECT_ROOT names a root with no registry. The resolver treats that as a hard error; let it
      # be the one to say so rather than guessing a directory here.
      PF_CAND_DIR[0]=""
      PF_CAND_ROOT[0]=""
      PF_CAND_COUNT=1
    fi
    return 0
  fi

  pf_probe_tree "$PWD" cwd

  # The command's own cd / git -C. The raw payload is only parsed when it can matter: a Bash command that
  # matches the loose union of gated operations and mentions cd or -C at all.
  case "$PF_PAYLOAD" in
    *'"command"'*cd*|*'"command"'*-C*)
      pf_extract_raw_command
      if [ -n "$PF_RAWCMD" ] && pf_is_gated_operation any Bash "$PF_RAWCMD"; then
        pf_probe_command_targets
      fi
      ;;
  esac

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    pf_probe_tree "${CLAUDE_PROJECT_DIR%/}" other
  fi
  return 0
}

# True when no marker file exists in any candidate tree - the ordinary session's case, and the one that must
# cost nothing. Only ever a fast REJECT: a true answer means "certainly no marker", a false answer means
# "maybe", and the authoritative per-session, TTL-aware lookup happens later in checklist-marker.sh read.
pf_no_marker_at_all() {
  pf_collect_candidates
  if [ "$PF_CAND_COUNT" -eq 0 ]; then
    return 0
  fi
  return 1
}

# pf_run_pinned <root> <command...>: run a command with JENGA_PROJECT_ROOT pinned to <root>, or unchanged when
# <root> is empty.
pf_run_pinned() {
  local root="$1"
  shift
  if [ -n "$root" ]; then
    JENGA_PROJECT_ROOT="$root" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# The gated-operation table (see "WHAT IT GATES" above).
# Phase "any" is the union pre-filter, and is also what an unnamed extension phase falls through to.
# ---------------------------------------------------------------------------
pf_is_gated_operation() {
  local phase="$1" tool="$2" cmd="$3"

  case "$tool" in
    Task|Agent)
      case "$phase" in
        any|pre-task) return 0 ;;
        pre-commit|pre-reconcile|pre-release|pre-publish|pre-mirror) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    Bash) : ;;
    *) return 1 ;;
  esac

  case "$phase" in
    pre-commit)
      case "$cmd" in *git*commit*) return 0 ;; esac
      ;;
    pre-task)
      case "$cmd" in *git*worktree*add*) return 0 ;; esac
      ;;
    pre-reconcile)
      case "$cmd" in *git*merge*|*git*worktree*remove*) return 0 ;; esac
      ;;
    pre-release|pre-publish)
      case "$cmd" in *npm*publish*|*gh*release*|*git*push*|*git*tag*) return 0 ;; esac
      ;;
    pre-mirror)
      case "$cmd" in *git*push*|*mirror.sh*) return 0 ;; esac
      ;;
    *)
      # One line on purpose: a backslash continuation inside a case pattern list would make the next
      # pattern begin with the continuation line's indentation, and such a pattern can never match.
      case "$cmd" in *git*commit*|*git*push*|*git*tag*|*git*merge*|*git*worktree*add*|*git*worktree*remove*|*npm*publish*|*gh*release*|*mirror.sh*|*git*reset*--hard*) return 0 ;; esac
      ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Locating the sibling scripts. One rule covers all three layouts, because this file always sits one level
# below the directory that holds scripts/: the repository's hooks/, the mirrored .claude/hooks/ and
# .agents/hooks/, and a consumer's node_modules/@jenga-ai/agent/hooks/.
# ---------------------------------------------------------------------------
pf_locate_scripts() {
  local self_dir candidate
  PF_SCRIPT_DIR=""
  if [ -n "${JENGA_PREFLIGHT_HOOK_SCRIPT_DIR:-}" ]; then
    PF_SCRIPT_DIR="$JENGA_PREFLIGHT_HOOK_SCRIPT_DIR"
    return 0
  fi
  self_dir="${BASH_SOURCE[0]%/*}"
  [ "$self_dir" = "${BASH_SOURCE[0]}" ] && self_dir="."
  for candidate in \
    "$self_dir/../scripts" \
    "scripts" \
    "node_modules/@jenga-ai/agent/scripts"
  do
    if [ -f "$candidate/checklist-marker.sh" ] && [ -f "$candidate/checklist.sh" ]; then
      PF_SCRIPT_DIR="$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Emitting the decision.
# ---------------------------------------------------------------------------
pf_emit() {
  local decision="$1" reason="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg d "$decision" \
      --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  fi
  if [ "$decision" = "deny" ]; then
    printf '%s\n' "$reason" >&2
    exit "$PF_EXIT_REFUSE"
  fi
  exit "$PF_EXIT_ALLOW"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# 1. Drain stdin with the read builtin, never cat. read -d '' reads to EOF and returns non-zero there while
#    still assigning, so the || : is expected rather than an error path.
PF_PAYLOAD=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' PF_PAYLOAD || :
fi

# 2. The fast reject: no marker anywhere means this hook has nothing to do.
if pf_no_marker_at_all; then
  pf_trace "no marker file for this project; silent no-op"
  exit "$PF_EXIT_ALLOW"
fi

# 3. Some marker exists, so it is worth parsing the payload. jq is required from here on; it is already a
#    hard requirement of this chain (checklist-marker.sh needs it to read the TTL from the config).
if ! command -v jq >/dev/null 2>&1; then
  pf_warn "jq is not installed; pre-flight checklist enforcement is NOT active for this tool call"
  exit "$PF_EXIT_ALLOW"
fi

PF_FIELDS="$(jq -r '[(.tool_name // ""), (.tool_input.command // "")] | @tsv' <<<"$PF_PAYLOAD" 2>/dev/null || :)"
PF_TOOL="${PF_FIELDS%%"$PF_TAB"*}"
PF_CMD="${PF_FIELDS#*"$PF_TAB"}"
[ "$PF_CMD" = "$PF_FIELDS" ] && PF_CMD=""
pf_trace "tool=$PF_TOOL"

# 4. Union pre-filter, before the marker read. A Bash call during an active phase that cannot be any phase's
#    gated operation stops here, so an ordinary command inside a long pre-task phase pays one jq parse rather
#    than a marker read as well.
if ! pf_is_gated_operation any "$PF_TOOL" "$PF_CMD"; then
  pf_trace "tool call is not a gated operation for any phase; allowing"
  exit "$PF_EXIT_ALLOW"
fi

# 5. The authoritative lookup: per-session keyed, TTL-aware, resolver-based. No --session is passed.
if ! pf_locate_scripts; then
  pf_warn "cannot locate checklist-marker.sh / checklist.sh; pre-flight checklist enforcement is NOT active for this tool call"
  exit "$PF_EXIT_ALLOW"
fi

# Try each candidate tree in order (cwd, cd / git -C targets, CLAUDE_PROJECT_DIR); the first one whose read
# returns a frame for THIS session wins, and the checker later runs pinned to that same tree.
PF_MARKER_JSON=""
PF_ACTIVE_ROOT=""
PF_I=0
while [ "$PF_I" -lt "$PF_CAND_COUNT" ]; do
  PF_MARKER_JSON="$(pf_run_pinned "${PF_CAND_ROOT[$PF_I]}" bash "$PF_SCRIPT_DIR/checklist-marker.sh" read 2>/dev/null || :)"
  if [ -n "$PF_MARKER_JSON" ]; then
    PF_ACTIVE_ROOT="${PF_CAND_ROOT[$PF_I]}"
    pf_trace "marker found via candidate $PF_I (root: ${PF_ACTIVE_ROOT:-<cwd>})"
    break
  fi
  PF_I=$((PF_I + 1))
done
if [ -z "$PF_MARKER_JSON" ]; then
  pf_trace "no phase is active for this session; allowing"
  exit "$PF_EXIT_ALLOW"
fi

PF_FRAME="$(jq -r '[(.situation // ""), (.run_id // "")] | @tsv' <<<"$PF_MARKER_JSON" 2>/dev/null || :)"
PF_SITUATION="${PF_FRAME%%"$PF_TAB"*}"
PF_RUN_ID="${PF_FRAME#*"$PF_TAB"}"
[ "$PF_RUN_ID" = "$PF_FRAME" ] && PF_RUN_ID=""
if [ -z "$PF_SITUATION" ]; then
  pf_trace "marker carried no situation; allowing"
  exit "$PF_EXIT_ALLOW"
fi
pf_trace "active phase=$PF_SITUATION run=${PF_RUN_ID:-<none>}"

# 6. Is this tool call the gated operation OF THAT PHASE?
if ! pf_is_gated_operation "$PF_SITUATION" "$PF_TOOL" "$PF_CMD"; then
  pf_trace "tool call is not $PF_SITUATION's gated operation; allowing"
  exit "$PF_EXIT_ALLOW"
fi

# 7. Run the checker. The run id from the marker frame is load-bearing: without it a run-scoped item the
#    gating skill already ticked would read as unticked and this hook would refuse a gate that passed.
PF_ERR_FILE="${TMPDIR:-/tmp}/jenga-preflight-hook.$$.err"
if [ -n "$PF_RUN_ID" ]; then
  PF_CHECK_OUT="$(pf_run_pinned "$PF_ACTIVE_ROOT" bash "$PF_SCRIPT_DIR/checklist.sh" check "$PF_SITUATION" --run "$PF_RUN_ID" 2>"$PF_ERR_FILE")"
else
  PF_CHECK_OUT="$(pf_run_pinned "$PF_ACTIVE_ROOT" bash "$PF_SCRIPT_DIR/checklist.sh" check "$PF_SITUATION" 2>"$PF_ERR_FILE")"
fi
PF_STATUS=$?
PF_CHECK_ERR=""
[ -f "$PF_ERR_FILE" ] && PF_CHECK_ERR="$(<"$PF_ERR_FILE")"
rm -f "$PF_ERR_FILE" 2>/dev/null || :
pf_trace "check $PF_SITUATION exited $PF_STATUS"

case "$PF_STATUS" in
  0)
    # Nothing blocks. remind items are the gating skill's business, not the hook's.
    exit "$PF_EXIT_ALLOW"
    ;;
  10)
    PF_REASON="$(jq -r --arg phase "$PF_SITUATION" '
      [ .[] | select(.action == "halt")
             | "  - [" + (.id // "?") + "] " + (.text // "")
               + (if ((.reason // "") | length) > 0 then "\n      " + .reason else "" end) ]
      | if length == 0 then "" else join("\n") end' <<<"$PF_CHECK_OUT" 2>/dev/null || :)"
    if [ -z "$PF_REASON" ]; then
      PF_REASON="  - (the checker reported a block-enforcement failure but named no item)"
    fi
    pf_emit deny "Blocked by the $PF_SITUATION pre-flight checklist: a block-enforcement item is unsatisfied.

$PF_REASON

Satisfy the item(s) above and re-run the operation, or stop. A failed machine item has no override: fix the
cause. An unconfirmed judgment item must be put to the user and ticked only after they confirm it. See
section 9 of the pre-flight checklist documentation (project/documentation/preflight-checklists.md)."
    ;;
  11)
    PF_REASON="$(jq -r '
      [ .[] | select(.action == "prompt")
             | "  - [" + (.id // "?") + "] " + (.text // "")
               + (if ((.reason // "") | length) > 0 then "\n      " + .reason else "" end) ]
      | if length == 0 then "" else join("\n") end' <<<"$PF_CHECK_OUT" 2>/dev/null || :)"
    pf_emit ask "The $PF_SITUATION pre-flight checklist has confirm-enforcement item(s) awaiting a decision:

$PF_REASON

Proceed only on an explicit choice by the user."
    ;;
  3)
    # An extension phase no registry item names. Silent, per rule 6 of "Calling the checker from a skill".
    exit "$PF_EXIT_ALLOW"
    ;;
  *)
    # Deliberate fail-open on a setup error - loudly. See "THE DECISION" above for why refusing here would
    # be worse than allowing.
    pf_warn "checklist.sh check $PF_SITUATION exited $PF_STATUS; pre-flight checklist enforcement is NOT active for this tool call"
    [ -n "$PF_CHECK_ERR" ] && printf '%s\n' "$PF_CHECK_ERR" >&2
    exit "$PF_EXIT_ALLOW"
    ;;
esac

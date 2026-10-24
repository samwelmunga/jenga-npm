# Perceived branch: how the session id reaches a script

Internal document. Task `E78_S01_T01`, story `E78_S01`, epic `E78` (session-perceived branch, `j.checkout`).
Verified 2026-10-19 on Claude Code 2.1.236, macOS (Darwin 23.6), `/bin/bash` 3.2. Session ids are redacted to
their first 8 characters.

`E78` keys its per-session state file by session id (epic decision 3). `E78_S01_T02` (`scripts/perceived-branch.sh`)
writes and reads that file and `E78_S01_T03` (`hooks/on_session_end.sh`) removes it, so both must resolve the
same key. This document fixes that contract. It changes no script or hook.

## Finding in one paragraph

Every caller can learn the harness session id: the Bash tool, the `SessionEnd` hook and the `WorktreeCreate`
hook all get it in `CLAUDE_CODE_SESSION_ID`, and both hooks also get it as `session_id` in their stdin payload,
with the same value. **`JENGA_SESSION_ID` does not equal the harness session id at `SessionEnd`: answer no.**
The `SessionEnd` command in `settings.json` sources `lib/resolve-project-dir.sh`, which finds neither
`JENGA_SESSION_ID` nor `CLAUDE_SESSION_ID` set and exports a freshly generated uuid, so the hook sees a random
value that differs on every run. `hooks/on_session_end.sh` line 48 reads only that variable. A state file written
under `CLAUDE_CODE_SESSION_ID` would therefore never be found for removal if `E78_S01_T03` reused that variable.
The design assumption that the `SessionEnd` hook can learn the key is **true** (via `CLAUDE_CODE_SESSION_ID` or
its stdin payload), so no rapport is needed and `E78_S01_T02`/`T03` can proceed as scoped, with the corrections in
"What E78_S01_T03 must do".

## Evidence by caller

### 1. Bash tool

Command (a bash script, because the interactive shell here is zsh), run in the developer subagent's Bash tool:

```text
for v in CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID JENGA_SESSION_ID JENGA_CHECKLIST_SESSION_ID \
         JENGA_AGENT_TYPE CLAUDE_AGENT_TYPE CLAUDE_PROJECT_DIR JENGA_PROJECT_DIR; do ...print set/unset...; done
CLAUDE_CODE_SESSION_ID=set e4504a93
CLAUDE_SESSION_ID=unset
JENGA_SESSION_ID=unset
JENGA_CHECKLIST_SESSION_ID=unset
JENGA_AGENT_TYPE=unset   CLAUDE_AGENT_TYPE=unset   CLAUDE_PROJECT_DIR=unset   JENGA_PROJECT_DIR=unset

$ bash scripts/checklist-marker.sh session-key
e4504a93-e943-4531-9588-8e35bc37100a        (exit 0, agrees with CLAUDE_CODE_SESSION_ID)
```

- Only `CLAUDE_CODE_SESSION_ID` is available. `JENGA_SESSION_ID` is unset until something sources
  `lib/resolve-project-dir.sh`; a script that sources it first and reads the variable afterwards gets an
  invented uuid, not the harness id.
- The subagent printed the same id (`e4504a93`) as the orchestrating session's `session-key`. Subagents share their
  parent's session id (also recorded as Q4 in `project/documentation/plans/spike-hook-payloads-skill-routing.md`).
  Consequence for `E78`: a perceived branch set by the orchestrator is automatically visible to the developer and
  tester subagents it dispatches, which is the wanted behaviour.

### 2. `SessionEnd` hook

**(a) What the harness provides.** A real Claude Code session (`claude -p ... ` in a scratch git repo with
project-level hooks, run under `env -i PATH HOME` so nothing is inherited) with a throwaway probe registered on
`SessionEnd`. The probe records only the four variables (first 8 characters) and the stdin payload's key names:

```text
CLAUDE_CODE_SESSION_ID=set f6e00bb9      CLAUDE_SESSION_ID=unset
JENGA_SESSION_ID=unset                   JENGA_CHECKLIST_SESSION_ID=unset      CLAUDE_PROJECT_DIR=set
stdin.keys=cwd,hook_event_name,prompt_id,reason,session_id,transcript_path
stdin.hook_event_name=SessionEnd   stdin.reason=other   stdin.session_id=f6e00bb9
stdin.session_id == CLAUDE_CODE_SESSION_ID: yes
```

**(b) What the existing hook does with that.** In the same run, the command shape registered in `settings.json`
(`. "$(git rev-parse --show-toplevel)/lib/resolve-project-dir.sh" && .../on_session_end.sh`) ran a COPY of
`hooks/on_session_end.sh`; the real hook was not touched. The `session_id` it logged to its (scratch)
`events.json` was `6B507E4E`, against a harness id of `f6e00bb9`.

**(c) Controlled variations.** The same copy and command shape, run with a stand-in harness id
(`CLAUDE_CODE_SESSION_ID=e4504a93-...`) and a stdin payload carrying that same id:

| Run | Environment given to the hook | `session_id` the hook logged |
|---|---|---|
| A | only `CLAUDE_CODE_SESSION_ID` | `B81BE832` (random) |
| B | same as A, again | `46A650F4` (random, differs from A) |
| C | + `CLAUDE_SESSION_ID=csid-1` | `csid-1` |
| D | + `JENGA_SESSION_ID=jsid-1` | `jsid-1` |
| E | hook invoked directly (it sources the lib itself, line 27), only `CLAUDE_CODE_SESSION_ID` | `FFE75490` (random) |
| F | no session variable at all | `F84FD944` (random) |

`JENGA_SESSION_ID` therefore equals the harness id only if something outside the hook exports it first, and
nothing in this project does. The hook never reads its stdin (its only `read` is a line loop over `find` output
at line 137), so the payload `session_id` is currently ignored.

**Answer to "does `JENGA_SESSION_ID` equal the harness session id at `SessionEnd`": no.** With the shipped
`settings.json` command it is a fresh random uuid on every run. `JENGA_SESSION_ID` is also never empty at that
point (the library always exports one), so `${JENGA_SESSION_ID:-}` cannot be used to detect "no key".

### 3. `WorktreeCreate` hook

Same harness, a throwaway probe registered on `WorktreeCreate`, session started with `--worktree e78probe`:

```text
CLAUDE_CODE_SESSION_ID=set 7ef138e7      CLAUDE_SESSION_ID=unset
JENGA_SESSION_ID=unset                   JENGA_CHECKLIST_SESSION_ID=unset      CLAUDE_PROJECT_DIR=set
stdin.keys=cwd,hook_event_name,name,session_id,transcript_path
stdin.hook_event_name=WorktreeCreate   stdin.name=e78probe   stdin.session_id=7ef138e7
stdin.session_id == CLAUDE_CODE_SESSION_ID: yes
```

`cwd` was the repository root. The existing `settings.json` command reads the payload with `jq -r '.name'`
straight from stdin, so a hook that also wants `session_id` must read stdin once (`IN=$(cat)`) and parse it twice;
it does not need the payload, since the environment variable carries the same value. The hook command also
sources `lib/resolve-project-dir.sh`, so `JENGA_SESSION_ID` is again an invented uuid there.

## Probe order for E78

`scripts/perceived-branch.sh` (and anything else in `E78` that needs the key) resolves it in this one order, the
same four steps as `scripts/checklist-marker.sh` so the two features can never disagree about "which session am I":

1. `--session <key>` (explicit)
2. `JENGA_CHECKLIST_SESSION_ID` (explicit override, and the seam bats tests use)
3. `CLAUDE_CODE_SESSION_ID` (the normal source in every caller above)
4. `JENGA_SESSION_ID` (only meaningful where the harness id is absent, for example a non-Claude host with a
   user-exported value)

Confirmed against the real script with `env -i`:

| Environment | `checklist-marker.sh session-key` |
|---|---|
| nothing set | no output, exit 7 |
| only `JENGA_SESSION_ID=jsid-9` | `jsid-9`, exit 0 |
| `CLAUDE_CODE_SESSION_ID=hhhhhhhh-1` and `JENGA_SESSION_ID=jsid-9` | `hhhhhhhh-1`, exit 0 |
| `JENGA_CHECKLIST_SESSION_ID=ovr-1` and `CLAUDE_CODE_SESSION_ID=hhhhhhhh-1` | `ovr-1`, exit 0 |

Rules that go with the order:

- A key is 1 to 128 characters of letters, digits, dot, colon, underscore or hyphen, starting with a letter or
  digit (same as the marker), so it is always safe in a filename.
- Resolve the key from the environment **before** sourcing `lib/resolve-project-dir.sh`, or take it from a
  caller that did. After sourcing, step 4 yields an invented uuid, and a state file written under it can never be
  found again.
- Step 4 is retained for non-Claude hosts; in Claude Code steps 1 to 3 always win, so the invented value is never
  reached by `perceived-branch.sh`.

### When no key can be determined

None of the four sources set means no clone-wide, default or guessed file is ever read or written:

| Subcommand | Behaviour |
|---|---|
| `set <branch>` | Refuses: a clear message on stderr (what was probed and that `--session` or `CLAUDE_CODE_SESSION_ID` is needed), exit 7 (the same code `checklist-marker.sh` uses), nothing written, no branch created |
| `get` (also `--real`) | Prints the real checked-out branch, exit 0, with a one-line notice on stderr that no session id was found |
| `get --perceived` | Prints nothing and exits 1 (no perceived branch can be set without a key) |
| `clear` | Nothing to clear: notice on stderr, exit 0 (idempotent, like `checklist-marker.sh clear`) |

## What E78_S01_T03 must do (how SessionEnd cleanup obtains the key)

- **Do not use the hook's `SESSION_ID` variable (line 48, `${JENGA_SESSION_ID:-}`).** It is a random uuid, so
  removal would always miss the file and the state file would leak.
- Take the key from the environment of the hook process: `${JENGA_CHECKLIST_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}`,
  read before or independently of the library's `JENGA_SESSION_ID` export. Observed present at `SessionEnd`.
- If both are empty, fall back to the stdin payload's `session_id` (observed present and equal), guarded so the
  hook cannot block on a terminal (`[ -t 0 ]`) and tolerant of unparsable input. If it is still empty, skip
  cleanup silently and write nothing: the hook must never remove a state file chosen by guessing.
- Call `scripts/perceived-branch.sh clear --session <key>` with the explicit key, so cleanup does not depend on
  the script's own env probe running inside the hook's polluted environment.
- Removal is by exact key, so a state file belonging to another or unknown session is never read or removed.
- The cleanup belongs after the existing steps and must not alter the existing `JENGA_SESSION_ID` logging.

## Not verified (stated so nobody relies on it)

- The probe `SessionEnd` ran under `claude -p` (`reason: other`) with no credentials, so no model turn took
  place. Other end reasons and an interactive session ending were not exercised. The hook environment and payload
  are assumed not to differ with the reason; `E78_S01_T04` should keep the key-from-env path independent of it.
- `/clear` and `--resume` are not exercised. If `/clear` starts a new `session_id` (the E73 spike did not check),
  a perceived branch set before it would be orphaned under the old key and the old key's `SessionEnd` may not
  fire. Any stale-state pruning is outside this task; it is recorded here as an open risk for `E78_S01_T02`.
- A Bash tool call inside the nested headless session was not observed (the session was unauthenticated); the
  Bash-tool evidence above comes from the developer subagent's own tool.

## Method (to reproduce)

Scratch only, never committed (it lived in an untracked `.e78-scratch/` directory inside the worktree root): a nested `git init` repo with a `.claude/settings.json` registering probe
hooks for `SessionStart`, `SessionEnd` and `WorktreeCreate` that print only the four variables above and the
payload's key names; a copy of `hooks/on_session_end.sh`, `lib/resolve-project-dir.sh` and `scripts/with-lock.sh`
inside it; then `env -i PATH="$PATH" HOME="$HOME" claude -p "say done" --model haiku [--worktree e78probe]`.
Variations A to F used `env -i PATH HOME <vars> bash -c '. lib/resolve-project-dir.sh && bash hooks/on_session_end.sh'`
with a JSON payload on stdin and `jq -r '.[-1].sender.session_id' project/logs/events.json` afterwards.

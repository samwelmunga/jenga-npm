# The `j.workflow-recorder` observation mechanism — decision

**Epic:** `E89` · **Story:** `E89_S02` · **Task:** `E89_S02_T01` · **Date:** 2026-11-01 (UTC)
**Status:** decided. `E89_S02_T02`, `E89_S02_T03` and `E89_S02_T04` are unblocked by this document and
must be implemented against it.

This settles the one open design question `E89` carried into breakdown: **how does the recorder observe
a session, given that a skill body cannot passively watch one?**

**A correction to `E89_S02_T01`'s seventh acceptance criterion, which reads "no code in this epic is
committed before it exists".** As written that was unsatisfiable before this task began, and it is not
satisfied: `E89_S01`'s shared script layer — `recording-path.sh`, `recording-file.sh` and
`active-recording.sh`, ~2,300 lines — was committed earlier the same day (`ecc83bb7`, `b3e7bed0`,
`50feb2bd`, merged as `4feb6939`) and before this document's own commit. Recorded here as a fact rather
than asserted away, after `E89_S02_T01`'s verification caught the original wording claiming compliance.

The criterion's defensible scope is **`E89_S02`'s implementation**, which is what this decision actually
gates and which genuinely had not started: no `SKILL.md`, no hook script, no settings registration
existed when this document landed. `E89_S01`'s scripts were deliberately sequenced first — both this
story's and this epic's task files state that `E89_S01_T02` and `E89_S01_T03` must land before
`E89_S02_T02`/`T03`, because those tasks call them by name and argument — so their landing early is the
plan working, not a violation of it. Nothing in `E89_S01` depended on this decision: it is the pointer
and the append mechanics, identical under either route.

---

## 1. The decision

**Hook-driven.** The recorder's appends are produced by a hook script, not by a skill that stays
resident in the turn loop.

Specifically:

| Event | Used? | What it does |
|---|---|---|
| `UserPromptSubmit` | **Yes — the only step-producing event** | Appends one verbatim interaction entry per user prompt, through `recording-file.sh append`, to the path named by `active-recording.sh get`. |
| `SessionEnd` | **Yes — close-out only, via the existing hook** | Appends one "session ended" note. Does *not* seal the recording and does *not* clear the pointer. No new registration: this is a step inside the already-registered `hooks/on_session_end.sh`. |
| `PreToolUse` | **No — deliberately rejected as a step source** | Untouched. See §4. |

The route was chosen by the user on 2026-11-01, mid-flight during this task, and is recorded in the
epic's "Rulings made during breakdown and dispatch". The investigation below was carried out
independently of that preference and **found no blocker**: the hook route is viable here, so there is no
preference-versus-limit collision to put back to the user. The user's choice settled the *choice*; §2–§8
are what make it implementable.

---

## 2. Evidence: which events this harness fires, and what each receives

### 2.1 `PreToolUse` — registered and firing today

- Registered in `settings.json` under `hooks.PreToolUse` with the matcher `Bash|Task|Agent`, dispatching
  to `hooks/on_preflight_check.sh`.
- Payload is one JSON object on stdin. The hook's own header (`hooks/on_preflight_check.sh:24-26`) states
  it needs `.tool_name` and `.tool_input.command`; the code reads exactly those at line 715 via
  `jq -r '[(.tool_name // ""), (.tool_input.command // "")] | @tsv'`. The test suite feeds that shape
  (`tests/checklist-hook.bats:142`), and for subagent dispatch `.tool_input` additionally carries
  `description`, `prompt` and `subagent_type` (`tests/checklist-hook.bats:1044,1066`).
- So: `PreToolUse` fires, delivers a structured stdin payload, and can both read and *refuse* a tool call.
  Availability is not in question for this event.

### 2.2 `SessionEnd` — registered and firing today, and its payload carries `session_id`

- Registered in `settings.json` under `hooks.SessionEnd`, `async: true`, dispatching to
  `hooks/on_session_end.sh`.
- That script resolves the harness session id from "the environment first, then the stdin payload's
  `session_id`" (`hooks/on_session_end.sh:59-72`), with a literal
  `jq -r 'if (.session_id | type) == "string" then .session_id else empty end'` against the drained
  stdin. This is working production code whose entire purpose (removing this session's perceived-branch
  state file, its section 4b) depends on that field being present. It is therefore established — not
  inferred — that a `SessionEnd` payload carries `session_id`.

### 2.3 `UserPromptSubmit` — a real event, not registered here today

Two separate facts, both verified, and they point in opposite directions:

**It is not registered.** Verified mechanically rather than by eye — the registered event keys are
identical across all six settings files and `UserPromptSubmit` is in none of them:

```
$ for f in templates/permission-levels/level-*.json; do jq -c '.hooks | keys' "$f"; done
["PreToolUse","SessionEnd","WorktreeCreate","WorktreeRemove"]      (×5, one per level)
```

The repo's own prior analysis says the same in plain words: *"root `settings.json` saknar
`UserPromptSubmit`"* — root `settings.json` lacks `UserPromptSubmit` —
`project/documentation/plans/context-aware-skill-routing.md:13`.

**But the event itself is available, and the harness's contract for it is known.** Four independent
pieces of evidence:

1. **`hooks/prompt_router.sh` exists and is written as one.** Its header: *"Claude Code UserPromptSubmit
   hook — routes prompts through the Jenga Router. Reads JSON from stdin … outputs JSON to stdout."* It
   `exec`s `hooks/prompt_router_helper.js`, which parses stdin as JSON
   (`prompt_router_helper.js:28`) and reads **`input.prompt`** (`prompt_router_helper.js:35`). The prompt
   text is in the payload — which is precisely the field an interaction recorder needs, and the reason
   this route works at all.
2. **It is a shipped product code path, not a sketch.** `lib/inject-settings.js` exists to *"inject the
   Jenga UserPromptSubmit hook into settings.json"* (line 14) and writes
   `settings.hooks.UserPromptSubmit` into a consumer's `.claude/settings.json` (lines 38-55), with
   `matcher: ""` and `hooks: [{type: "command", command: <abs path to hooks/prompt_router.sh>}]`. Jenga
   already registers this event in downstream projects; the registration shape to copy is right there.
3. **The sibling payload was empirically confirmed.** `project/documentation/hook-parity.md:22` maps
   Claude's `UserPromptSubmit` to Copilot CLI's `userPromptSubmitted` and records that `E16_S03_T03`
   confirmed the latter firing against a real installed `copilot` 1.0.83 with a stdin payload of
   `{sessionId, timestamp, cwd, prompt}` — and that `hooks/prompt_router.sh` serves **both** platforms
   unmodified because both deliver a `prompt` field.
4. **A second, independent decision in this repo already picked this event.** The context-aware skill
   routing plan's "Arkitektur B" is *"en `UserPromptSubmit`-hook som injicerar läge och kandidater"*
   (`context-aware-skill-routing.md:23`) — a different feature reaching the same conclusion about the
   same event.

### 2.4 What is *not* established, stated plainly

**There is no live capture of a Claude-side `UserPromptSubmit` payload in this repo.** Point 3 above is a
*Copilot* capture; points 1, 2 and 4 are code written against the Claude contract and the published
event set, not a measurement. The repo's own prior analysis flags this category of gap explicitly and
proposed a payload-logging spike to close it (`solution-assessment-context-aware-skill-routing.md`,
"Problem 5: Overifierade hook-API-antaganden" — unverified hook-API assumptions).

I did not close that gap in this task, and the reason is structural rather than an omission:
`UserPromptSubmit` fires on a **host-session user prompt**, which a subagent cannot produce, and the only
way to force a capture would be to register a probe hook in a live settings file — which is both
`E89_S02_T04`'s territory and a mutation of the running session. §8 converts this into a concrete
first-run verification step for `E89_S02_T03` instead of leaving it as an assumption.

Also not available: **there is no `SessionStart` hook** (`context-aware-skill-routing.md:19`: *"Ingen
SessionStart-hook finns"*). Nothing in this design needs one.

---

## 3. The rejected route: resident turn loop

**Rejected.** The reasons, in order of weight:

1. **It cannot survive the thing the story requires it to survive.** `E89_S02`'s acceptance criteria
   require that "a recording survives a context summarisation mid-session and keeps appending to the same
   file". A resident loop's knowledge of the active recording lives in conversation state, which is
   exactly what a summarisation is free to discard. The hook route does not merely survive this — a hook
   is a fresh process per event that holds no state by construction, so there is nothing for a
   summarisation to damage (§5).
2. **It dies with the turn.** A recording is meant to span a working session of many turns. Any turn that
   ends — normally, by error, or by the user changing direction — ends the observation.
3. **It contradicts CLAUDE.md's Skill Implementation Principle.** "Append one entry per interaction" is a
   fixed sequence with no dynamic reasoning in it: the canonical case for a script rather than prose
   instructions an agent must remember to follow on every turn.
4. The user chose hooks (epic ruling, 2026-11-01).

**What the resident route would genuinely have been better at, and how that is recovered.** A resident
agent can write *prose* — "the user asked for X because Y, which continues the process begun at step 3".
A shell script cannot: it has no model. Rejecting the resident route therefore gives up the one thing the
epic's purpose most depends on, and the two-tier design in §4 exists specifically to get it back: the
hook guarantees the *record*, the Scrum Master supplies the *prose*. Neither tier alone satisfies the
epic.

---

## 4. Division of labour, and why `PreToolUse` is not used

### 4.1 `UserPromptSubmit` is the recorder's event, because an interaction is what is being recorded

The epic's subject is *"the user's interaction as it happens"* — a process of user-visible steps, emitted
as a replayable `project/.workflows/<id>.json` definition. The unit of that process is **one user
interaction**, which is exactly one `UserPromptSubmit`. The mapping is one-to-one and needs no inference.

### 4.2 `PreToolUse` is rejected as a step source — three reasons, all concrete

1. **It produces a transcript, not a process document.** It fires on every `Bash`, `Task` and `Agent`
   call. A single user interaction routinely produces dozens; this very task produced well over twenty
   `Bash` calls while answering one request. Appending on each would bury the process in its own
   mechanics, which is the failure mode the task brief named.
2. **The cost is prohibitive on that hot path — measured, not assumed.** The recorder's no-op check must
   ask `active-recording.sh get` whether anything is active, and that call spawns
   `resolve-root.sh get queue` (`active-recording.sh:239`). Measured on this machine with no active
   recording: **~110–130 ms warm, ~290 ms cold, against a ~10 ms bare-`bash` floor** — roughly 10× the
   11.0 ms no-marker path `hooks/on_preflight_check.sh` reports in its own "THE COST OF THE NO-MARKER
   PATH" header. That header records the precedent decision directly: it refuses to call
   `checklist-marker.sh` at all on the hot path because *"on a hook that fires per tool call it is
   material"*. Once per **user prompt**, the same 110 ms is noise against seconds of model latency. The
   event choice is what makes the cost acceptable.
3. **That slot is occupied by a fail-closed safety gate, and the two failure modes must not mix.**
   `PreToolUse` is the pre-flight checklist's enforcing hook, which deliberately *refuses* tool calls and
   holds at permission level 5. A recorder is fail-open by nature (§6). The repo has already written down
   that these must stay separate: *"routing-hooks fail-open, `on_preflight_check.sh` förblir
   fail-closed"* — routing hooks fail open, the preflight hook stays fail closed
   (`solution-assessment-context-aware-skill-routing.md:571`). The recorder joins the fail-open class and
   therefore stays out of that script and out of that event.

### 4.3 `SessionEnd` closes out, but does not seal

A session ending is **not** a confirmed end of process. The epic requires the end of a recording to be
*confirmed by the user* (interrogation point 2), and sealing is `E89_S03_T03`'s `close-recording.sh`. So
`SessionEnd` appends a factual note — this session ended with no confirmed end-of-process — and stops
there.

It also must **not clear the pointer**. A session can be resumed, and clearing would destroy a recording
the user intends to continue. The pointer's 720-minute TTL already bounds the stale case, and
`active-recording.sh`'s header argues the asymmetry in the same direction: a lost pointer is silent, a
stale one is visible and recoverable (`set` refuses with exit 6, naming the active path).

**No new `SessionEnd` registration.** `hooks/on_session_end.sh` is already registered in all six files
and already resolves the harness session id from the payload (§2.2), so the close-out is a step inside it
— a sibling of its existing section 4b, which removes this session's perceived-branch state file. This
keeps the new six-file registration surface down to one key.

---

## 5. How appends keep reaching the same file across a context summarisation

The durability requirement is satisfied by `E89_S01_T03`'s pointer,
`skills/j-workflow-recorder/scripts/active-recording.sh` (read from branch `bundle-E89_S01` while
writing this; merged to `main` as `4feb6939` shortly afterwards). Its sub-commands are
`set` / `get` / `clear` / `status` / `refresh` / `path` /
`session-key`. The recorder uses three:

- **`set <path> [--force] [--title <t>]`** — once, when the skill body starts a recording. Prints a token.
  Refuses with **exit 6** when a recording is already active, naming the active path on stderr; `--force`
  is the only way to replace a live pointer. (This refusal is what `E89_S02_T02` surfaces as the explicit
  "a recording is already running" interaction.)
- **`get`** — on every hook invocation. Prints the active path on stdout and **nothing else** on exit 0;
  prints nothing and exits **3** when no recording is active. The hook branches on the exit code and
  never parses prose.
- **`clear`** — when a recording is sealed. Idempotent, never an error.

State lives in `"$(resolve-root.sh get queue)/active-recordings/recording-<sha256(session-key)[:24]>.json"`
— under the queue directory, per `E89`'s dispatch ruling, resolved through the root resolver and never a
working-tree literal. The TTL comes from `recording_ttl_minutes` in the configs' `scope-thresholds.json`,
falling back to **720 minutes** when that key is absent (it is not shipped yet); a key that is present but
not a positive number is a hard error (exit 5), never silently ignored.

**Why a summarisation cannot break this.** The hook is a fresh process per event. It is incapable of
remembering a path, so it must read one from disk on every single invocation — the behaviour the
durability criterion asks for is not a rule the implementation has to remember to follow, it is the only
thing the implementation *can* do. A summarisation discards conversation state; it does not touch
`project/queue/active-recordings/`. That asymmetry is the whole technical case for this route.

**The boundary, stated so it is not mistaken for more than it is.** The pointer is **session-keyed**. A
context summarisation keeps the same session, hence the same key, hence the same pointer file — the
required case works. A *different* session computes a different key and will not find the pointer, so a
recording does not automatically resume across a session restart. `E89_S02` does not require that, and
nothing here should be read as providing it.

### 5.1 The highest-risk item in this design: session-key agreement

`active-recording.sh` resolves its key in this order (lines 265-277):
`--session` > `JENGA_RECORDING_SESSION_ID` > `CLAUDE_CODE_SESSION_ID` > `JENGA_SESSION_ID`; with none of
them set it exits **7**.

**`CLAUDE_CODE_SESSION_ID` is not reliably present in a hook subprocess** — and this repo already knows
it. Both existing precedents fall back to the stdin payload:

- The `WorktreeCreate` registration in `settings.json` reads `.session_id` from the payload *only* when
  `CLAUDE_CODE_SESSION_ID` and `JENGA_CHECKLIST_SESSION_ID` are both empty.
- `hooks/on_session_end.sh:65-72` does the same, with a 1-second read timeout and a `jq` type check.

So the recorder hook resolves its key the `WorktreeCreate` way: prefer the environment, else
`--session "$(payload .session_id)"`.

This creates the design's sharpest failure mode, and `E89_S02_T03` must treat it as the primary thing to
verify: **the skill body's `set` runs in the session environment, while the hook's `get` runs in a hook
subprocess. If those two resolve different keys, `get` returns exit 3 forever and the recorder silently
records nothing** — no error, no output, just an empty document. Note that
`hooks/on_preflight_check.sh`'s "SESSION KEYING AND THE RUN ID" section reaches the *opposite*
conclusion for its own case (pass no `--session`, let the script read the environment) precisely because
its writer and reader share an environment. The recorder's do not. Do not copy the preflight hook's
reasoning here; copy `WorktreeCreate`'s.

Related and **unverified**: whether subagent sessions share the host `session_id`. The repo's prior
analysis lists this among its open hook-API questions
(`solution-assessment-context-aware-skill-routing.md:207`: *"Delar subagenter `session_id`…"*). The
consequence if they do not is bounded — interactions inside a subagent turn would not be recorded — and
it is acceptable for a recorder whose subject is the *user's* interaction, which by definition happens in
the host session.

---

## 6. Safety doctrine for the hook — `UserPromptSubmit` is the one event that can damage a session

This is not optional hardening. `UserPromptSubmit` sits between the user and the model, and a recorder
that gets it wrong is worse than no recorder at all. `E89_S02_T03` must implement all four:

1. **Never write to stdout.** Under Claude Code, a `UserPromptSubmit` hook's stdout is injected into the
   model's context. A recorder that echoes anything pollutes every turn of every session. The hook's
   stdout must be empty, always.

   *This is a concrete **live** defect in the existing `prompt_router_helper.js`, which writes
   `JSON.stringify(input)` to stdout on all four of its exit paths — lines 38, 46, 56, 63.* An earlier
   draft of this document called it "latent" on the grounds that `UserPromptSubmit` is not registered in
   this repo's own six settings files (§2.3). `E89_S02_T01`'s verification caught the error, and §2.3's
   point 2 holds the contradicting fact: `lib/inject-settings.js` registers that hook in **consumer**
   projects, and `lib/commands/init.js` imports it (line 6) and calls `injectSettings(projectRoot)`
   unconditionally at line 124. So every project scaffolded by `jenga init` has
   `UserPromptSubmit → prompt_router.sh` registered, and those four writes are injecting the hook's
   whole JSON payload into the model's context on every prompt downstream. Not latent, and not this
   task's to fix — it warrants its own board item. It is another reason not to reuse that script (§7),
   and rule 1 above is what stops `E89_S02_T03` inheriting the pattern.
2. **Always exit 0.** A non-zero exit from `UserPromptSubmit` can block prompt processing and erase the
   user's prompt — recorded as a High-severity risk in this repo's own prior analysis
   (`solution-assessment-context-aware-skill-routing.md:26`). Wrap the body so that a broken state file,
   a missing `jq` or `python3`, an unresolvable root, empty or malformed stdin, a read-only filesystem
   and a timeout all end in a silent exit 0. **Fail-open, in the recorder's class, not the preflight
   hook's.**
3. **Silent no-op when no recording is active.** Same discipline `hooks/on_preflight_check.sh` applies
   with no situation marker: no output, no decision, exit 0. A user who never runs the recorder must not
   be able to tell it is installed.
4. **Keep the no-op path cheap.** §4.2 measured `active-recording.sh get` at ~110–130 ms. That is
   acceptable once per user prompt but it is still paid by every user on every prompt, recording or not.
   Recommended: a pure-bash stage-1 probe before paying for it — the technique
   `hooks/on_preflight_check.sh` uses in its own stage 1 (zero subprocesses: no fork, no exec, no
   `$(...)`; an upward walk for `project/configs/workflow.json` instead of calling the resolver). If the
   `active-recordings` directory is absent or empty, return immediately without invoking
   `active-recording.sh` at all. Advisory, not a hard requirement — but measure it, do not assume it.

---

## 7. A new script, not `hooks/prompt_router.sh`

The recorder gets its own hook script — `hooks/on_recording_step.sh`, as `E89_S02_T03`'s task file names
it — and does not extend `prompt_router.sh`. Three reasons:

1. **The router is on a path to removal.** The context-aware-routing decisions include
   *"Router-MCP avvecklas"* — the Router MCP is being retired (`context-aware-skill-routing.md`,
   decision 7). Building the recorder on top of it would attach a new feature to something scheduled for
   deletion.
2. **It is already effectively disconnected.** The same document's verified status section calls
   `prompt_router_helper.js` a stub whose PID paths do not match and whose Claude-side registration is
   absent (line 13); the helper's own closing comment says *"Router client integration TBD; passthrough
   until wired up."*
3. **Its stdout behaviour is wrong for this event** (§6.1), so reusing it would mean fixing it first.

Both scripts would register under the same `UserPromptSubmit` key, which Claude Code supports as a list —
and which `lib/inject-settings.js` already handles idempotently — so this costs nothing in
compatibility.

---

## 8. Where deterministic appends end and the Scrum Master's judgment begins

The epic's purpose says the Scrum Master *follows and documents* the interaction, while a hook appends
without any agent in the loop. Both are true, and they are reconciled by recording in **two tiers over
one file**.

**Tier 1 — capture (the hook, deterministic, no model).** On each `UserPromptSubmit`, append one step
whose text is the user's interaction, verbatim. This tier's only job is that **nothing is ever lost**: it
runs whether or not an agent is paying attention, whether or not the turn survives, whether or not the
context was summarised.

**Tier 2 — interpretation (the Scrum Master, judgment).** The agent annotates those captured steps with
what they *mean* in the process being recorded, and runs the two interrogation points. This tier is why
the output is a process document rather than a transcript, and it is what `metadata.prefered_agent:
scrum-master` exists to deliver (`E89_S02_T02`).

**The two tiers share one file and one format, because `E89_S01_T02` already designed for exactly this.**
`recording-file.sh`'s step format — the single source of truth, defined in that script's header — wraps
each step in an open marker and a **close** marker, and the header states the close marker exists *"so an
annotator has an unambiguous insertion point INSIDE a step"*, because otherwise a later answer would be
detached from the step it is about. A step's `id` is stable once written, which is what lets an annotator
come back to "the step the user just answered about". So tier 1 writes step N and tier 2 annotates
*into* step N, through `record-answer.sh` (`E89_S03_T01`). Neither tier reimplements the format and
neither writes the file directly.

**Where the filtering lives — and it is not in the hook.** The brief is right that appending
indiscriminately yields an unreadable transcript. The split:

- **In the hook, only cheap deterministic exclusions:** no active recording (exit 3 from `get`); an empty
  prompt; a prompt that is itself a recorder control command (`j.workflow-recorder start|status|stop`),
  which is scaffolding about the recording rather than a step in the process being recorded.
- **Everything semantic is tier 2, never the hook:** is this a deviation; is this a plausible final step;
  is this merely a clarifying question that should pass silently. `E89_S03_T02` owns these criteria and is
  explicitly required to write them concretely enough that a Tester can point at a step and say whether
  the recorder should have asked. A shell script cannot make those calls, and it must not pretend to.

The consequence is the correct asymmetry: **a step the hook captured but the Scrum Master never
interpreted is still in the document, flagged as uninterpreted.** A recording with a gap in its prose is
recoverable; a recording with a gap in its *record* is not. Rejecting `PreToolUse` as a step source
(§4.2) is what keeps tier 1's volume low enough for tier 2 to stay on top of it.

---

## 9. Consequences for the rest of `E89_S02`

| Task | Consequence |
|---|---|
| `E89_S02_T02` (`SKILL.md`) | Describe the two-tier flow of §8: the body sets and clears the pointer and owns tier-2 prose; it does **not** describe appending from inside the turn. Surface `set`'s exit 6 as the "already recording" interaction. |
| `E89_S02_T03` (mechanism) | Implement the **hook route**. Add `hooks/on_recording_step.sh` per §6's four safety rules and §5.1's session-key resolution. Verify session-key agreement first — it is the failure mode that would make everything else pass while recording nothing. |
| `E89_S02_T04` (registration) | **IN SCOPE** — see §10. |
| `E89_S03_T02` (interrogation) | Unchanged, and now explicitly the sole home of all semantic filtering (§8). |

---

## 10. `E89_S02_T04` is IN SCOPE

Stated explicitly, because that task's own description makes it conditional on this decision and
describes a not-applicable path (closure as `Rejected`, there being no `Not Applicable` task status):
**that path does not apply.** Hooks were chosen, a hook exists to register, and `E89_S02_T04` has real
work.

What it registers: **`UserPromptSubmit`**, as a new `hooks.UserPromptSubmit` key, byte-identical across
all six files —

- `settings.json` (repo root)
- `templates/permission-levels/level-1-locked.json`
- `templates/permission-levels/level-2-guarded.json`
- `templates/permission-levels/level-3-standard.json`
- `templates/permission-levels/level-4-elevated.json`
- `templates/permission-levels/level-5-unrestricted.json`

What it must **not** touch: the existing `PreToolUse`, `SessionEnd`, `WorktreeCreate` and `WorktreeRemove`
registrations. The `SessionEnd` close-out of §4.3 is a change *inside* `hooks/on_session_end.sh`, not a
new registration, so `SessionEnd`'s registered block stays byte-for-byte as it is.

**Why all six, confirmed rather than quoted.** `scripts/jenga-permission-level-switch.sh` whole-file
overwrites `.claude/settings.json` and `.agents/settings.json` from the level template
(`cp "$TEMPLATE" "$tmp" && mv "$tmp" "$dest"`, line 98; the templates are described at its line 12 as
*"COMPLETE settings.json documents"*). A hook present only in the root file is therefore silently dropped
by the next `j.jenga-permission-level` switch — the same bug `E15_S04_T01` fixed for the `WorktreeCreate`
commit guard. The six-file invariant is also currently *true*, which is the standard to match: the
`PreToolUse` block hashes identically in all six —

```
$ for f in settings.json templates/permission-levels/level-*.json; do jq -S '.hooks.PreToolUse' "$f" | shasum; done
2bfd78df31f7…   (identical for all six)
```

The registration shape to copy is `lib/inject-settings.js:50-55`: a single entry with `matcher: ""` and
one `{type: "command", command: …}` hook. The command string must resolve the script path the way the
existing registrations in those files do — `$(git rev-parse --show-toplevel)` or
`${CLAUDE_PROJECT_DIR:-.}` with the documented fallback chain — and must not introduce a new path
convention or a hardcoded literal.

---

## 11. What remains unverified, and how `E89_S02_T03` closes it

One open item, carried from §2.4. It does not change the decision; it is the first thing to confirm when
the hook first runs.

1. **A live Claude-side `UserPromptSubmit` payload has not been captured in this repo.** Expected, from
   the published event set and the code that reads it: `session_id`, `transcript_path`, `cwd`,
   `hook_event_name`, `prompt`. Load-bearing fields: **`prompt`** (the step text) and **`session_id`**
   (the pointer key, §5.1).
   **Verification:** on its first run, have the hook write the raw payload once to a scratch path and
   confirm both fields are present and non-empty, then remove the probe. Because the hook is fail-open
   and silent (§6), a payload that does not match simply produces no recording rather than a broken
   session — the failure is safe, but it is also *silent*, which is exactly why this check is worth
   making deliberately instead of waiting to notice an empty document.
2. **Subagent `session_id` sharing** (§5.1) — bounded, acceptable, no action required.

---

## 12. References

- `hooks/prompt_router.sh`, `hooks/prompt_router_helper.js` — the existing `UserPromptSubmit` script and
  its `input.prompt` read (line 35); its stdout defect (lines 38, 46, 56, 63).
- `hooks/on_preflight_check.sh` — `PreToolUse` precedent: payload fields (header lines 24-26, code line
  715), no-op cost discipline and the zero-subprocess stage 1, the fail-closed decision table, and the
  session-keying argument that does *not* transfer here.
- `hooks/on_session_end.sh` — `SessionEnd` precedent, and payload `session_id` resolution (lines 59-72).
- `lib/inject-settings.js` — the shipped `UserPromptSubmit` registration shape.
- `settings.json`, `templates/permission-levels/level-*.json` — the six-file invariant.
- `scripts/jenga-permission-level-switch.sh:98` — the whole-file overwrite that makes six files necessary.
- `project/documentation/hook-parity.md` — the event mapping and the `E16_S03_T03` payload confirmation.
- `project/documentation/plans/context-aware-skill-routing.md` and
  `project/documentation/plans/solution-assessment-context-aware-skill-routing.md` — prior analysis of
  this same event: the missing registration, the fail-open doctrine, the unverified-payload gap, and the
  Router MCP's retirement.
- `skills/j-workflow-recorder/scripts/active-recording.sh` (`E89_S01_T03`) and `recording-file.sh`
  (`E89_S01_T02`) — the pointer and the append contract, on `main` as of `4feb6939`.

---
name: j.workflow-recorder
description: Record a working session as it happens into a continuously-appended _RECORDING.md document, so a process performed once by hand becomes a document and, later, a replayable workflow definition. Sub-commands are start, status and stop; bare, it starts a recording or reports the one already running.
metadata:
  prefered_agent: scrum-master
keywords:
  - record session
  - start recording
  - recording status
  - stop recording
  - document this process
examples:
  - "j.workflow-recorder start setting up the release pipeline"
  - "j.workflow-recorder status"
  - "j.workflow-recorder stop"
  - "record what we are doing now so it can be replayed"
  - "am I still recording"
---

# Workflow Recorder — Follow and Document a Session As It Happens

## Purpose

A recording is a document that grows while a process is being performed, rather than one written from
memory afterwards. It is created on the first interaction of the recording, named after that
interaction, and every later interaction is appended to the same file.

You are the Scrum Master, and this skill is instructions **to you**. Your job in a recording is
**meaning**, not capture — see "The two tiers" below before doing anything else, because the single
most common way to get this skill wrong is to try to append the steps yourself.

Everything deterministic here already exists as a script. Nothing in this body re-derives a filename,
truncates a slug, resolves a collision, creates or appends to a document, or decides where state
lives: ask the script. Where a script's header documents a rule, that header is the single source of
truth and this body does not restate the rule.

## Script resolution

Shell state does not persist between Bash calls, so begin **every** call that uses them with the
assignments it needs:

```bash
RP="$([ -f skills/j-workflow-recorder/scripts/recording-path.sh ] && echo skills/j-workflow-recorder/scripts/recording-path.sh || echo node_modules/@jenga-ai/agent/skills/j-workflow-recorder/scripts/recording-path.sh)"
RF="$([ -f skills/j-workflow-recorder/scripts/recording-file.sh ] && echo skills/j-workflow-recorder/scripts/recording-file.sh || echo node_modules/@jenga-ai/agent/skills/j-workflow-recorder/scripts/recording-file.sh)"
AR="$([ -f skills/j-workflow-recorder/scripts/active-recording.sh ] && echo skills/j-workflow-recorder/scripts/active-recording.sh || echo node_modules/@jenga-ai/agent/skills/j-workflow-recorder/scripts/active-recording.sh)"
RA="$([ -f skills/j-workflow-recorder/scripts/record-answer.sh ] && echo skills/j-workflow-recorder/scripts/record-answer.sh || echo node_modules/@jenga-ai/agent/skills/j-workflow-recorder/scripts/record-answer.sh)"
IP="$([ -f skills/j-workflow-recorder/assets/interrogation-prompts.md ] && echo skills/j-workflow-recorder/assets/interrogation-prompts.md || echo node_modules/@jenga-ai/agent/skills/j-workflow-recorder/assets/interrogation-prompts.md)"
```

Below, `recording-path.sh`, `recording-file.sh`, `active-recording.sh` and `record-answer.sh` mean
`bash "$RP"`, `bash "$RF"`, `bash "$AR"` and `bash "$RA"`. Each prints its own usage on `-h`; read that
rather than guessing an argument. `$IP` is not a script — it is the one asset this body reads, the
prompt wording used by "The two interrogation points" below.

The recording's destination is **not** chosen here and is never written as a literal. `recording-path.sh`
resolves the documentation root from `workflow.json`'s `paths.documentation` through the shared root
resolver, and the `_RECORDING.md` suffix and the whole-filename length limit are its rules, not this
body's.

## The two tiers — you do not append the steps

Recording is split over one file by **two** writers, and the split is the reason a recording survives
a context summarisation:

- **Tier 1 — capture, by a hook, with no agent in the loop.** A `UserPromptSubmit` hook
  (`on_recording_step.sh`) appends one verbatim step per user interaction, to the path
  `active-recording.sh get` names. It is a fresh process per event, holds no state, and reads the
  pointer from disk every single time. It runs whether or not you are paying attention, whether or
  not the turn survived, and whether or not the context was summarised. Its one job is that **nothing
  is lost**.
- **Tier 2 — interpretation, by you.** You annotate those captured steps with what they *mean* in the
  process being recorded. This is what makes the output a process document instead of a transcript,
  and it is why this skill has `prefered_agent: scrum-master` at all.

Two consequences, both binding:

1. **Never call `recording-file.sh append` to record a user interaction, and never edit a recording
   file directly.** The hook owns step capture. Doing it yourself double-records every step and, worse,
   makes the record depend on you remembering — which is exactly what tier 1 exists to remove.
2. **A step the hook captured but you never interpreted stays in the document, uninterpreted.** That
   asymmetry is deliberate: a recording with a gap in its prose is recoverable, a recording with a gap
   in its record is not. Never remove or rewrite a captured step to tidy the narrative.

The rest of a recording's lifetime — when to interrogate the user about a step and when to stay
silent — is the rest of tier 2, and it is **not** one of the entry points below: it runs against
captured steps while a recording is active, whatever the user happened to type. It has its own section,
"The two interrogation points".

## Instructions

### 0. Bare invocation

Run `active-recording.sh status --field active`. It prints `true` or `false` and exits 0 either way.

- `true` — behave as `status` (section 2). Do **not** start a second recording.
- `false` — behave as `start` (section 1).

### 1. `start [<name>]`

**Your judgment first, then three script calls in order.**

**a. The name.** With `<name>` given, use it. With no `<name>`, derive a short descriptive name from
the user's opening interaction — what process is about to be performed, in a handful of words, as the
user would recognise it ("set up the release pipeline", not "session 4"). This is the one genuinely
non-mechanical input to the whole flow; everything the name is then *turned into* belongs to
`recording-path.sh`. If the opening interaction is too thin to name a process from, ask the user for
one sentence describing what they are about to do rather than inventing a name.

**b. The path.** `recording-path.sh <name...>` prints one absolute path and nothing else.

| Exit | Meaning | What you do |
|------|---------|-------------|
| 0 | the path to write | continue to **c** |
| 2 | usage error, or a name with no alphanumeric character in it | ask the user for a usable name |
| 3 | the documentation root could not be resolved | surface stderr verbatim and halt |
| 5 | the collision scan was exhausted for this name | surface stderr and offer a different name |

**c. The document.** `recording-file.sh create <path> <title...>` — pass the path from **b** and the
descriptive name from **a** as the title. Exit 4 means something was created at that path in the
meantime: go back to **b** for a fresh path and try once more. Exit 2, 5 or 6 is a real failure —
surface stderr verbatim and halt without setting the pointer.

**d. The pointer.** `active-recording.sh set <path> --title <name>` prints a token on stdout. Keep that
token in your reply to the user, because `clear` and `refresh` can be scoped to exactly this pointer
with `--token`.

Exit 6 is the "already recording" case — section 1.1. Exit 7 means no session key could be resolved;
surface stderr and halt, because with no key the hook has nothing to find.

**Order is load-bearing and is not an implementation detail.** `recording-path.sh` reserves nothing: it
is a pure function of the name and the directory's contents, so two calls with no creation in between
legitimately return the same path. Create the file (**c**) before setting the pointer (**d**), and
before asking for any second path.

**e. Confirm, honestly.** Tell the user the recording's path, that capture is now automatic on each
interaction, and that `j.workflow-recorder status` shows the step count. A successful `set` means the
pointer is in place — it is **not** evidence that capture is reaching the file. Do not report
recording as verified until a step count has actually grown.

#### 1.1 A recording is already running

`set` exits 6, prints the already-active path on stderr and changes nothing. This is a decision for the
user, never something to resolve by retrying with `--force`. Present it:

```
A recording is already running: <active path>
What would you like to do?
1. Keep recording to that document — I'll continue the existing recording
2. Stop that recording first, then start the new one
3. Replace the pointer and start the new recording anyway — the existing document stays on disk but stops being appended to
4. Other (describe below)
```

- **1** — do not call `set` again. Continue with the active recording (section 2's report is the useful reply).
- **2** — run `stop` (section 3) for the active recording, then restart section 1 from **a**.
- **3** — only now `active-recording.sh set <path> --force`. Name the document that stops being appended
  to, in the same breath, so the user knows what was set aside.
- **4** — follow what the user says.

Never pass `--force` without having presented this choice and received an answer.

### 2. `status`

1. `active-recording.sh status` prints the whole state as one JSON object and exits 0 whether or not a
   recording is active — which is the one thing `get` cannot express, so prefer it here. `--field <name>`
   gives a single bare value (`path`, `title`, `set_at`, `expires_at`, `token`, `active`).
2. With no active recording, say so plainly. That is a normal answer and not a failure.
3. With one active, read the step count: `recording-file.sh steps <path>` prints the step ids in file
   order, one per line, so the count is the number of lines. Report the path, the title, the step count
   and when the pointer expires.
4. **Read the step count as a health check, not decoration.** An active pointer with a step count that
   stays at zero across several interactions means capture is not reaching the file — most likely the
   hook and this session disagree about the session key, which is the recorder's known silent failure
   mode. Say that out loud rather than reporting a healthy-looking pointer.

### 3. `stop`

`stop` is a **route**, not an implementation. Sealing a recording is deterministic and belongs to
`close-recording.sh`, which marks the recording closed in its frontmatter, clears the pointer in that
order, and prints the closed path so the workflow-definition emitter can be run against it.

1. Confirm with the user that the process has actually ended. A session ending is not an ended process,
   and nothing seals a recording without a confirmation.
2. Run `close-recording.sh` (no argument — it defaults to the active recording). Surface a non-zero exit
   verbatim; in particular an already-closed recording is refused rather than closed twice.
3. Hand the printed path to the workflow-definition emission step, and tell the user both the closed
   document and what was emitted from it.
4. **If `close-recording.sh` is not present in this skill's `scripts/` directory yet**, say plainly that
   sealing is not implemented in this installation and stop. Do not hand-edit the recording's
   frontmatter and do not clear the pointer by hand: a cleared pointer with an unclosed document is the
   one state the ordering above exists to prevent.

## The two interrogation points

Tier 2's other half, and the one part of the recorder that is instructions rather than a script,
because the question it answers — *what did that step mean in the process?* — is a judgment and not a
lookup. **All** semantic filtering lives here. The hook filters only on cheap deterministic grounds
(no active recording, an empty prompt, or a prompt whose **first token** is, case-sensitively, one of
this skill's own canonical invocations) and judges nothing; a step that should not have been captured is corrected here by
annotation, never by the hook and never by editing the document.

Read the wording before asking anything — `cat "$IP"`. That file holds the literal text of all four
questions, the option-to-token mapping and the placeholder substitutions. This section holds the
judgment: **when** to ask, when to stay silent, and what an answer does.

### The default is silence

Evaluate the newest captured step once, against the criteria below. Most steps match none of them and
**pass silently** — you say nothing about the recording at all. A recorder that asks after every prompt
is unusable, and unusable is worse than incomplete here, for a reason that is a property of
`record-answer.sh` rather than a preference: an annotation is keyed by step id and is inserted at that
step whenever it is made, so a step you did not interrogate now can still be annotated later. A user
who has been asked after every step has stopped answering, and nothing recovers that.

So where the criteria are genuinely ambiguous, stay silent. Silence is recoverable; a question is not.

### Which route, and never both

| The newest step | Route |
|---|---|
| matches a `D` criterion below | the deviation ladder (`$IP`, prompt A) |
| matches no `D` criterion but matches an `F` criterion | the end-of-process question (`$IP`, prompt B) |
| matches neither | silence — see `S` below for what silence does, and does not, write |

The ladder's second question *is* the end-of-process question, so a step that looks like both a
deviation and an ending is covered by the ladder alone. That is why the two routes are exclusive.

#### At most one interrogation per step — what the property is now

"One interrogation per step" has always meant **one route per step**, not "one question". It holds
because the table above is exclusive (a `D` match, else an `F` match, else silence) and a step is
evaluated once; it does not depend on how deep the ladder goes. Making the relevance question reachable
from an included step (see "Why the ladder asks relevance for an included step" below) changes the ladder's
shape but not that property: a step still enters exactly one route, and the ladder still asks it at most
**three** questions (`A1`, `A2`, `A3`, for a detour in a continuing process). The in-process path is now
two questions (`A1`, `A3`) where it used to be one. Nothing counts interrogations; the route table is the
mechanism.

#### What stops the extra question tipping into asking about every step

`A3` is reachable only through `A1`, and `A1` only through a `D1`–`D3` match that survived the `S` rules
below. So the new question widens **nothing** about which steps are interrogated: candidacy is unchanged,
a step that matches no `D` criterion never reaches `A3`, and an `F`-route step (prompt B) never reaches it
either. The extra cost falls only on a `D` false positive — a step the recorder suspected was a deviation
and the user said belongs — and `S1`–`S6` are what keep those rare: `S1`–`S4` name the commonest
in-process shapes (a clarification, the next step, a question to you, a retry), `S5` and `S6` are
mechanical, and on an overlap with `D` the narrower `S` rule wins. That set was reviewed for this change
and is **sufficient as written**; no `S` rule was added. The guard is to apply it faithfully, not to
extend it. If a recording nonetheless starts putting `A1` → `A3` to the user repeatedly for steps they keep
calling part of the process, the fault is in the `D` reading, so read `D1` more narrowly (stay silent)
rather than asking less at `A3`.

### `D` — what makes a step a deviation candidate

Any one of these, judged from the step's own text and the recording so far:

- **D1 — new subject.** The step introduces a target the recording has not mentioned: a file, service,
  repository, deliverable or system that appears in neither the recording's title nor any step captured
  so far.
- **D2 — backwards move.** The step undoes, reverts or abandons something an already-captured step
  recorded as done — "scrap that", "revert the config change", "actually take that file back out".
- **D3 — signposted interruption.** The step signposts itself as being about something else — "hold
  on", "unrelated", "quick question about <other thing>", "btw", "before I forget" — or is plainly a
  different piece of work that arrived mid-session.

### `F` — what makes a step a plausible final step

Any one of these:

- **F1 — stated completion.** The step says the thing is done: "that's it", "it works now", "shipped",
  "merged", "tests pass", "deployed".
- **F2 — the named outcome is reached.** The recording's title names an outcome and the newest step is
  the one that produces it — title "set up the release pipeline", step publishes the first release.
- **F3 — verification with nothing pending.** The step only checks or confirms the previous substantive
  step, and no captured step is left in an explicitly unfinished state.
- **F4 — winding down.** The step is about the session rather than the work: "let's wrap up", "stop
  here", "that's enough for today". Note what this is and is not — a session ending is not a process
  ending, which is exactly why this is a *candidate* that gets asked rather than assumed.

### `S` — what passes silently

These never put a question to the user. **Silent means unasked, not necessarily unannotated** — `S5`
is the one case that records something with no prompt at all. The first two rules are the common cases;
the last two are mechanical.

- **S1 — clarification or correction of the step before it.** "No, the other one", "use port 8080
  instead", "what does that error mean?" These refine an in-process step while leaving its goal intact;
  they do not depart from the process. Worked example: the previous step was "add the publish job to
  CI" and this step is "make it run only on tags" — the same step being specified, not a deviation and
  not an ending. The discriminator against `D2` is the goal: a correction that *abandons* the previous
  step's goal rather than adjusting it is `D2`, not `S1`. **Read "goal" narrowly** — the previous step's
  own stated objective, not the broader outcome the process is working toward. "Add the publish job to
  CI" followed by "actually revert that, we'll use the release-please action instead" abandons *that
  step's* goal even though the process's outcome (publishing from CI) is untouched, so it is `D2` and
  gets asked. The narrow reading is deliberately the one that asks, because the general bias toward
  silence already applies everywhere else.
- **S2 — the next step of the process as recorded.** A new command, a new file, a new service — all
  in-process as long as the subject is the process the recording names. Worked example: a recording
  titled "set up the release pipeline" reaching "now add the changelog generation step" is the process
  continuing, however little the earlier steps mentioned changelogs.
- **S3 — a question addressed to you.** "Which of these two should I pick?" is inside the process; it is
  the process being performed with you in it.
- **S4 — a retry of a step that failed.** The command failed and the user runs it again with a fix. The
  attempt deviated; the process did not.
- **S5 — recorder scaffolding.** A prompt that invokes this skill is scaffolding *about* the recording,
  not a step *in* the process, and is never worth a question. But do not assume it never reached the
  document. The hook drops such a prompt only when its **first token** is one of the canonical
  spellings, matched case-sensitively, and its header delegates the remainder here on purpose — so
  `J.Workflow-Recorder stop` (mis-cased) or `please j.workflow-recorder stop` (not the first token)
  arrives as an ordinary captured step, matching no `D` and no `F` criterion. Leaving it alone is not
  neutral: an unannotated step and an `in-process` one are identical to a consumer, so a "stop the
  recording" line would be emitted as a workflow step. Annotate it `deviation out-of-process` — **and
  do it without asking.** This is the one annotation written with no prompt, and it is sound because
  the test is a fact about the step's text — it opens with an invocation of this skill, in any casing
  and whether or not a word like "please" precedes it — rather than a judgment about the process.
  **Order matters when the scaffolding step is a `stop` invocation.** Write the annotation *before* you
  invoke the close path, not after: sealing clears the active-recording pointer, and from then on
  `active-recording.sh get` fails and the only path left names an already-sealed document, so the
  annotation becomes unreachable through these rules and the step is emitted after all. This is the
  same ordering exception the close path already takes to "do not let the interrogation displace the
  step", for the same reason.
  Reach for the fall-back readily, because this write is the one thing in this section that is **not**
  recoverable: it consumes the step's `deviation` slot, a second annotation of that kind is refused
  (exit 7), and `S6` then says to leave it. If the text leaves you at all unsure whether it is an
  invocation, that is no longer this rule — stay silent and leave the step alone.
- **S6 — a step already carrying an annotation of that kind.** Check it rather than remembering it:
  `record-answer.sh --value <path> <step-id> <kind>` exits 0 when one exists and 1 when it does not. If
  it exists, stay silent — a second annotation of the same kind is refused (exit 7), and `--replace` is
  not yours to reach for, because overwriting an answer the user already gave is not a correction.

Where an `S` rule and a candidacy criterion both seem to fit, and the `S` rule fits **as written**
rather than approximately, `S` wins: the silence rules are the narrower and more concrete of the two
sets, so on an overlap the narrower reading is the better one.

### Resolving the recording and the step

Both are looked up, never remembered:

```bash
REC="$(bash "$AR" get)"                        # exits non-zero when no recording is active
SID="$(bash "$RF" steps "$REC" | tail -n 1)"   # step ids in file order; the last one is the newest
```

With no active recording there is nothing to interrogate. That is a normal state, not an error to
report.

### Recording the answer

Every answer goes through `record-answer.sh`, with the **token** from `$IP`'s mapping table as the
answer argument and the user's own words in `--note`:

```bash
bash "$RA" "$REC" "$SID" deviation out-of-process --note "<the user's own words>"
bash "$RA" "$REC" "$SID" end-of-process continuing
bash "$RA" "$REC" "$SID" relevance -           # the relevance text on stdin, verbatim and unreflowed
# an included step carries both, with no --replace: they are different kinds
bash "$RA" "$REC" "$SID" deviation in-process && printf '%s' "<the relevance text>" | bash "$RA" "$REC" "$SID" relevance -
```

- Exit 2 means the answer did not map to the kind's vocabulary. Do **not** retry with a different token
  to make it pass; follow `$IP`'s "when the free-text answer resolves to neither option".
- Exit 7 means the step already carries an annotation of that kind, i.e. `S6` was missed. Leave it as
  it is.
- Exit 8 means the recording's own markers are ambiguous, so nothing can be read or written from it
  safely — a recording written before the body-escape rule, carrying a recorder marker inside a step
  body. Do not re-run it, do not work around it: report the message, which names the offending lines,
  and `recording-file.sh migrate <path>` once the document has been fixed.
- Exit 9 means the answer (or `--note`) contains a line that would be read as a recorder marker and the
  recording is too old a format version to hold one. Promote it with `recording-file.sh migrate <path>`
  and retry; do not reword the user's answer to get past it.
- Never read an answer back as prose to decide anything. `--value`'s exit code is a sound presence
  check. `--text` is trustworthy as of `E89_S06_T15`: a body containing a literal recorder marker round
  trips byte for byte, and an unreadable document fails with exit 8 rather than returning a
  neighbouring block. The parse contract that guarantees that — including the rule that a consumer
  must anchor every marker match at **column 1** — is
  `skills/j-workflow-recorder/scripts/recording-format.sh`'s header.

### The ladder's flow control

The order is fixed and is not yours to reorder. Each stop is a real stop: the later questions are not
asked and no annotation of their kind is written.

1. **Is this in fact a deviation from the process?**
   → "no" (part of the process): record `deviation in-process` and **continue to 3**. The step is
   included, so the process model is unchanged, but its relevance is still asked. `A2` is skipped — the
   user has just said the step belongs, so whether the process ended is not a question it raised.
   → "yes": record `deviation out-of-process` and continue to 2.
2. **Has the process that was being followed ended here?**
   → "yes": record `end-of-process ended` and **stop** — question 3 is not asked. Go to the close path.
   → "no": record `end-of-process continuing` and continue to 3.
3. **What is this step's relevance in the process?**
   → record `relevance` with the chosen option's text, or the user's free text, as the body. Use the
   included-step options when you came from 1, the detour options when you came from 2 (`$IP`, `A3`).
   The ladder ends. A step may now carry both `deviation in-process` and `relevance`; they are different
   kinds, so `record-answer.sh` accepts the pair with no `--replace`.

A `relevance` body describes an **included** step and is what an emitter uses as that step's description.
On the detour path the step is excluded, so its body is recorded for the reader and never emitted.

### Why the ladder asks relevance for an included step

This departs from the three-question order the user first specified, where relevance was the *otherwise*
branch — reached only after a deviation was confirmed and found not to be an ending. The user ruled on
**2026-11-02** (task `E89_S06_T17`, resolving `E89_S03_T02`'s finding 5) that it is also asked when the
answer to question 1 is "part of the process". The old order contradicted itself: `out-of-process`
**excludes** a step from the emitted definition while a `relevance` body becomes **the emitted step's
description**, so the description could only ever describe a step that would not exist. Letting the
relevance answer decide inclusion instead was offered and not chosen.

Do not restore the old order because the original phrasing reads differently, and do not reintroduce a
rule that relevance follows only an `out-of-process` verdict. If the order looks wrong, that is a question
for the user, not a correction for the recorder.

### The end-of-process question's flow control

- **"Ended"** — record `end-of-process ended` and go to the close path below.
- **"Not ended"** — record `end-of-process continuing` and carry on. Do not ask about that step again,
  and do not ask about the next step unless it *newly* satisfies an `F` criterion that this one did not.
  Re-asking a user who has just said the process is still going is the fastest way to make them stop
  reading the question.

### The close path — a confirmed ending

A confirmed ending is handed to **`stop` (section 3)**, which already owns sealing and emission. Nothing
is sealed here.

- Section 3's step 1 — confirming with the user that the process has actually ended — is **already
  satisfied**: prompt A2 option 1, or prompt B option 1, *is* that confirmation. Do not ask a second
  time; go straight to section 3's step 2.
- From there section 3 is unchanged: `close-recording.sh` with no argument closes the recording named by
  the active pointer and prints that path, an already-closed recording is refused rather than closed
  twice, and the printed path is what the workflow-definition emitter is run against.
- Section 3's step 4 still applies. If `close-recording.sh` is not present in this skill's `scripts/`
  directory, say plainly that sealing is not implemented in this installation and stop. The answer you
  just recorded stays in the document and is not lost, so do not hand-edit the frontmatter or clear the
  pointer to compensate.

### Do not let the interrogation displace the step

The user asked for something; do that, and ask at the end of the same reply. An interrogation is an
addition to your response, never a substitute for it. The one exception is the close path, where the
step *is* the ending, so the question comes before anything is sealed.

## What this skill does not do

Deliberate boundaries. Each is owned elsewhere, and none of them should be improvised here:

- **Appending steps.** The `UserPromptSubmit` hook `on_recording_step.sh` does this. It is fail-open,
  silent, writes nothing to stdout and always exits 0, so a user who never runs this skill cannot tell
  it is installed.
- **Registering that hook.** It belongs in the root `settings.json` *and* all five
  `templates/permission-levels/level-*.json` files, byte-identically — a hook in only one is silently
  dropped by the next `j.jenga-permission-level` switch.
- **Defining the document format.** `scripts/recording-format.sh`'s header is the single source of
  truth for the markers, the body-escape rule, the column-1 matching rule and the format versions. Both
  writing scripts source it. Do not restate any of it here or in a script header.
- **Writing an answer into a step.** A captured step carries a close marker so an annotator has an
  unambiguous insertion point *inside* it; `record-answer.sh` uses that marker. This body decides
  *what* is recorded and never writes a byte of it itself.
- **Sealing a recording** (`close-recording.sh`, section 3) and **emitting the workflow definition**
  from a sealed one.
- **Resuming a recording in a new session.** The pointer is session-keyed: a context summarisation keeps
  the same session and therefore the same recording, which is what the recorder guarantees. A *different*
  session resolves a different key and will not find the pointer. Do not tell a user a recording will
  resume after a restart.

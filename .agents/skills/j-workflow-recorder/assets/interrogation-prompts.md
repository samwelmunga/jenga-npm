# Interrogation prompts — the exact wording

The literal text of the recorder's two interrogation points. This file is **wording only**. Whether to
ask at all, and what to do with the answer, is `SKILL.md`'s section "The two interrogation points" —
read that first; reading this file alone tells you what to say but not when, and asking at the wrong
time is the failure mode that makes a recorder unusable.

Present each block as written, with the placeholders substituted. Keep the option numbering and keep
the free-text option last, per CLAUDE.md's interaction pattern.

## Placeholders

| Placeholder | Substitute with |
|---|---|
| `<step>` | a short paraphrase of the captured step, in the user's own terms — enough that they know which step you mean without re-quoting it in full |
| `<process>` | the recording's title, from `active-recording.sh status --field title` |

## The two rules that make an answer recordable

1. **Never pass the user's prose as the machine value.** `record-answer.sh` normalises a fixed
   vocabulary per kind and treats an unmappable answer as a usage error rather than defaulting. Pass
   the **token** from the mapping table below as the answer, and carry the user's own words in
   `--note` when they chose the free-text option or said something worth keeping.
2. **`relevance` is the one exception**, because its value is always `stated` and its *body* is the
   payload a consumer reads. There, the chosen option's text — or the user's free text verbatim — **is**
   the answer argument.

---

## Prompt A — deviation (a three-question ladder)

Ask these in order. Stop as soon as an answer makes a later question moot; the ladder is **one**
interrogation, not three, and the questions after the stopping point are never asked.

**The order departs from the user's original specification, deliberately.** As first written, relevance
was the *otherwise* branch — asked only after a deviation was confirmed and found not to be an ending.
On **2026-11-02** the user ruled (resolving `E89_S03_T02`'s finding 5, task `E89_S06_T17`) that the
relevance question is also asked when `A1` is answered "part of the process". The reason is mechanical:
`out-of-process` **excludes** a step from the emitted workflow definition while a `relevance` body
becomes **the emitted step's description**, so with relevance reachable only after `out-of-process` the
description would describe a step that does not exist. Letting the relevance answer decide inclusion
instead was offered and not chosen. **Do not restore the old order because the original phrasing reads
differently** — that reopens a contradiction the user has already resolved.

The paths through the ladder:

| `A1` answer | Path | Questions asked |
|---|---|---|
| part of the process | `A1` → `A3` | 2 |
| deviation, process ended | `A1` → `A2` (stop, close path) | 2 |
| deviation, process continuing | `A1` → `A2` → `A3` | 3 |

`A2` is skipped for an included step on purpose: the user has just said the step belongs to the
process, so "has the process ended here" is not a question the step raised.

### A1 — question 1 of 3

```
That last step — <step> — doesn't look like part of the process we're recording.

Is this in fact a deviation from the process?
1. No — it is part of the process I'm recording
2. Yes — it is a deviation from it
3. Other (describe below)
```

| Option | `kind` | `value` | Next |
|---|---|---|---|
| 1 | `deviation` | `in-process` | A3 (the included-step options) |
| 2 | `deviation` | `out-of-process` | A2 |
| 3 | `deviation` | whichever of the two the prose resolves to, with the prose in `--note` | as per the resolved option |

Recording option 1 is still not an exclusion: `in-process` is the semantic identity of no deviation
annotation at all, so that answer joins the record without entering the process model. What follows it
is the relevance question, whose answer **is** read — as the emitted step's description.

### A2 — question 2 of 3

```
Has the process we were following — <process> — ended here?
1. Yes — that process has ended; this step belongs to whatever comes next
2. No — it is still going; this step is a detour inside it
3. Other (describe below)
```

| Option | `kind` | `value` | Next |
|---|---|---|---|
| 1 | `end-of-process` | `ended` | **Stop.** The ladder ends here and the close path takes over. |
| 2 | `end-of-process` | `continuing` | A3 (the detour options) |
| 3 | `end-of-process` | whichever of the two the prose resolves to, with the prose in `--note` | as per the resolved option |

### A3 — the relevance question (last question of the ladder)

Reached from **two** places, and the options differ because the step differs:

- from `A1` option 1 — the step is **part of the process** and will be emitted, so its answer becomes its
  description and must describe a step that belongs;
- from `A2` option 2 — the step is a **detour** inside a continuing process and is excluded, so its answer
  is context for the record and is not emitted.

A `relevance` body describes an **included** step. On the detour path it is recorded for the reader and no
emitter uses it, because the step it describes is not emitted.

**A3, from `A1` (an included step):**

```
What is this step's role in the process?
1. A prerequisite the process turned out to need
2. A fix or recovery for a problem the process hit
3. An ordinary part of the process that simply had not come up yet
4. Other (describe below)
```

**A3, from `A2` (a detour in a continuing process):**

```
What is this step's relevance in the process?
1. A prerequisite the process turned out to need
2. A fix or recovery for a problem the process hit
3. A one-off side errand, unrelated to this process
4. Part of a different process that interleaved with this one
5. Other (describe below)
```

The detour options "unrelated to this process" and "part of a different process" are deliberately absent
from the included-step list: offering them for a step the user has just called part of the process would
put a contradiction into its emitted description.

| Option (either list) | `kind` | `value` | Answer argument |
|---|---|---|---|
| a listed option | `relevance` | `stated` | the chosen option's text, verbatim |
| the free-text option (last) | `relevance` | `stated` | the user's free text, verbatim and unreflowed |

Any non-empty answer is accepted, so there is no unmappable case here — but an **empty** answer is a
usage error. If the user answers with nothing, ask once more rather than inventing a relevance, and if
there is still no answer leave the step without a `relevance` annotation: it is recoverable, and an
invented description is not.

`record-answer.sh` accepts `deviation: in-process` and `relevance: stated` on one step without
`--replace`: uniqueness is per step **and kind**, and these are different kinds.

---

## Prompt B — end of process

A standalone question for a step that is **not** a deviation candidate but could plausibly be the last
one. A step that is both is handled by the ladder above, whose A2 is this same question — so B and the
ladder never both run on one step.

```
That looks like it might be the last step of <process>.

Has the process reached its end?
1. Yes — it is complete; close the recording
2. No — there is more to do
3. Other (describe below)
```

| Option | `kind` | `value` | Next |
|---|---|---|---|
| 1 | `end-of-process` | `ended` | the close path |
| 2 | `end-of-process` | `continuing` | carry on recording; do not ask again about this step |
| 3 | `end-of-process` | whichever of the two the prose resolves to, with the prose in `--note` | as per the resolved option |

A "yes" here **is** the confirmation `stop` requires before anything is sealed. Having asked it, do not
ask the user to confirm the ending a second time.

---

## When the free-text answer resolves to neither option

Do not guess, and do not pick the option that keeps the flow moving. Say which part of the answer you
could not place, re-present the same block once, and if it is still unresolved leave the step
**unannotated** and carry on recording. An uninterpreted step is recoverable — the step itself is
captured verbatim and can be annotated later. A wrong annotation is not: it silently changes what gets
emitted.

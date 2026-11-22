# Review prompts — the exact wording

The literal text of `j.workflow-capture`'s review mode. This file is **wording and answer mapping only**; when the
review runs and what surrounds it is `SKILL.md`'s section "Review mode". Present each block as written, with the
placeholders substituted, keep the numbering, and keep the free-text option last (CLAUDE.md's interaction pattern).

**Asking is the default here.** The live recorder (`j.workflow-recorder`) judges one fresh step at a time and stays
silent unless a step looks off. A review is the opposite: every step is on the table at once and the user is
actively reviewing, so every candidate step gets a decision, and every uncertain one is asked about on its own.

**The flow, in order:**

1. Render the table (`render-review-table.sh <candidates-file>`) and print it exactly as it comes.
2. Ask **R1**. Corrections go through **R2**, as many rounds as the user wants, each round re-rendering nothing
   but re-showing R1 afterwards.
3. Persist the accepted proposals of the rows that are **not** uncertain (`record-review.sh accept`).
4. Walk the uncertain rows (`render-review-table.sh --uncertain`) **one at a time** with **R3**, showing each row
   in full first (`render-review-table.sh --row <n>`). A row the user already corrected in R2 still gets R3 for
   whatever R2 did not decide.
5. `record-review.sh pending` must print nothing before the recording is sealed and emitted.

## Placeholders

| Placeholder | Substitute with |
|---|---|
| `<N>` | the number of candidate steps |
| `<uncertain>` | the uncertain row numbers, comma-separated, from the table's summary line |
| `<n>` | the row number being asked about |
| `<step>` | a short paraphrase of row `<n>`'s text, in the user's own terms |
| `<proposed-type>` | the row's proposed step type, or "none proposed" |
| `<proposed-parameters>` | the row's Parameters cell, or "none proposed" |

## The rules that make an answer recordable

1. **Every decision goes through `record-review.sh`, which writes through `record-answer.sh`.** Never edit the
   recording by hand and never hold a decision only in the conversation: an answer that is not persisted is a
   judgment the emitter would have to make again.
2. **Pass tokens, not prose.** The mapping tables below give the exact command for each option. When the user chose
   the free-text option, resolve it to one of the listed options and pass their words in `--note`. When it
   resolves to none of them, say which part you could not place, ask the same block once more, and if it is still
   unresolved leave that decision unmade: `pending` keeps it visible, and a wrong annotation silently changes what
   is emitted.
3. **A correction replaces.** A decision the user changes after it was written is re-written with `--replace`.
4. **A secret is a name, never a value.** A parameter that looks like a credential is recorded as a bare `<name>`;
   its value is never typed into a prompt answer, a `--note`, the recording or the definition.

---

## Prompt R1 — after the table

```
Here are the <N> candidate steps. Rows <uncertain> are marked uncertain; I'll go through those one at a time.
What would you like to do with the rest?
1. Accept the proposals for every row not marked uncertain, then go through the uncertain ones
2. Correct some rows first
3. Mark more rows as uncertain so we go through them one at a time
4. Other (describe below)
```

When no row is uncertain, drop the second sentence of the first line and the words "then go through the uncertain
ones". When the table says "No candidate steps to review.", do not ask R1: say there is nothing to review and that
the range or the source needs another look.

| Option | Do |
|---|---|
| 1 | `record-review.sh accept <recording> <candidates-file>`, then step 4 of the flow |
| 2 | ask R2 |
| 3 | ask which rows; those rows are walked with R3 and are left out of the batch: pass only the remaining certain rows to `accept` (`accept <recording> <candidates-file> <n>...`) |
| 4 | resolve to 1-3, or rule 2 above |

## Prompt R2 — batch correction

```
Which rows should change, and how? You can list several at once, for example "3 exclude, 5 type confirm, 7 include".
1. Include or exclude rows
2. Change the step type of rows
3. Change the parameters of rows
4. Other (describe below)
```

The user may answer with the corrections directly instead of picking a number; that is the expected answer. Read
each correction, say back what you understood as one line per row, write each one, then show R1 again.

| Correction | Command |
|---|---|
| row `<n>` included | `record-review.sh decide <recording> <n> include` |
| row `<n>` excluded | `record-review.sh decide <recording> <n> exclude` |
| row `<n>` step type `<t>` | `record-review.sh decide <recording> <n> type <t>` (skill, playbook, confirm, compute, render) |
| row `<n>` has no parameters | `record-review.sh decide <recording> <n> params none` |
| row `<n>` parameters | `record-review.sh decide <recording> <n> params <name>=<literal> ... <secret-name>` |

Add `--replace` when that kind was already written for the row. A corrected decision is never overwritten by a later
`accept`.

## Prompt R3 — one uncertain row

Show `render-review-table.sh --row <n> <candidates-file>` first. Then ask only the questions this row still needs,
in this order; a later question is skipped when an earlier answer makes it moot (an excluded step needs no type and
no parameters).

### R3a — include or exclude

```
Step <n> — <step>. Is this part of the process?
1. Yes — include it in the workflow
2. No — exclude it (a detour, a mistake, or part of something else)
3. Other (describe below)
```

| Option | Command | Next |
|---|---|---|
| 1 | `record-review.sh decide <recording> <n> include` | R3b |
| 2 | `record-review.sh decide <recording> <n> exclude` | next uncertain row |
| 3 | resolve to 1 or 2 with the user's words in `--note`, or rule 2 | as resolved |

### R3b — step type

```
What kind of step is it? I'd say: <proposed-type>.
1. Run a skill (skill)
2. Run a playbook (playbook)
3. Ask the person running the workflow to confirm or do something by hand (confirm)
4. Run a script (compute)
5. Render a template (render)
6. Other (describe below)
```

| Option | Command |
|---|---|
| 1-5 | `record-review.sh decide <recording> <n> type <t>`, `<t>` being the word in brackets |
| 6 | resolve to 1-5 with the user's words in `--note`, or rule 2 |

### R3c — parameters

Ask only when the row proposes parameters or the user mentions a value that differs between projects.

```
These values look project-specific: <proposed-parameters>. Which should become workflow inputs?
1. All of them, as proposed
2. None of them
3. Some of them, or under different names
4. Other (describe below)
```

| Option | Command |
|---|---|
| 1 | `record-review.sh decide <recording> <n> params <name>=<literal> ...` with every proposed parameter (a secret by bare name) |
| 2 | `record-review.sh decide <recording> <n> params none` |
| 3, 4 | read the answer, say back the resulting list, then `params ...` with it; or rule 2 |

---

## Prompt W1 — one generated wrapper script

Asked once per step that `generate-wrapper.sh pending` lists, after the review and before sealing. Show
`generate-wrapper.sh show <recording> <n>` first and print its output **exactly as it comes, the whole file**: never
summarise, shorten or paraphrase the script. Then ask:

```
Step <n> runs as this script (<path>), with <args> passed as arguments and a timeout of <timeout>.
Write it exactly as shown?
1. Yes, write it as shown
2. No, make this step a confirm step instead (the person running the workflow does it by hand)
3. Change the timeout first
4. Other (describe below)
```

| Option | Command |
|---|---|
| 1 | `generate-wrapper.sh write --confirm <the sha256 line of the show output> [--timeout <same as shown>] <recording> <n>` |
| 2 | `generate-wrapper.sh decline <recording> <n>` |
| 3 | ask for the seconds (or none), run `show --timeout <s> <recording> <n>` again, and ask W1 again |
| 4 | resolve to 1-3 with the user's words, or rule 2; a request to edit the command itself is a correction of the step's text or parameters in the review, not of the script |

`<args>` is the show output's `args` line ("no arguments" for `-`), `<timeout>` its `timeout` line ("the default 60
seconds" for `-`). Only option 1, chosen after the full file was shown, is a confirmation: silence, an unrelated
answer or a yes given before the file was shown is not. A refused `write` (exit 9) means the content changed since it
was shown: show it again and ask again.

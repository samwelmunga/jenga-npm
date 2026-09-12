---
name: j.playbook
description: Invoke a specific /jenga playbook directly by ID, skipping natural-language matching entirely and going straight to chain confirmation and execution.
keywords:
  - run playbook
  - invoke playbook by id
  - playbook direct
  - execute playbook
examples:
  - "j.playbook brainstorm-to-mirror"
  - "run the understand-then-ship playbook"
  - "invoke playbook by id"
---

# Playbook — Direct Playbook Invocation by ID

## Purpose

`/jenga`'s natural-language branch (`skills/jenga/SKILL.md`) proposes a playbook only when
free-text intent doesn't cleanly resolve to a single skill and `skills/jenga/scripts/match-playbook.sh`
finds a confident match. That's the right default when the user doesn't know a playbook exists or
doesn't know its exact id. `j.playbook <id>` is the other case: the user already knows exactly
which playbook they want and names it directly — this skill skips `detect-nl-intent.sh` and
`match-playbook.sh` entirely and goes straight to the same confirmation-and-execution machinery
`/jenga`'s natural-language branch already uses (`E53_S06_T03`, per story `E53_S06`'s fourth and
fifth Acceptance Criteria).

This skill never re-implements chain confirmation, sequential execution, `forward_from`/`resolve`
resolution, or composition/conditional handling — all of that is `skills/jenga/SKILL.md`'s
Natural-language branch steps 5a-5e, reused here by reference. The only genuinely new logic in
this skill is id resolution (step 1 below).

## Instructions

0. **Bare invocation — no id given.** If this skill was invoked with no argument at all, do not
   proceed to step 1. Instead:
   a. Invoke `skills/jenga/scripts/load-playbooks.sh` with no arguments (its existing full-catalog
      mode — the same call step 1's `"not_found"` branch already uses for its "did you mean"
      nudge; no new script is introduced for this).
   b. Render the returned JSON array as a Markdown table with columns `Id`, `Name`, `Source`, and
      `Steps`. For the `Source` column, render `Built-in` for a `source` field of `"builtin"` and
      `Project` for `"project"`. For the `Steps` column, render each entry in that playbook's
      `steps` array joined by `->`: a bare string step renders as itself; a StepObject step
      renders its `skill` or `playbook` field value (whichever is present).
   c. Halt this invocation after rendering the table — do not proceed to step 1.

1. **Resolve the id** — invoke `skills/jenga/scripts/load-playbooks.sh lookup "<id>"`
   (`E53_S06_T02`), where `<id>` is this skill's argument. Branch on the returned `status` field:

   - **`"not_found"`** — no playbook with that id exists. Tell the user plainly that no such
     playbook was found. As a "did you mean" nudge, you may additionally invoke
     `skills/jenga/scripts/load-playbooks.sh` (no arguments, full-catalog mode) and list the
     available `id`s from its output — use your judgment on whether this is helpful given the
     specific id the user typed. Halt this invocation; do not proceed to step 2.
   - **`"invalid"`** — a file for that id exists but failed load-time validation. Report the
     `reason` field to the user **verbatim** — never a generic "not found" message, since this is
     a materially different situation from `not_found` (the story's explicit distinguishing
     requirement, `E53_S06_T02`). Halt this invocation; do not proceed to step 2.
   - **`"valid"`** — continue to step 2, using the returned `playbook` object's `id`, `name`, and
     `steps` fields. This object has the exact same field shape as one entry from
     `load-playbooks.sh`'s full-catalog output — the same shape `match-playbook.sh`'s
     `playbook_match` result carries `id`/`name`/`steps` in, for `/jenga`'s Natural-language
     branch step 5.

2. **Confirm and execute the chain** — follow `skills/jenga/SKILL.md`'s Natural-language branch
   **step 5, sub-steps a through e, verbatim** (conditional/origin metadata resolution; render and
   confirm the chain via `render-playbook-confirmation.sh`; the reply loop; sequential-runner
   `init`; the execute-in-a-loop procedure covering skip evaluation, `forward_from`/`resolve`
   resolution (`E53_S06_T01`), invocation, `advance`, and halt handling) exactly as written there
   — do not duplicate that prose here. Use the `id`/`name`/`steps` resolved in step 1 above
   wherever that section refers to `match-playbook.sh`'s `playbook_id`/`name`/`steps` output; every
   other detail (including how `forward_from`, `resolve`, conditionals, and composed/nested steps
   are handled) is identical, with no special-casing for this direct-invocation entry point.

   The one framing difference: step 5b's confirmation prompt need not (and should not) present
   this as a *proposal* the user might not have expected — they named this playbook explicitly by
   id. Otherwise render, confirm, and execute exactly as that section already does.

3. **On a `complete` or `halted` result** (per step 5e-v/5e-vi), report exactly as that section
   already specifies. This skill does not continue into any further phase — there is no `/jenga`
   Phase 1-4 to fall into here, since this is a direct entry point, not `/jenga` itself.

## Edge Cases

- **The looked-up playbook contains a `resolve` step or composed/nested steps** — handled
  identically to the natural-language path; no special-casing exists or is ever needed here (per
  story `E53_S06`'s fifth Acceptance Criterion).
- **The user cancels at the chain confirmation step (step 5c)** — identical posture to
  `/jenga`'s own playbook-confirmation cancellation: halt immediately after relaying the
  cancellation acknowledgement, with no step of the chain executed.
- **`load-playbooks.sh lookup` itself fails unexpectedly (exit code 2, usage/setup error)** — this
  is an environment/setup problem, not a normal `not_found`/`invalid` result; surface the script's
  stderr output to the user rather than treating it as either playbook-lookup outcome.

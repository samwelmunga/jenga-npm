# Foreground check-in and cost/cadence prompt

<!--
  Shared wording for the foreground step that precedes a dispatch (epic E67, story E67_S11).
  Consumers: skills/jenga/SKILL.md Phase 0.8 (E67_S11_T03); standalone /do and /dooo (E67_S11_T04).
  A caller reads this file and shows the "Prompt" section, with the placeholders below filled in, verbatim.
  It is the ONLY place this wording lives; callers reference it, they do not copy it.

  Placeholders (filled from facts the caller already holds, never invented):
    <N>           number of units in the confirmed scope (tasks, or one per bundled story); "at least <N>" when
                  some epic or story in scope is not yet broken down into tasks
    <scope mix>   the execution_scope distribution of those units, e.g. "3 task, 2 story, 1 inline"
    <cap>         max_concurrent_developers read from project/configs/scope-thresholds.json

  The ~30 minute cap and the mid-run report are the cadence agreed for background dispatch; the "no rework round
  without asking again" rule is part of dispatch-cost-and-cadence. Do not reword them per caller.
-->

## Prompt

The dispatch will run <N> units in the background (<scope mix>), up to <cap> at a time, each capped at about 30 minutes, with a mid-run report, and no rework round without asking again.

<!-- PLUG-IN POINT: measured-per-task-numbers (E90, E76)
     Replace ONLY the single sentence between the PLUG-IN markers below when measured per-task numbers exist
     (epic E90 owns the measurement, epic E76 owns the persisted per-task usage). Nothing else in this file or
     in any caller changes. Until then this sentence makes no forecast and points at the after-the-fact script. -->
<!-- PLUG-IN START -->
No time or usage forecast is made here; for numbers measured after the fact, run `scripts/task-usage.sh`.
<!-- PLUG-IN END -->

1. Proceed
2. Cancel
3. Other (describe below)

## Answer handling

- **1. Proceed** is the only answer that counts as the user's explicit yes to the stated cost and cadence.
- **2. Cancel** halts the run with nothing dispatched. The cost item is never ticked.
- **3. Other**, and any free text, is unresolved: answer it, then ask this prompt again. It never counts as a yes.

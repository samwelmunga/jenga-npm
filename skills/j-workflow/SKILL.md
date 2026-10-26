---
name: j.workflow
description: Run, inspect, pause, resume and cancel declarative multi-step workflows. Bare, it lists the available workflow definitions as a numbered picker; the sub-commands are run, status, list, resume, pause and cancel.
keywords:
  - run workflow
  - resume workflow
  - workflow status
  - pause workflow
examples:
  - "j.workflow run sprint"
  - "j.workflow resume"
  - "j.workflow status"
  - "what workflows can I run"
---

# Workflow — Run and Manage Declarative Workflows

## Purpose

A workflow is a definition of ordered steps (`skill`, `playbook`, `confirm`, `compute`, `render`) whose
run state is durable. This skill is only the driver: every lifecycle transition, reference substitution,
output verification and state write happens inside scripts. Nothing here computes, validates or writes
run state, and nothing here should be re-derived from the definitions: ask the script.

Scripts are resolved with the consumer-install fallback idiom. Shell state does not persist between Bash
calls, so begin every call that uses them with these assignments (only the ones needed):

```bash
RS="$([ -f scripts/workflow/run-state.sh ] && echo scripts/workflow/run-state.sh || echo node_modules/@jenga-ai/agent/scripts/workflow/run-state.sh)"
NS="$([ -f scripts/workflow/next-step.sh ] && echo scripts/workflow/next-step.sh || echo node_modules/@jenga-ai/agent/scripts/workflow/next-step.sh)"
CS="$([ -f scripts/workflow/complete-step.sh ] && echo scripts/workflow/complete-step.sh || echo node_modules/@jenga-ai/agent/scripts/workflow/complete-step.sh)"
SC="$([ -f scripts/workflow/step-confirm.sh ] && echo scripts/workflow/step-confirm.sh || echo node_modules/@jenga-ai/agent/scripts/workflow/step-confirm.sh)"
CLI="$([ -f skills/j-workflow/scripts/workflow-cli.sh ] && echo skills/j-workflow/scripts/workflow-cli.sh || echo node_modules/@jenga-ai/agent/skills/j-workflow/scripts/workflow-cli.sh)"
```

Below, `run-state.sh`, `next-step.sh`, `complete-step.sh` and `step-confirm.sh` mean `bash "$RS"`, `bash "$NS"`,
`bash "$CS"` and `bash "$SC"`; `bash "$CLI"` is `workflow-cli.sh`.

## Instructions

### 0. Bare invocation or a numeric argument

- **No argument:** run `bash "$CLI" list-render` and print its output **verbatim** as the numbered list it is.
  Then offer the picker in the CLAUDE.md Interaction Pattern format: one numbered option per workflow to run,
  then `Other (describe below)` as the final number. If the output is empty, say plainly that no workflows are
  available. Halt after the picker until the user chooses; a choice means `run <id>`.
- **Numeric argument** (`^[0-9]+$`): it is a list number. Run `bash "$CLI" resolve-definition <n>` and use the id
  it prints as `<id>`. Exit `1` means the number is out of range: report stderr (it names the valid range) and halt.

### 1. `run [<id>] [--input k=v ...]`

1. A bare `run` behaves as step 0 (list, then picker).
2. Run `run-state.sh start <id> [--input k=v ...]`. On success it prints only the new run id. On any failure
   (unknown workflow, bad or missing input) surface its stderr **verbatim** and halt; do not retry with guessed input.
3. Enter the run loop (section 2) with that run id.

### 2. The run loop

Repeat until a stop state is reached:

1. Run `next-step.sh <run_id>`. It prints one JSON object `{signal, run_id, step_id, type, payload}`. A non-zero
   exit is a usage or environment error, not a run state: surface stderr and halt.
2. Branch on `signal`.

**Signal `step`** — act on `type`, then report the outcome with `complete-step.sh`:

| type | what the agent does |
|------|---------------------|
| `skill` | The payload carries `invoke_as`, `instruction` and `prefered_agent`. Invoke the skill as `invoke_as` with the `instruction` (delegating to `prefered_agent` when set), then report. |
| `playbook` | The payload carries `playbook_id`, `name`, `steps` and `reinitialised`. Run it by following `skills/jenga/SKILL.md`'s Natural-language branch **step 5, sub-steps a through e, verbatim**, exactly as `j.playbook` step 2 does, using these fields in place of `match-playbook.sh`'s output. Report when the playbook completes or halts. |
| `confirm` | The payload carries the stored gate rendering. Relay it to the user **verbatim** (numbered options, free text last) and stop the loop; the reply is handled by section 3. Do **not** call `complete-step.sh` for a gate. |
| `compute`, `render` | `next-step.sh` executes these itself and returns the first action the agent must perform, so they normally never reach the loop. If a payload for one does arrive, show its produced text (or returned result) and report it as the payload directs. |

Report with `complete-step.sh <run_id> <step_id> passed [value]` or `... failed [note]`. Pass `passed` only when the
step really succeeded; a step that declares outputs needs the value (a JSON object keyed by output name when it
declares more than one). If `complete-step.sh` exits 1 for a type violation, read the rule on stderr and either
retry `passed` with a corrected value or report `failed`. Exit 2 is a setup problem (section 6). Then return to
loop step 1.

**Stop states** — report the state to the user, then stop. Do not call `next-step.sh` again in this turn:

- `complete` — every step finished; report the run id and, if shown by `status-render`, the registered outputs.
- `halted` — the run failed; report the failed step id and note from the payload. Offer `resume` (section 4).
- `awaiting_confirmation` — relay the stored gate rendering unchanged and wait for the user's reply (section 3).
- `paused` — report that the run is paused and that `j.workflow resume <run_id>` continues it.
- `cancelled` — report that the run was cancelled; nothing further runs.
- `error` — report the payload's `reason` verbatim. The step is left pending; do not skip it and do not report it
  as passed or failed.

### 3. Answering a pending gate

When the user replies to a relayed gate, run `step-confirm.sh reply <run_id> <step_id> "<raw reply>"`.

- Exit `0`: the answer is recorded and the step completed; print the chosen option and re-enter the run loop.
- Exit `3`: the reply was invalid. Re-print the stored rendering the script printed (with its one-line error),
  and wait again. No state changed.
- To re-show a pending gate, run `step-confirm.sh status <run_id>`.

### 4. `status [<run_id>]`, `list`, `resume [<run_id>]`

- **`status`:** `bash "$CLI" status-render [run_id]`; print verbatim. With no run id it prints the runs list.
- **`list`:** print `bash "$CLI" list-render` (definitions) then `bash "$CLI" runs-render` (runs), each verbatim and
  labelled, using the "none" sentence when one is empty.
- **`resume`:** with a run id, use it. Without one, run `bash "$CLI" resumable`, print it as a numbered list and
  ask which run (free text last). A number resolves with `bash "$CLI" resolve-run <n> --resumable`. Then run
  `run-state.sh resume <run_id>`; on success it prints JSON with `next_step`, so report where the run continues from
  and re-enter the run loop. Exit `6` means the definition changed since the run started: show stderr, then offer a
  numbered choice (resume anyway with `--allow-definition-change`, leave it, other). Only pass the flag after the
  user picks it.

### 5. `pause <run_id>`, `cancel <run_id>`

- **`pause`:** run `run-state.sh pause <run_id>` and report the resulting state.
- **`cancel`:** ask one numbered confirmation first and wait:

      Cancel run <run_id>? This cannot be resumed.
      1. Yes, cancel it
      2. No, leave it as it is
      3. Other (describe below)

  Only on option 1 run `run-state.sh cancel <run_id>` and report the resulting state. Any other answer changes nothing.
- With no run id, list candidates via `bash "$CLI" runs-render` as a numbered picker and resolve the choice with
  `bash "$CLI" resolve-run <n>`.

### 6. Edge cases

- **Exit 2 from any script** is a setup problem (missing `jq`, missing script, corrupt state, lock timeout). Surface
  its stderr; never treat it as a normal result and never retry in a loop.
- **Exit 1 from `status-render`** means the run does not exist; say so and offer `list`.
- **Never advance past `failed` or `awaiting_confirmation`** unless the script permits it: only `next-step.sh` decides
  what runs next, and a failed run moves only through `resume`.
- **Never write run state by hand** or edit definitions to get past a stop; all transitions go through the scripts above.

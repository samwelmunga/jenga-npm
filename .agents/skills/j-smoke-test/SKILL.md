---
name: j.smoke-test
description: Run a structural smoke test across every skill in the catalog (frontmatter, name versus directory, preferred agent, referenced scripts and assets) and report a pass/fail summary with findings classified as critical or minor.
keywords:
  - smoke test
  - skill health
  - catalog check
  - broken skills
  - j-smoke-test
examples:
  - "smoke test all the skills"
  - "j-smoke-test"
  - "are any skills broken?"
  - "check that every skill still hangs together"
---

# Smoke Test — Does every skill still hang together?

`skills/j-smoke-test/` is the **canonical, hand-edited** directory for this skill; the frontmatter name is `j.smoke-test`, never `j.j-smoke-test`. This file only sequences the harness and interprets its result. Every check, the critical-versus-minor severity bar and the output format live in `skills/j-smoke-test/scripts/smoke-test-skills.sh`, whose header is the contract; the critical-error table is rendered by `skills/j-smoke-test/scripts/render-error-table.sh`, likewise. Do not restate or re-implement them here.

## Boundaries

- **Structural, not functional.** It checks that each skill loads and its references resolve. It does not run `tests/*.bats`, and a clean smoke test says nothing about whether a skill behaves correctly.
- It is **not** `scripts/smoke-harness.sh`, which smoke-tests the diff of one in-flight inline task.
- Read-only: it never edits a skill and never writes board status. A finding is information for the user, not a verdict on any board item.

## Instructions

Resolve the scripts directory once, and create one scratch file for the findings:

```bash
SMOKE_DIR="$([ -d skills/j-smoke-test/scripts ] && echo skills/j-smoke-test/scripts || echo node_modules/@jenga-ai/agent/skills/j-smoke-test/scripts)"
FINDINGS="$(mktemp)"
```

Shell variables do not survive between separate commands: define `SMOKE_DIR` again in each later command, and use the literal findings path that `mktemp` printed.

### 1. Run the harness

```bash
bash "$SMOKE_DIR/smoke-test-skills.sh" > "$FINDINGS"
```

Its stderr is the pass/fail summary: relay it unchanged. Findings are JSON lines in `$FINDINGS`. Exit `0`: no critical finding. Exit `1`: at least one critical finding. Exit `2`: usage error or `jq` missing; show its stderr and stop.

### 2. Render the critical-error table

```bash
bash "$SMOKE_DIR/render-error-table.sh" "$FINDINGS"
```

Print its stdout verbatim. The table (columns **Feature**, **Error**, **Consequences**, shaped by `templates/CRITICAL_ERROR_TABLE_TEMPLATE.md` and registered as the `error_table` type in `templates/playbook-types.json`) holds only the critical findings. When there is no critical finding the script prints nothing: print no table, no heading and no placeholder for it. Exit `2`: show its stderr and stop.

### 3. Interpret the result

- Exit `0` with no findings: say every skill passed.
- Exit `0` with minor findings: say the catalog passed and list the minor findings briefly (`skill`, `error`).
- Exit `1`: the table from step 2 is the report; do not restate its rows. Offer next steps:

  ```
  What would you like to do?
  1. Fix one of the findings now (name it)
  2. Capture the findings as board items with j.todo
  3. Stop here
  4. Other (describe below)
  ```

Never fix a skill unprompted: the user chooses what to change.

When the user is done, remove `$FINDINGS`.

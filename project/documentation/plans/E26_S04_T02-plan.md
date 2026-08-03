# Execution Plan: Create npm setup wizard

**Task ID:** E26_S04_T02
**Story ID:** E26_S04
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** E26_S04_T02

---

## Task Summary
Author `skills/publish/wizards/npm.md`, a wizard definition (markdown) that mirrors `wizards/mobile-ios.md`. The wizard collects five inputs (package_name, access, dist_tag, registry, dry_run), writes a valid npm target block to `publish.json` per the S03 schema, prompts overwrite/update if an npm target already exists, and generates a `project/instructions/E26_S04_T02_INSTRUCTIONS.md` file explaining how to obtain and set `NPM_TOKEN`.

---

## Implementation Approach

1. Create a git worktree for this task.
2. Read the S03 schema to identify the exact `npmSettings` shape and target-level fields (`name`, `type=npm`, `platform`, `checks`, `secrets`, `npm`, optional `notes`).
3. Write `skills/publish/wizards/npm.md` following the `mobile-ios.md` structure: one `## Question: <field>` section per prompt, with `Maps to:` line, prompt body, and `## Expected format:` block.
4. Add the five prompts:
   - `package_name` — pre-fill from `package.json` name if present, validated against schema regex.
   - `access` — public (default) or restricted.
   - `dist_tag` — latest (default) or a custom tag.
   - `registry` — default `https://registry.npmjs.org`, customisable (GitHub Packages url shown as example).
   - `dry_run` — yes/no; if yes, is captured in the target's `notes` field (schema `additionalProperties: false` on `npmSettings` forbids extra fields).
5. Add a "Post-collection actions" section that instructs the agent to (a) load or create `publish.json`, (b) if an npm target exists ask overwrite/update, (c) write the target block per the example, (d) also write `project/instructions/E26_S04_T02_INSTRUCTIONS.md` with `NPM_TOKEN` steps.
6. Add a "Prerequisite: NPM_TOKEN" section describing what the token is, how to obtain it, and how to configure the env var.
7. Write the wizard so the emitted target block matches `skills/publish/assets/publish.example.npm.json` shape and passes the S03 schema.
8. Write the execution summary; do not commit (per task instructions).

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/wizards/npm.md` | New — wizard definition |
| `project/documentation/plans/E26_S04_T02-plan.md` | New — this plan |
| `project/documentation/summaries/E26_S04_T02-summary.md` | New — execution summary |

Note: the `project/instructions/E26_S04_T02_INSTRUCTIONS.md` file is written **by the wizard at runtime**, not statically by this task. However, per the developer agent rules, since this task requires the user to obtain an NPM_TOKEN before the wizard can be used, we also seed a static copy of that instructions file at task-authoring time.

---

## Dependencies & Risks

- Depends on the S03 schema at `skills/publish/schemas/publish.schema.json` (already merged — commits 360b958, cc94c88).
- Sibling task E26_S04_T01 (npm adapter) is not yet implemented but this wizard does not depend on it — the wizard writes to `publish.json`, not to the adapter.
- Risk: dry-run preference has no corresponding schema field. Mitigation: capture into the target-level `notes` field per the example config's convention.
- Risk: mobile-ios wizard has no explicit "post-collection actions" section (it's pure prompts). Deviating slightly by adding an "Actions" tail-section is necessary because the task requires overwrite prompt + instructions-file generation, both of which are agent behavior beyond simple prompt collection.

---

## Notes

- The wizard is a **markdown definition** consumed by an agent — no runtime code involved.
- Written to `skills/publish/wizards/npm.md` (repo source). The `/distribute` mechanism (or future npm dist) is responsible for propagating it to `.claude/skills/...` and `.agents/skills/...` on install.

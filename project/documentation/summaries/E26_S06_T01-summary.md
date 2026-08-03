# Execution Summary: Add npm branch to setup_wizard.sh

**Task ID:** E26_S06_T01
**Story ID:** E26_S06
**Epic ID:** E26
**Date Completed:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** agent-a71b83d4272665ef0

---

## What Was Implemented

Extended `skills/publish/scripts/setup_wizard.sh` to treat `npm` as a
first-class deployment type alongside `mobile-ios`:

- The `--type` CLI validator now accepts `npm` in addition to `mobile-ios`
  (previously only `mobile-ios` was allowed; anything else exited 4).
- `prompt_deploy_type` (the interactive selector used when `--type` is
  omitted) now offers two choices — `1. mobile-ios` and `2. npm` — with
  `mobile-ios` remaining the default so existing users see no behavior
  change on Enter.
- A new branch after template resolution short-circuits the npm flow:
  when `DEPLOY_TYPE == npm`, the script prints the resolved
  `wizards/npm.md` path plus a one-paragraph pointer to the wizard's
  "Post-collection actions" section, then exits 0. This is the correct
  handoff because `wizards/npm.md` is an agent-driven template (see
  Edge Cases below).
- The `mobile-ios` code path (question-field loop, `build_target_json`,
  `save_config`) is untouched — same execution, same JSON, same
  publish.json shape.

---

## Files Changed

| File | Summary of Changes |
|------|--------------------|
| `skills/publish/scripts/setup_wizard.sh` | Added `npm` option to interactive type prompt; added `npm` to CLI type whitelist; added early-return branch that prints the resolved wizard-template path and exits 0 when `DEPLOY_TYPE == npm`. |

---

## Commits

| SHA | Message |
|-----|---------|
| `5d4f02a` | feat(E26_S06_T01): add npm branch to setup_wizard.sh |

---

## Acceptance Criteria Coverage

| Criterion | Status | Notes |
|-----------|--------|-------|
| `setup_wizard.sh` accepts `--type npm` and invokes `wizards/npm.md` | Met | Smoke test with `--type npm` resolves `skills/publish/wizards/npm.md`, prints it, exits 0. |
| `setup_wizard.sh` still handles `--type mobile-ios` exactly as before | Met | Smoke test with `--type mobile-ios` still enters the iOS question loop (verified `## Question: bundle_id` prompt fires). No line inside the `mobile-ios` code path was changed. |
| If `--type` is not supplied, script prompts the user to select a type from a list | Met | `prompt_deploy_type` prints `1. mobile-ios` / `2. npm` and accepts numeric or literal answers. Verified with `printf '2\n' \| ...` selecting npm. |
| Script passes `shellcheck` after modification | Met | `shellcheck skills/publish/scripts/setup_wizard.sh` exits 0 with no warnings. |

---

## Edge Cases & Known Concerns

- **Why the npm branch does not run a shell question loop.** The iOS
  wizard (`wizards/mobile-ios.md`) is a machine-readable list of
  `## Question: <field>` sections that the script iterates over with
  `awk`, feeding each answer into `build_target_json`. `wizards/npm.md`
  is different — it is a prose/JSON specification that includes
  post-collection actions (writing a target block, creating
  `project/instructions/E26_S04_T02_INSTRUCTIONS.md`, validating against
  the schema) that the `/publish` agent performs. Reimplementing that
  in shell would (a) duplicate logic the agent already owns, (b) exceed
  T01's scope which is explicitly "add npm branch to setup_wizard.sh",
  and (c) fight the story boundary — T02–T04 own the other publish
  scripts, and the npm-target JSON assembly is not called out as this
  task's responsibility. The chosen approach — print the template path
  and exit — satisfies the acceptance criterion ("invokes wizards/npm.md
  and exits cleanly") without preempting parallel work.
- **Default choice preserved.** The interactive prompt still defaults to
  `mobile-ios` on empty input, so anyone with existing muscle memory
  from before this task lands on the same type they used to.
- **Invalid `--type` still fails 4.** Verified `--type bogus` exits 4
  with `unsupported deployment type 'bogus'`.

---

## Notes for Tester

- **Worktree:** `/Users/samwelmunga/Desktop/Projects/agents/.claude/worktrees/E26_S06_T01-setup-wizard-npm`
- **Branch:** `E26_S06_T01-setup-wizard-npm`
- **Suggested verification:**
  1. `shellcheck skills/publish/scripts/setup_wizard.sh` — expect exit 0.
  2. `bash skills/publish/scripts/setup_wizard.sh my-pkg --type npm` —
     expect exit 0 and a line pointing to `wizards/npm.md`.
  3. `bash skills/publish/scripts/setup_wizard.sh some-name --type bogus` —
     expect exit 4 with the "unsupported deployment type" error.
  4. `printf '2\n' \| bash skills/publish/scripts/setup_wizard.sh my-pkg` —
     expect the type prompt to list both options and the npm branch to
     run.
  5. `printf '\n' \| bash skills/publish/scripts/setup_wizard.sh my-ios --type mobile-ios` —
     expect the iOS question loop to start (`## Question: bundle_id`
     shown before it aborts on EOF). Confirms no regression.
- **Out of scope, do not test here:** downstream `publish_deploy.sh`,
  `run_gates.sh`, `validate_config.sh` npm handling — those are
  T02/T03/T04. Full end-to-end npm publish also out of scope until
  E26_S06 is complete.

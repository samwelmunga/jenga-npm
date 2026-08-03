# Execution Plan: Add npm branch to setup_wizard.sh

**Task ID:** E26_S06_T01
**Story ID:** E26_S06
**Epic ID:** E26
**Date:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** agent-a71b83d4272665ef0

---

## Task Summary
Extend `skills/publish/scripts/setup_wizard.sh` so that it accepts `--type npm`
in addition to the existing `--type mobile-ios`, and — when `--type` is
omitted — prompts the user to pick between the two. The npm branch must load
and drive `skills/publish/wizards/npm.md`. The mobile-ios branch must be
unchanged.

Scope is deliberately narrow: this task does not implement npm-target JSON
construction or `save_config` for npm (T02–T04 cover the downstream scripts
and the epic's story `E26_S04` owns the wizard content itself). What this
task must guarantee is that the CLI wiring — arg parsing, type validation,
type-selection prompt, wizard-template resolution — supports `npm` as a
first-class type.

---

## Implementation Approach

1. Update `prompt_deploy_type` to offer both `mobile-ios` and `npm` in the
   list, defaulting to `mobile-ios` (preserves existing muscle memory), and
   accept either the numeric choice or the literal type name.
2. Update the CLI arg validation to accept `mobile-ios` OR `npm` as valid
   `--type` values, rejecting anything else with the existing `fail`
   pattern.
3. Keep template resolution (`TEMPLATE_PATH="${SKILL_DIR}/wizards/${DEPLOY_TYPE}.md"`)
   as-is — it already resolves `wizards/npm.md` when `DEPLOY_TYPE=npm`.
4. Guard the iOS-only downstream work behind a `DEPLOY_TYPE` check so that
   `--type npm` does not crash by trying to run the iOS question-field loop
   or `build_target_json`. For npm, the script prints the wizard-template
   path and hands off to the Claude-driven wizard flow (see Notes below),
   then exits 0. This matches how `wizards/npm.md` is authored — the
   post-collection actions in that file are performed by the agent, not by
   this shell script (unlike the iOS wizard, whose questions map cleanly
   onto shell-side JSON assembly).
5. Verify `shellcheck` passes on the modified script.
6. Commit with the requested message.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/scripts/setup_wizard.sh` | Extend type prompt, add `npm` to CLI validation, branch on `DEPLOY_TYPE` so npm exits after printing the wizard-template path |

---

## Dependencies & Risks

- Depends on `skills/publish/wizards/npm.md` existing (delivered by E26_S04).
  Verified present.
- Downstream tasks (T02 `publish_deploy.sh`, T03 `run_gates.sh`,
  T04 `validate_config.sh`) are independent and can proceed in parallel.
- Risk: the iOS flow in this script inlines JSON assembly rather than
  delegating to a per-type helper. Introducing an equivalent for npm here
  would exceed scope. The chosen "print template path and exit" approach
  keeps this task minimal and matches the story's acceptance criterion
  ("invokes wizards/npm.md and exits cleanly"). The full npm question-and-
  save loop is the agent's responsibility per `wizards/npm.md` §
  "Post-collection actions".

---

## Notes

"Invoking" `wizards/npm.md` in a shell context means: resolving the template
path, printing it, and returning control to the caller (the `/publish` skill
agent) which then reads and executes the wizard prompts. This mirrors how
`wizards/npm.md` is written — it is a prose/JSON specification interpreted
by an agent, not a machine-readable question list like `mobile-ios.md`.

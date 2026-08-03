# Execution Plan: Update publish SKILL.md with npm examples and metadata

**Task ID:** E26_S07_T01
**Story ID:** E26_S07
**Epic ID:** E26
**Date:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** E26_S07_T01_session

---

## Task Summary
Update `skills/publish/SKILL.md` so it reads as a multi-target publish orchestrator (mobile-ios + npm) rather than iOS-only. Add npm invocation examples, update the sub-command table setup notes, refresh metadata to drop iOS-only framing, document the `--dry-run` flag under deploy, and move iOS-specific detail into a clearly-labelled section.

---

## Implementation Approach

1. Update frontmatter:
   - Add npm examples to `examples`: `publish setup --type npm`, `publish deploy --target npm-registry`, `publish deploy --target npm-registry --dry-run`.
   - Change `metadata.scope` from `ios-v1-complete` to `multi-target-v2`.
   - Change `metadata.primary_target` from `mobile-ios` to a multi-target value (`multi` — mobile-ios and npm both supported).
   - Change `metadata.primary_platform` similarly (drop the ios-app-store hard-coding; use `multi`).
   - Extend `keywords` with `npm` since it is now a first-class target type.
2. Rewrite the top intro paragraph to be neutral multi-target (mention mobile-ios and npm are the current adapters, iOS App Store details live below).
3. Update the sub-command table row for `/publish setup` notes to mention supported types `mobile-ios` and `npm` (add a Notes column if none exists — currently the table has no notes column, so surface support inside the Purpose cell or add explicit prose after the table).
4. Update the `/publish setup` Usage Signature so the `--type` flag reflects both types (`--type mobile-ios|npm`), and update wizard step 2 to no longer say "currently `mobile-ios`".
5. Under `/publish deploy`, add an explicit paragraph or bullet documenting the `--dry-run` flag behaviour (it is already mentioned inline; make it prominent).
6. Restructure the Configuration Model: keep the "Required target structure for `mobile-ios`" as a subsection under a new "iOS App Store" section, and add a sibling "npm registry" pointer noting that npm target details live in the npm adapter/wizard (do not duplicate the schema here — the story that owns npm target schema is E26_S03).
7. Commit at one milestone (frontmatter + body updates together — the file is small and edits are cohesive), write the execution summary, and hand off to tester.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| skills/publish/SKILL.md | Frontmatter examples/keywords/metadata refresh; body reframed as multi-target; `--dry-run` doc; iOS-specific detail scoped to an "iOS App Store" section; setup wizard signature/notes updated to include `npm`. |

---

## Dependencies & Risks

- No script or code changes are required — pure documentation.
- Risk: overstating what the npm adapter/wizard can do. Task E26_S07_T01 is scoped to SKILL.md text only; concrete npm schema/wizard details are owned by other stories in E26. Cross-references will point at the schema and wizard files rather than duplicating them.
- Risk: breaking existing metadata consumers. `metadata.scope` is a free-form string and is not (per grep) consumed by any script — a rename is safe.

---

## Notes

- The task instructs "at least two npm examples". Adding all three named examples (`setup --type npm`, `deploy --target npm-registry`, `deploy --target npm-registry --dry-run`) satisfies both the count and the `--dry-run` visibility requirement.
- Leave the existing iOS App Store adapter cross-reference (`skills/publish/adapters/mobile-ios.md`) in place under the new iOS section.

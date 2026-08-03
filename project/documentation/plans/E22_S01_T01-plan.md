# Execution Plan: /publish Skill Scaffold, Schema, and CI Contract

**Task ID:** E22_S01_T01
**Story ID:** E22_S01
**Epic ID:** E22
**Date:** 2026-07-11 (UTC)
**Agent:** developer
**Session ID:** 88d3f412-a3db-4356-aa58-96c6d8860c37

---

## Task Summary
Implement the scaffold-only first story for `/publish` by creating the skill entrypoint, defining the canonical `publish.json` schema and example config, and documenting the non-interactive deploy contract with a validation stub that runs before any sub-command work. This plan intentionally covers E22_S01_T01, E22_S01_T02, and E22_S01_T03 in one implementation pass.

---

## Implementation Approach
1. Review existing skill frontmatter and runtime conventions so the new `/publish` skill matches repository patterns while staying within the story's scaffold-only scope.
2. Create the `skills/publish/` structure with `SKILL.md`, `schemas/`, `assets/`, and `scripts/` directories.
3. Mirror the skill entrypoint into `.agents/skills/publish/` and `.claude/skills/publish/` so the existing help MCP discovery path can list the new skill.
4. Author `SKILL.md` as a thin orchestrator spec with frontmatter, the four required sub-commands, usage signatures, option flags, config/schema references, and a clear statement that `validate_config.sh` runs before every invocation.
5. Define `publish.schema.json` as a draft-07 schema for the canonical `publish.json` contract, including targets, secrets as env-var references, per-target gate overrides, and iOS-oriented v1 platform constraints.
6. Create `publish.example.json` as a valid example config aligned with the schema and the narrowed v1 iOS scope.
7. Write a CI-facing contract document describing required flags, env vars, defaults, and exit codes for non-interactive `/publish deploy` usage.
8. Implement `validate_config.sh` as a bash script that uses `jq` to verify file presence, JSON syntax, and schema-aligned structure, returning exit code 4 with human-readable stderr messages on failure.
9. Manually validate the scaffold by checking executable bits, running the validator against valid and invalid inputs, and confirming the help MCP server now detects `publish`.
10. Commit at meaningful milestones, then write the execution summary and hand off to the tester agent with the full sender object.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/SKILL.md` | Create the `/publish` skill scaffold, frontmatter, usage, sub-command specs, and validation contract references. |
| `skills/publish/schemas/publish.schema.json` | Define the canonical draft-07 schema for `publish.json`. |
| `skills/publish/assets/publish.example.json` | Add a valid example config matching the schema. |
| `skills/publish/assets/ci-contract.md` | Document the non-interactive deploy contract in detail. |
| `skills/publish/scripts/validate_config.sh` | Add the bash + `jq` config validation stub. |
| `.agents/skills/publish/SKILL.md` | Mirror the skill entrypoint into the MCP help discovery path. |
| `.claude/skills/publish/SKILL.md` | Mirror the skill entrypoint into the local Claude skill path. |
| `project/documentation/plans/E22_S01_T01-plan.md` | Record this execution plan. |
| `project/documentation/summaries/E22_S01_T01-summary.md` | Record the implementation summary before tester handoff. |

---

## Dependencies & Risks
- `jq` must be available for the validation stub; the current environment already provides it.
- The repository currently uses multiple skill roots (`skills/`, `.agents/skills/`, `.claude/skills/`), so discovery can drift if the scaffold is only written to one path.
- `jq` is not a full JSON Schema engine, so the validator will enforce the schema contract through schema-aligned structural checks rather than generic draft-07 evaluation.
- Story scope explicitly excludes real deploy logic, setup wizard logic, and quality gate execution; the scaffold must avoid implying those are implemented.

---

## Notes
- No user-action prerequisite file is needed because this story only scaffolds documentation, schema, and validation logic.
- The skill will be documented as iOS App Store v1 oriented, but still model generic target metadata needed for later stories.
- Validation will focus on `publish.json` supplied by path, while the skill documentation will point to `project/configs/publish.json` as the canonical default location.

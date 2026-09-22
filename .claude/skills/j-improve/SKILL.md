---
name: j.improve
description: A skill for analyzing a codebase and producing a structured improvement plan toward a defined goal.
keywords:
  - j-improve
---

# Improve

`skills/j-improve/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-improve/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/improve/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

Before doing anything, check the attached description for an explicit or implicit goal.

- **Explicit goal**: clearly stated (e.g. "improve login performance")
- **Implicit goal**: inferable from context (e.g. "the checkout flow feels slow" → goal: improve checkout performance)

If no goal can be determined, ask:
> "What's the outcome you're trying to achieve with this improvement?"

Do not proceed until a goal is confirmed.

---

## Steps

### 1. Search the Codebase
Search for files and flows relevant to the target goal. Look for:
- Entry points, handlers, or controllers related to the feature
- Shared utilities or services it depends on
- Recent changes in the area (if git history is accessible)

### 2. Check Project Documentation
Look in `project/documentation/` for `.md` files that offer insight into:
- Architecture decisions
- Known limitations
- Intended behavior of the relevant area

### 3. Evaluate Insight Sufficiency
Assess whether you have enough context to evaluate current behavior against the goal.

- If yes: proceed to step 5.
- If no: proceed to step 4.

### 4. Run `/examplify`
Invoke the `/examplify` skill. Specify clearly what you want it to find out — e.g. which code paths are exercised, what inputs/outputs look like, or what edge cases exist.

### 5. Run `/evaluate`
Copy `.agents/skills/j-evaluate/assets/evaluation_invokation_template.yml` and fill in:
- `paths`: path(s) to the relevant example files
- `goal`: the confirmed target goal

This generates `<target-goal-in-kebab-case>-eval.md` inside `project/rapports/analysis/`.

### 6. Invoke `/todo`
Call `/todo` with the following message:

"invoke /brainstorm <path-to-evaluation-rapport>".

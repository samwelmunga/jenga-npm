---
name: improve
description: A skill for analyzing a codebase and producing a structured improvement plan toward a defined goal.
---

# Improve

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
Copy `.agents/skills/evaluate/assets/evaluation_invokation_template.yml` and fill in:
- `paths`: path(s) to the relevant example files
- `goal`: the confirmed target goal

This generates `<target-goal-in-kebab-case>-eval.md` inside `project/rapports/analysis/`.

### 6. Invoke `/todo`
Call `/todo` with the following message:

"invoke /brainstorm <path-to-evaluation-rapport>".

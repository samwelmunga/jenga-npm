---
name: j.evaluate
description: Analyzes example files against a target goal and produces a structured evaluation rapport.
keywords:
  - j-evaluate
---

# Evaluate

`skills/j-evaluate/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-evaluate/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/evaluate/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Input

Expects a filled `eval_invokation_template.yml` with:
- `goal`: the confirmed target goal
- `paths`: list of example files from `/examplify` to analyze

## Steps

### 1. Read Input
Parse the provided YAML file. If `goal` is empty or `paths` is empty/missing, 
stop and ask the user to fill in the missing fields before proceeding.

### 2. Read Example Files
Load each file listed under `paths`. These are outputs from `/examplify` and 
represent real observed behavior in the codebase.

### 3. Analyze Against Goal
For each example file, evaluate:
- **Qualitative observations**: What is the current behavior? How does it relate 
  to the goal?
- **Gaps and issues**: What is missing, broken, or misaligned relative to the goal?
- **Score**: How well does the current behavior satisfy the goal? 
  Use a simple 1–5 scale with a one-line justification.

### 4. Synthesize
Across all examples, identify:
- Recurring patterns or systemic issues
- The most critical gaps blocking the goal
- Any areas that are already well-aligned

### 5. Write Rapport
Copy `evaluation_rapport_template.md`. Derive the rapport filename from the goal in kebab-case:
`<target-goal-in-kebab-case>-eval.md`

Fill in the rapport based on the template structure and save to `project/rapports/analysis/` with this structure.

### 6. Return
Return the rapport filename to the caller (e.g. `/improve`).

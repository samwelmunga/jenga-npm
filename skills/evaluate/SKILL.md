---
name: evaluate
description: Analyzes example files against a target goal and produces a structured evaluation rapport.
---

# Evaluate

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

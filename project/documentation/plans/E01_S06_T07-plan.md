# Plan: E01_S06_T07 — Two-Phase CLI Orchestration in /train Skill

## Objective
Wire a pre-flight → smoke test execution pipeline into a new `/train` skill CLI.

## Approach

### Files to Create
1. `skills/train/SKILL.md` — AI-agent instruction definition for the skill
2. `skills/train/train_cli.py` — Concrete Python CLI script implementing two-phase orchestration

### Phase Breakdown

**Phase A — Pre-flight (validate.py)**
- Run `python validate.py` as subprocess in job directory
- Stream stdout/stderr in real time
- Halt on non-zero exit with clear error message
- Print pass confirmation on zero exit

**Phase B — Smoke test (train.py --smoke)**
- Only runs if Phase A passed
- Run `python train.py --smoke` as subprocess in job directory
- Stream stdout/stderr in real time
- Report pass/fail

### CLI Subcommands
- `new <type> <job-name>`: scaffold from `.training/template/<type>/` to `jobs/<job-name>/`
- `run <job-dir>`: execute two-phase pipeline

### Testing Plan
Test against all three template types (classifiers, transformers, nlp), then clean up.

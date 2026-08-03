---
id: E01_S06
epic_id: E01
title: Training Skill Assets & Standardized Templates
status: Passed
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S06_T01
  - E01_S06_T02
  - E01_S06_T03
  - E01_S06_T04
  - E01_S06_T05
  - E01_S06_T06
  - E01_S06_T07
---

# Story: Training Skill Assets & Standardized Templates

As a developer using the `/train` skill, I want each model training type (classifiers, transformers, nlp) to ship with a self-contained set of standardized assets — minimal but correctly structured stub data, a type-specific `validate.py`, a smoke-testable `train.py`, and a version-stamped `config.yaml` — so that a scaffolded job can be immediately verified and run without any manual setup.

## Acceptance Criteria

**Asset files (per template)**
1. Each of `classifiers/`, `transformers/`, `nlp/` contains: `train.py`, `validate.py`, stub data file, and `config.yaml` with a `template_version` field.
2. No shared lib exists between templates — each directory is fully self-contained.

**Stub data**
3. `classifiers` stub: a CSV file with labeled rows and the correct column names (at minimum a features column and a label column).
4. `transformers` stub: a token sequence data file (e.g. newline-delimited sequences) readable without additional preprocessing.
5. `nlp` stub: one or more raw `.txt` files with non-empty text content.
6. Each stub must be parseable by its corresponding `validate.py` — the file must exist, be openable, and yield at least one row/record with the expected structure.

**`validate.py` behaviour**
7. `validate.py` performs an existence check — exits non-zero with a clear error message if the stub data file is missing.
8. `validate.py` performs light parsing — reads one row/record and checks column names or structural shape against expected schema for its type.
9. On success, `validate.py` exits zero and prints a human-readable pass message.
10. On failure, `validate.py` exits non-zero and prints a descriptive failure message identifying what was wrong.

**`train.py` smoke test**
11. `train.py` accepts a `--smoke` flag that limits training to one epoch using the stub data.
12. In smoke mode, `train.py` produces at least one output artifact (e.g. a model checkpoint or `results.json`) in the job output directory.
13. `train.py` does NOT call `validate.py` directly — validation is owned by the `/train` skill CLI.

**`template_version` in `config.yaml`**
14. Each template's `config.yaml` includes a `template_version` field (semver, e.g. `"1.0.0"`).
15. The `/train` skill stamps this field at scaffold time from the current template manifest version.

**Drift warning**
16. When a scaffolded job's `template_version` is behind the current template manifest version, the `/train` skill prints a non-blocking warning before proceeding (e.g. `⚠ Template version mismatch: job uses 1.0.0, current is 1.1.0`).
17. The skill does NOT block execution on a version mismatch — it warns only.

**CLI orchestration**
18. Running `/train` on a scaffolded job triggers Phase A: the skill calls `validate.py` as a subprocess — halts with the validation error if it exits non-zero.
19. If Phase A passes, Phase B runs automatically: the skill calls `train.py --smoke` as a second subprocess.
20. `train.py` and `validate.py` have no awareness of each other — the `/train` skill CLI owns the gate.

## Definition of Done
- [ ] All three template directories contain `train.py`, `validate.py`, a correctly structured stub data file, and a `config.yaml` with `template_version`
- [ ] Each `validate.py` passes its own existence + parse checks against its stub data
- [ ] Each `train.py` completes a one-epoch smoke run and produces an output artifact
- [ ] The `/train` skill orchestrates `validate.py → train.py --smoke` in sequence via subprocess calls
- [ ] The skill prints a non-blocking warning when `template_version` in the job config is behind the current manifest
- [ ] All three template types tested end-to-end through the CLI gate

## Board Dependencies
- **E01_S02** must be at least In Progress before T04 and T05 can be finalized — the `config.yaml` schema (including the `workflow:` block) is owned by that story.

---
id: E01_S05
epic_id: E01
title: Result Surfacing
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S05_T01
  - E01_S05_T02
  - E01_S05_T03
---

# Story: Result Surfacing

As a developer, I want training results parsed and surfaced in four formats automatically after training completes so that I can immediately review outcomes without manually digging through output files.

## Acceptance Criteria
- [ ] **Terminal print**: key metrics (loss, accuracy, F1, or equivalent per type) are printed to the session after training
- [ ] **`summary.md`**: a human-readable summary is written inside the job directory
- [ ] **`results.json`**: a structured results file is written inside the job directory; schema is consistent per training type
- [ ] **`dashboard.html`**: a type-specific HTML file is written inside the job directory:
  - `classifiers` — confusion matrix + feature importance chart
  - `transformers` — loss curves + eval metrics table
  - `nlp` — entity/label distribution + F1 per class table
- [ ] All four outputs are skipped gracefully (no error) when `auto_summarize: false`
- [ ] Result surfacing is triggered both from `training_runner` MCP completion and from `start.sh` completion path
- [ ] If `training-results/` is empty or missing expected files, a clear warning is printed instead of a silent no-op

## Definition of Done
- [ ] All four output formats are produced correctly for each training type (classifiers, transformers, nlp)
- [ ] `dashboard.html` renders correctly in a browser for each type
- [ ] `auto_summarize: false` suppresses all outputs without error
- [ ] Both trigger paths (MCP + `start.sh`) produce identical outputs

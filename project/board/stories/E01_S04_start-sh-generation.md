---
id: E01_S04
epic_id: E01
title: start.sh Generation
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
tasks:
  - E01_S04_T01
  - E01_S04_T02
---

# Story: start.sh Generation

As a developer, I want a `start.sh` script emitted in the job directory when `generate_start_sh: true` so that I can run training manually outside the agent session and still benefit from result surfacing on completion.

## Acceptance Criteria
- [ ] `start.sh` is only written when `generate_start_sh: true` in the job's `config.yaml`
- [ ] The script runs `python training/main.py` from the job directory
- [ ] On training completion (exit 0), the script triggers result surfacing (calls the result surfacing logic or equivalent CLI entry point)
- [ ] The file is executable (`chmod +x`) at creation time
- [ ] The `/train` skill's next-steps output explicitly mentions `start.sh` and its path when the file was generated
- [ ] If `auto_summarize: false` in config, `start.sh` skips result surfacing and exits cleanly

## Definition of Done
- [ ] `start.sh` is generated correctly in all relevant scaffold scenarios
- [ ] Script is executable and runs end-to-end without agent session involvement
- [ ] Result surfacing integration matches Story E01_S05 output spec

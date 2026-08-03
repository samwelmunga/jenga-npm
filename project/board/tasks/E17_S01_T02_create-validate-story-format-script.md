---
id: E17_S01_T02
story_id: E17_S01
epic_id: E17
title: Create scripts/validate-story-format.sh
status: Passed
date_created: 2026-06-06
date_started:
date_completed: 2026-06-06
assigned_to: developer
---

# Task: Create scripts/validate-story-format.sh

## Description
Create a shell script at `scripts/validate-story-format.sh` that validates a story markdown file against the required format rules.

**Usage:** `./scripts/validate-story-format.sh <path-to-story-file>`

**Validation checks (in order):**
1. File exists and is readable — exit 1 if not
2. `## Acceptance Criteria` section is present — exit 2 if missing
3. `## Definition of Done` section is present — exit 3 if missing
4. DoD section contains at least one `- [ ]` checkbox — exit 4 if only plain bullets or empty

On success: exit 0 and print a human-readable pass message (e.g. `✅ E17_S01: story format valid`).
On failure: exit with the appropriate code and print a descriptive message identifying exactly what was wrong and which file failed.

The script must be executable (`chmod +x`).

## Prerequisites

## Acceptance Criteria
- [ ] Script exists at `scripts/validate-story-format.sh` and is executable
- [ ] Exits 0 with a pass message on a correctly-formatted story file
- [ ] Exits non-zero with a clear error message when AC section is missing
- [ ] Exits non-zero with a clear error message when DoD section is missing
- [ ] Exits non-zero with a clear error message when DoD has no `- [ ]` checkboxes (plain bullets only)
- [ ] Script is idempotent — running it multiple times on the same file produces the same result

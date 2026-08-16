# project/configs

This directory holds version-controlled configuration files consumed by JengaAgent skills at runtime.

---

## scope-thresholds.json

Runtime threshold values used by `/jenga` and `/do` to determine execution scope per task.

### Fields

| Field | Type | Initial Value | Description |
|-------|------|---------------|-------------|
| `threshold_version` | integer | 1 | Version counter for this config. **Must be incremented every time any threshold value changes.** This makes threshold drift visible in git history and code review. |
| `inline_max_files` | integer | 1 | Maximum number of files a task may touch to qualify for `inline` execution scope (no subagent, no worktree). |
| `inline_max_lines` | integer | 20 | Maximum total lines changed for a task to qualify for `inline` execution scope. |
| `story_max_files` | integer | 5 | Maximum number of files a task may touch to qualify for `story` scope bundling (multiple tasks executed in one developer context). |
| `bundle_lock_ttl_minutes` | integer | 30 | Time-to-live in minutes for a story-scope bundle lock. A lock older than this value is considered stale and may be reclaimed. |

### Versioning Convention

When you change any threshold value:

1. Update the value(s) in `scope-thresholds.json`.
2. Increment `threshold_version` by 1.
3. Commit the change with a message describing which threshold changed and why.

This ensures every threshold change is a distinct, reviewable commit — no silent drift.

### Consuming Skills

- `skills/jenga/SKILL.md` — reads all threshold fields at Phase 0 startup
- `skills/do/SKILL.md` — reads all threshold fields at Step 0 startup

Both skills halt with a clear error if this file is missing or contains invalid JSON.

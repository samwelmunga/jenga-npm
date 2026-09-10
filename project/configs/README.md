# project/configs

This directory holds version-controlled configuration files consumed by Jenga AI skills at runtime.

---

## scope-thresholds.json

Runtime threshold values used by `/jenga` and `/do` to determine execution scope per task.

### Fields

| Field | Type | Current Value | Description |
|-------|------|---------------|-------------|
| `threshold_version` | integer | 2 | Version counter for this config. **Must be incremented every time any threshold value changes.** This makes threshold drift visible in git history and code review. |
| `inline_max_files` | integer | 3 | Maximum number of files a task may touch to qualify for `inline` execution scope (no subagent, no worktree). Raised from 1 to 3 (`threshold_version: 2`) — a 1-file cap forced small multi-file work (e.g. a `SKILL.md` plus one small script, the standard "delegate deterministic logic to a script" shape required by CLAUDE.md's Skill Implementation Principle) through the full worktree+tester pipeline, which costs disproportionately more than the change itself. See `E42_S04_T01` for the case that surfaced this. |
| `inline_max_lines` | integer | 75 | Maximum total lines changed for a task to qualify for `inline` execution scope. Raised from 20 to 75 alongside `inline_max_files` for the same reason — a small `SKILL.md` + script pair routinely exceeds 20 lines. |
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

---

## playbook-config.json

Deliberately a **separate file** from `scope-thresholds.json` (`E53_S05_T01`) — the fields above
are specifically `/jenga`/`/do` task **execution-scope** thresholds, a different concern from
playbook nesting-depth safety limits. Read by `skills/jenga/scripts/load-playbooks.sh` only.

### Fields

| Field | Type | Current Value | Description |
|-------|------|---------------|-------------|
| `config_version` | integer | 1 | Version counter for this config, mirroring `scope-thresholds.json`'s own `threshold_version` convention. Increment whenever a value below changes. |
| `max_composition_depth` | integer | 3 | Maximum playbook-to-playbook composition nesting depth `load-playbooks.sh` allows before dropping a playbook (with a stderr warning) at load time. A **tunable safety default**, not an architectural ceiling — depth 1 is a playbook's own steps; depth 2 is one level of composition; a chain nesting deeper than this value is rejected. Missing file, missing field, or a non-positive-integer value all fall back to the hardcoded default of 3. |

### Consuming Skills

- `skills/jenga/scripts/load-playbooks.sh` — reads `max_composition_depth` once per invocation,
  resolving the project root the same way `skills/jenga/scripts/run-playbook-step.sh` already does
  (`JENGA_PROJECT_DIR` -> `CLAUDE_PROJECT_DIR` -> `git rev-parse --show-toplevel` -> `pwd`; the
  existing `JENGA_PLAYBOOKS_TEST_ROOT` fixture override is reused for this lookup too — see that
  script's own header). Missing or invalid config is a soft fallback to the default, never a halt
  (composition depth-limiting is a safety default, not a required setup file).

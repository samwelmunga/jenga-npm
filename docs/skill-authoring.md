# Skill Authoring Guide

Skills are stored in `skills/<name>/SKILL.md` and invoked with `/<name>` in a Claude Code session.

---

## Frontmatter Spec

Every `SKILL.md` begins with a YAML frontmatter block. All fields except `name` and `description` are optional.

```yaml
---
name: <skill-name>
description: <one-sentence description shown in /help listings>
metadata:
  prefered_agent: <agent_name>       # optional — delegate execution to a sub-agent
keywords:                            # optional — short phrases for keyword routing
  - "<phrase 1>"
  - "<phrase 2>"
examples:                            # optional — natural-language prompts for semantic routing
  - "<example prompt 1>"
  - "<example prompt 2>"
minimum_permission_level: <1-5>       # optional — minimum session permission level required to run this skill
---
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | ✅ | Skill name. Must match the directory name under `skills/`. |
| `description` | string | ✅ | One-sentence description shown in `/help` listings and the skill registry. |
| `metadata.prefered_agent` | string | ❌ | Sub-agent to delegate execution to. Valid values: `scrum-master`, `developer`, `tester`. |
| `keywords` | string[] | ❌ | Short words or phrases (1–3 words) strongly associated with this skill. Used by the Jenga Router for keyword matching. |
| `examples` | string[] | ❌ | Natural-language prompt strings that should trigger this skill. Used by the Jenga Router for semantic matching. |
| `minimum_permission_level` | integer | ❌ | Minimum session permission level (`1`-`5`) required to run this skill. Skills that set this field must gate execution via `scripts/check-permission-level.sh`. |

---

### `keywords`

An optional array of short strings (1–3 words each) that are strongly associated with this skill. The Jenga Router uses these for fast keyword-based dispatch before falling back to semantic matching.

**Guidelines:**
- Keep phrases short — one to three words.
- Include the canonical command name as well as common synonyms.
- Avoid generic words that could match many skills (e.g. "task", "run").

**Example:**
```yaml
keywords:
  - "brainstorm"
  - "plan"
  - "feature planning"
  - "scrum planning"
```

---

### `examples`

An optional array of natural-language strings representing prompts that should trigger this skill. The Jenga Router uses these for semantic (embedding-based) matching when keyword matching yields no clear winner.

**Guidelines:**
- Write examples as a user would naturally type them.
- Cover diverse phrasings of the same intent.
- Aim for 3–8 examples per skill.

**Example:**
```yaml
examples:
  - "let's plan a new feature"
  - "I need to brainstorm ideas for X"
  - "help me think through this epic"
  - "can we scope out the next milestone?"
```

---

### `minimum_permission_level`

An optional integer (`1`-`5`) declaring the minimum session permission level a skill needs to run correctly. This corresponds to the 5-tier system defined by the `/jenga-permission-level` epic: `1` = Locked, `2` = Guarded (the permanent default), `3` = Standard, `4` = Elevated, `5` = Unrestricted. See the level matrix under `templates/permission-levels/` for what each tier permits.

Set this field only when a skill genuinely cannot complete its work at the default Guarded (2) level — e.g. it needs to run commands that Guarded denies. Most skills should omit this field entirely and run at the default level.

**Guidelines:**
- Use the lowest level that actually satisfies the skill's needs — never request more than necessary.
- Skills that set this field **must** call `scripts/check-permission-level.sh <minimum-level>` at the top of their instructions, before any other work, to gate execution on the current session level.
- If the current session level is below the declared minimum, the skill must surface an explicit confirmation prompt to the user before elevating — silent auto-elevation is never permitted.
- Elevation happens via the same mechanism as `/jenga-permission-level <n>` (i.e. the skill drives the same level switch, it does not invent a separate one).
- Immediately after the skill's own work completes, reset the session level back to Guarded (2) — regardless of what level it was elevated to. Elevation must never be held past the skill's own execution, and must never be left for the next session start to clean up.
- Do not use this field to hold a session at an elevated level across multiple skills or commands — each elevation is scoped to a single skill invocation.

**Example:**
```yaml
minimum_permission_level: 4
```

---

## Complete Example

```yaml
---
name: brainstorm
description: Engage the scrum-master agent in a focused planning session to define, refine, or challenge features, improvements, tasks, stories, and epics.
metadata:
  prefered_agent: scrum-master
keywords:
  - "brainstorm"
  - "plan"
  - "feature planning"
examples:
  - "let's plan a new feature"
  - "I need to brainstorm ideas for X"
  - "help me think through this epic before committing it to the board"
---
```

---

## Skill Body

After the frontmatter, write the skill instructions in plain Markdown. The instructions are passed directly to the executing agent (or to the main Claude Code agent if no `prefered_agent` is set).

Follow these conventions:

- Use numbered steps for sequential workflows.
- Use `bash` code blocks for any shell commands the skill should run.
- Reference board paths via `$(bash scripts/board_resolver.sh)` rather than hard-coding them.
- Keep the skill body focused on *what to do*, not *how Claude works*.

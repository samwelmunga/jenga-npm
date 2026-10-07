# Jenga Completion Signal Protocol

## Overview

The Jenga Router uses an in-memory session to track which skill is currently active. While a session is active, every subsequent prompt is passed through directly to that skill without going through normal pattern matching. The **completion signal** is the mechanism by which a skill tells the router that its session is finished and normal matching can resume.

---

## Signal Format

```
[JENGA:SESSION_END:<skill_name>]
```

- Must appear **on its own line** in the skill's output.
- `<skill_name>` must match the skill's registered name exactly (case-sensitive, kebab-case).
- The marker is **stripped from visible output** by the post-response watcher — the user never sees it.

### Examples

| Skill | Signal |
|-------|--------|
| `brainstorm` | `[JENGA:SESSION_END:brainstorm]` |
| `do` | `[JENGA:SESSION_END:do]` |
| `btw` | `[JENGA:SESSION_END:btw]` |

---

## Full Flow

```
Skill output
    │
    │  emits [JENGA:SESSION_END:<skill_name>] on its own line
    ▼
Post-response watcher / hook
    │
    ├─ 1. Detects the marker in Claude's raw output
    ├─ 2. Calls end_session(<skill_name>) on the Jenga Router (via MCP tool)
    ├─ 3. Strips the marker line from displayed output
    └─ 4. Passes the cleaned output to the user
           │
           ▼
       Jenga Router
           │
           └─ Clears activeSkill → resumes normal prompt matching
```

### Step-by-step

1. **Skill emits the signal.** At the natural conclusion of its session the skill outputs `[JENGA:SESSION_END:<skill_name>]` on its own line. This is the only required action on the skill's part.

2. **Watcher detects the marker.** A post-response hook scans every assistant response for the pattern `\[JENGA:SESSION_END:[^\]]+\]`. Detection is line-based; partial matches on a shared line are ignored.

3. **`end_session` is called.** The watcher extracts the skill name from the marker and calls the `end_session(skill)` MCP tool on the router. If the named skill is not the currently active skill the call is a no-op (no error is raised).

4. **Marker is stripped.** The line containing the marker is removed from the output before it is rendered. The user sees only the skill's human-readable farewell message (if any).

5. **Router clears the session.** The router sets `activeSkill → null` and `startedAt → null`. All subsequent `route_prompt` calls resume normal pattern matching.

---

## Why This Signal Exists

Without an explicit completion signal the router has no way to know when a skill session is over. It would hold `activeSkill` set until the session auto-expires (default **300 seconds / 5 minutes**). During that window every prompt — regardless of content — would be passed through to the previously-active skill instead of being matched normally. This blocks all other skills and produces confusing behaviour for the user.

The signal gives the skill full control over session lifetime and eliminates the need for users or the router to guess when a skill is done.

---

## Session Auto-Expiry (Fallback)

If a skill fails to emit the signal (e.g. due to an error or an incomplete implementation), the router will automatically clear the session after `sessionTimeout` ms of inactivity. The default is **300 000 ms (5 minutes)**, configurable in `jenga.cli.json`:

```json
{
  "sessionTimeout": 300000
}
```

Auto-expiry is a safety net, **not** a substitute for the explicit signal.

---

## Skill Author Responsibilities

Every skill that causes the router to enter session mode **must** emit the completion signal when its session concludes.

### Checklist for skill authors

- [ ] Identify all natural exit points of the skill (task complete, user cancels, error path).
- [ ] Emit `[JENGA:SESSION_END:<skill_name>]` on its own line at **every** exit point.
- [ ] Do not emit the signal mid-session (e.g. between interaction turns). It must only appear at the true end.
- [ ] The skill name in the signal must exactly match the skill's registered name.

### Concrete example

The following shows a minimal skill that emits the signal correctly:

```
# Skill: brainstorm

... (skill interaction with user) ...

I've captured all the stories. The backlog is ready for review. 

[JENGA:SESSION_END:brainstorm]
```

The line `[JENGA:SESSION_END:brainstorm]` is the last thing the skill outputs. The watcher strips it; the user only sees the line above it.

---

## Template Note

The skill creation template (`templates/`) should include a stub reminding authors to emit this signal. Updating that template is tracked in task **E12_S02_T03**.

---

## Related Components

| Component | Role |
|-----------|------|
| Jenga Router (`mcp/`) | Maintains `activeSkill` state; exposes `end_session` and `active_session` MCP tools |
| Post-response watcher (`hooks/`) | Scans output, calls `end_session`, strips marker — tracked in **E12_S02_T02** |
| Skill files (`skills/`) | Must emit the signal at session end — tracked in **E12_S02_T03** |

---

## Reference

- Router session tracker: story **E11_S04**
- `end_session` MCP tool: task **E11_S04_T02**
- Post-response watcher implementation: task **E12_S02_T02**
- Skill template update: task **E12_S02_T03**

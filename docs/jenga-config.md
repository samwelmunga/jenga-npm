# Jenga CLI Configuration (`jenga.cli.json`)

This document describes all fields supported in `jenga.cli.json` — the runtime configuration file for the Jenga AI CLI. Copy `jenga.cli.json.example` from the project root to get started.

---

## Fields

### `agentTarget`

**Type:** `string`  
**Default:** `"claude"`  
**Options:** `"claude"` | `"copilot"` | `"custom"` | `"codex"`

The agent backend that Jenga dispatches skill execution to.

| Value | Description |
|-------|-------------|
| `"claude"` | Claude Code (Anthropic) — default |
| `"copilot"` | GitHub Copilot CLI agent |
| `"custom"` | User-defined agent; requires additional config in the skill frontmatter |
| `"codex"` | Codex CLI agent |

`agentTarget` also accepts an array of these values (e.g. `["claude", "codex"]`) for multi-target installs.

---

### Generated Agent Context Files (`CLAUDE.md` / `AGENTS.md`)

`/init` always generates both `CLAUDE.md` and `AGENTS.md` at the project root — this is **unconditional** and does not depend on `agentTarget`. Every agent gets a real, populated root-level context file regardless of which target(s) the project is configured for; there is no `AGENT.md` (singular) file.

Both files are rendered from a single shared template (`templates/agent-context.md.tpl`) so they cannot drift apart the way two hand-maintained copies would. The generated content lives inside a managed block:

```
<!-- JENGA:START -->
...
<!-- JENGA:END -->
```

On repeat `/init` runs, only the content inside this block is replaced — anything a user added outside it is preserved, and the block itself is idempotent (no duplication).

**Collision rule (`J-<NAME>.md`):** If `CLAUDE.md` or `AGENTS.md` already exists at the project root **and** it isn't a file Jenga itself previously generated (i.e. it has no `JENGA:START` marker), Jenga treats this as a genuine pre-existing user file:

- Jenga's own copy is written instead as `J-CLAUDE.md` / `J-AGENTS.md`.
- A short, clearly-marked reference block is inserted near the top of the user's existing file, pointing at the `J-<NAME>.md` copy. The user's file is otherwise left untouched.
- On subsequent runs, the `J-<NAME>.md` file (and its reference in the original file) are updated in place — a collision is never re-derived twice, so a `J-J-CLAUDE.md` can never occur.

If no collision exists, `CLAUDE.md`/`AGENTS.md` are written directly at the project root.

---

### `skillsPath`

**Type:** `string`  
**Default:** `"skills/"`

Path to the skills directory, relative to the project root. Jenga scans this directory for `.md` files containing skill frontmatter.

```json
{ "skillsPath": "skills/" }
```

---

### `matchThreshold`

**Type:** `number` (0–1)  
**Default:** `0.75`

The minimum confidence score required for Jenga to invoke a skill automatically. If no skill scores above this threshold, the input is passed through to the agent without skill augmentation.

- `1.0` — only invoke on exact keyword matches
- `0.75` — recommended balance (default)
- `0.0` — always invoke the best-matching skill

```json
{ "matchThreshold": 0.75 }
```

---

### `sessionTimeout`

**Type:** `number` (milliseconds)  
**Default:** `300000` (5 minutes)

Milliseconds of inactivity before an active skill session auto-expires. Once expired, the next user message starts a fresh session context.

| Value | Duration |
|-------|----------|
| `60000` | 1 minute |
| `300000` | 5 minutes (default) |
| `600000` | 10 minutes |

```json
{ "sessionTimeout": 300000 }
```

---

## Example

```json
{
  "agentTarget": "claude",
  "skillsPath": "skills/",
  "matchThreshold": 0.75,
  "sessionTimeout": 300000
}
```

See `jenga.cli.json.example` at the project root for a ready-to-copy template.

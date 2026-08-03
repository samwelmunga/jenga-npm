# Jenga CLI Configuration (`jenga.cli.json`)

This document describes all fields supported in `jenga.cli.json` — the runtime configuration file for the JengaAgent CLI. Copy `jenga.cli.json.example` from the project root to get started.

---

## Fields

### `agentTarget`

**Type:** `string`  
**Default:** `"claude"`  
**Options:** `"claude"` | `"copilot"` | `"custom"`

The agent backend that Jenga dispatches skill execution to.

| Value | Description |
|-------|-------------|
| `"claude"` | Claude Code (Anthropic) — default |
| `"copilot"` | GitHub Copilot CLI agent |
| `"custom"` | User-defined agent; requires additional config in the skill frontmatter |

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

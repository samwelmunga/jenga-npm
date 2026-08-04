# GitHub Copilot Instructions

This file configures GitHub Copilot's behavior for this project. The block between the Jenga markers is managed automatically by `jenga init` — do not edit it manually.

<!-- JENGA:START -->
## Jenga Agent Framework

This project uses **Jenga** — a skill-based AI agent framework. Jenga organises project work into Epics, Stories, and Tasks managed on a scrum board. It routes user messages to specialised **skills** that execute defined workflows.

### How Jenga Works

- Each **skill** is a self-contained instruction set stored under `.agents/skills/<skill-name>/` (the non-Claude discovery path; Claude Code reads the same content from `.claude/skills/`).
- Skills are invoked by typing `/skill-name` in the chat prompt.
- The active project directory is available via the `JENGA_PROJECT_DIR` environment variable. **Use `JENGA_PROJECT_DIR` — not `CLAUDE_PROJECT_DIR` or any other agent-specific variable** — as the canonical path to the project folder.

### Skill Routing

When a user's message matches a known skill keyword or intent, invoke the skill immediately using the slash-command syntax:

```
/skill-name
```

Do **not** answer skill-related requests with free-form prose if a matching skill exists — delegate to the skill instead.

For free-form questions (architecture, code review, debugging, general Q&A) that do not match a skill, answer directly using your full capabilities.

#### Routing decision table

| Situation | Action |
|-----------|--------|
| Message matches a skill keyword or intent | Invoke `/skill-name` |
| Message is a general coding or project question | Answer directly |
| Ambiguous — could be skill or free-form | Prefer the skill; mention it is being invoked |

### Available Skills

{{SKILL_LIST}}

### Session End

GitHub Copilot CLI does not fire a native session-end hook. To replicate the cleanup logic that Claude Code triggers via its `SessionEnd` hook, run the following script at the end of any Copilot session or after completing a significant skill (e.g. `commit`, `lgtm`):

```bash
bash "$(node -p "path.dirname(require.resolve('jenga-agent/package.json'))")/hooks/copilot_session_end.sh"
```

The `hooks/`, `lib/`, `scripts/`, `templates/`, and `mcp/` directories all live inside the installed `jenga-agent` package (`node_modules/jenga-agent/…`) — they are **not** copied into the project. The script above sources `lib/resolve-project-dir.sh` and delegates to `hooks/on_session_end.sh` (both from the same package), which handle queue routing, rapport detection, handoff file processing, and todo cleanup. See [`docs/hook-parity.md`](docs/hook-parity.md) for the full Claude Code ↔ Copilot hook parity reference.

### Notes

- Always resolve file paths relative to `JENGA_PROJECT_DIR`.
- When a skill asks you to read a file such as `SKILL.md` or a task file, look for it inside `JENGA_PROJECT_DIR/.agents/skills/` or `JENGA_PROJECT_DIR/project/board/` respectively.
- Commit messages and branch names follow the EST naming convention (`E<n>_S<n>_T<n>`).
<!-- JENGA:END -->

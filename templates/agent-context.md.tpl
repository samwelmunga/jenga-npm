# {{TARGET_FILENAME}}

This file gives AI coding agents context on this project. The block between the Jenga markers is managed automatically by `jenga init` — do not edit it manually.

<!-- JENGA:START -->
## Jenga Agent Framework

This project uses **Jenga** — a skill-based AI agent framework. Jenga organises project work into Epics, Stories, and Tasks managed on a scrum board. It routes user messages to specialised **skills** that execute defined workflows.

### How Jenga Works

- Each **skill** is a self-contained instruction set stored under `{{SKILL_DISCOVERY_PATH}}<skill-name>/`.
- Skills are invoked by typing `/skill-name` in the chat prompt.
- The active project directory is available via the `JENGA_PROJECT_DIR` environment variable. **Use `JENGA_PROJECT_DIR` — not `CLAUDE_PROJECT_DIR` or any other agent-specific variable** — as the canonical path to the project folder.

### Skill Routing

If you are Claude Code, `/skill-name` is a native harness-level mechanism: the harness itself
intercepts the literal command and loads the skill for you, independent of anything written here. If
you are any other agent (Codex, or a generic `AGENTS.md` consumer) with no equivalent native
interception, you depend entirely on the instructions below to know what "invoking a skill" concretely
means. Do not improvise a plausible-sounding response instead of following these steps — that is the
exact failure this section exists to prevent.

When the user's message is or matches `/skill-name` (or otherwise clearly matches a known skill's
keyword or intent):

1. Locate the target file at `{{SKILL_DISCOVERY_PATH}}<skill-name>/SKILL.md` (the discovery path from
   "How Jenga Works" above).
2. Open and read that file **in full** before doing anything else.
3. Execute its instructions exactly as written, for the rest of this turn — including running any
   shell scripts or commands it references (e.g. via a terminal/shell tool).
4. Do not substitute your own judgment about what "running the skill" should look like, and do not
   answer with free-form prose describing what the skill would do — the `SKILL.md` file's contents
   are the authoritative procedure, not a summary or a suggestion.

For free-form questions (architecture, code review, debugging, general Q&A) that do not match a skill,
answer directly using your full capabilities.

#### Routing decision table

| Situation | Action |
|-----------|--------|
| Message matches a skill keyword or intent | Open `{{SKILL_DISCOVERY_PATH}}<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message is a general coding or project question | Answer directly |
| Ambiguous — could be skill or free-form | Prefer the skill; open and execute its `SKILL.md` rather than describing it |

### Available Skills

{{SKILL_LIST}}

### Notes

- Always resolve file paths relative to `JENGA_PROJECT_DIR`.
- When a skill asks you to read a file such as `SKILL.md` or a task file, look for it inside `JENGA_PROJECT_DIR/{{SKILL_DISCOVERY_PATH}}` or `JENGA_PROJECT_DIR/project/board/` respectively.
- Commit messages and branch names follow the EST naming convention (`E<n>_S<n>_T<n>`).
- Agent definitions (scrum-master, developer, tester, and any others) live in the `agents/` directory that sits alongside the skills directory shown above, at the same discovery root.
<!-- JENGA:END -->

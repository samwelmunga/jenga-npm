# GitHub Copilot Instructions

This file configures GitHub Copilot's behavior for this project. The block between the Jenga markers is managed automatically by `jenga init` — do not edit it manually.

<!-- JENGA:START -->
## Jenga Agent Framework

This project uses **Jenga** — a skill-based AI agent framework. Jenga organises project work into Epics, Stories, and Tasks managed on a scrum board. It routes user messages to specialised **skills** that execute defined workflows.

### How Jenga Works

- Each **skill** is a self-contained instruction set stored under `.agents/skills/<skill-name>/` (the non-Claude discovery path; Claude Code reads the same content from `.claude/skills/`).
- Skills are invoked by typing `j:skill-name` in the chat prompt (e.g. `j:status`, `j:commit`). The
  older bare `/skill-name` form (e.g. `/status`, `/commit`) is a **permanent alias** — it keeps
  resolving indefinitely, with no deprecation warning and no removal planned — so treat a message in
  either form as the exact same invocation.
- The active project directory is available via the `JENGA_PROJECT_DIR` environment variable. **Use `JENGA_PROJECT_DIR` — not `CLAUDE_PROJECT_DIR` or any other agent-specific variable** — as the canonical path to the project folder.

### Skill Routing

Unlike Claude Code, GitHub Copilot has **no native slash-command interception** — typing `j:skill-name`
(or the older bare `/skill-name` alias) does not automatically load or run anything on its own. Copilot
depends entirely on the instructions below to know what "invoking a skill" concretely means. Do not
improvise a plausible-sounding response instead of following these steps — that is the exact failure
this section exists to prevent.

**Old bare-form alias.** `j:skill-name` is the canonical invocation form. A message using the older
bare `/skill-name` form is not deprecated and must not be treated as an error, a warning case, or a
migration prompt — route it to the identical skill as its `j:skill-name` equivalent. Both forms remain
equally valid indefinitely.

When the user's message is or matches `j:skill-name`, or matches the older bare `/skill-name` alias (or
otherwise clearly matches a known skill's keyword or intent):

1. Locate the target file at `.agents/skills/<skill-name>/SKILL.md` (the discovery path from "How
   Jenga Works" above).
2. Open and read that file **in full** before doing anything else.
3. Execute its instructions exactly as written, for the rest of this turn — including running any
   shell scripts or commands it references (e.g. via a terminal/shell tool).
4. Do not substitute your own judgment about what "running the skill" should look like, and do not
   answer with free-form prose describing what the skill would do — the `SKILL.md` file's contents
   are the authoritative procedure, not a summary or a suggestion.

For free-form questions (architecture, code review, debugging, general Q&A) that do not match a skill,
answer directly using your full capabilities.

#### Routing decision table

Before acting on any row below that opens a `SKILL.md` file, first check the identifier against
the trusted allow-list: {{ALLOWED_SKILL_IDS}}. Since Copilot/Codex has no native interception for
`j:skill-name`, this prose-level check is the entire enforcement mechanism — there is no runtime
guard behind it.

| Situation | Action |
|-----------|--------|
| Message matches `j:skill-name` and `skill-name` is in the allow-list | Open `.agents/skills/<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message matches the older bare `/skill-name` alias and `skill-name` is in the allow-list | Treat identically to `j:skill-name` — same skill, same file, no warning, no migration prompt |
| Message matches a skill keyword or intent and the matched skill is in the allow-list | Open `.agents/skills/<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message matches `j:skill-name` or `/skill-name`, but `skill-name` is **not** in the allow-list | Do not open or execute anything — tell the user the identifier is unrecognized and is not a known Jenga skill |
| Message is a general coding or project question | Answer directly |
| Ambiguous — could be skill or free-form | Prefer the skill; open and execute its `SKILL.md` rather than describing it |

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

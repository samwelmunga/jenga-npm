# {{TARGET_FILENAME}}

This file gives AI coding agents context on this project. The block between the Jenga markers is managed automatically by `jenga init` — do not edit it manually.

<!-- JENGA:START -->
## Jenga Agent Framework

This project uses **Jenga** — a skill-based AI agent framework. Jenga organises project work into Epics, Stories, and Tasks managed on a scrum board. It routes user messages to specialised **skills** that execute defined workflows.

### How Jenga Works

- Each **skill** is a self-contained instruction set stored under `{{SKILL_DISCOVERY_PATH}}<skill-name>/`.
- Skills are invoked by typing `j:skill-name` in the chat prompt (e.g. `j:status`, `j:commit`). The
  older bare `/skill-name` form (e.g. `/status`, `/commit`) is a **permanent alias** — it keeps
  resolving indefinitely, with no deprecation warning and no removal planned — so treat a message in
  either form as the exact same invocation.
- The active project directory is available via the `JENGA_PROJECT_DIR` environment variable. **Use `JENGA_PROJECT_DIR` — not `CLAUDE_PROJECT_DIR` or any other agent-specific variable** — as the canonical path to the project folder.

### Skill Routing

If you are Claude Code, both `j:skill-name` (the canonical form) and the older bare `/skill-name`
(a permanent alias) are native harness-level mechanisms: the harness itself intercepts the literal
command and loads the skill for you, independent of anything written here. If you are any other agent
(Codex, or a generic `AGENTS.md` consumer) with no equivalent native interception, you depend entirely
on the instructions below to know what "invoking a skill" concretely means — for either the
`j:skill-name` form or the older bare `/skill-name` form, both of which route to the same skill. Do not
improvise a plausible-sounding response instead of following these steps — that is the exact failure
this section exists to prevent.

**Old bare-form alias.** `j:skill-name` is the canonical invocation form. A message using the older
bare `/skill-name` form is not deprecated and must not be treated as an error, a warning case, or a
migration prompt — route it to the identical skill as its `j:skill-name` equivalent. Both forms remain
equally valid indefinitely.

When the user's message is or matches `j:skill-name`, or matches the older bare `/skill-name` alias (or
otherwise clearly matches a known skill's keyword or intent):

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
| Message matches `j:skill-name` | Open `{{SKILL_DISCOVERY_PATH}}<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message matches the older bare `/skill-name` alias | Treat identically to `j:skill-name` — same skill, same file, no warning, no migration prompt |
| Message matches a skill keyword or intent | Open `{{SKILL_DISCOVERY_PATH}}<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message is a general coding or project question | Answer directly |
| Ambiguous — could be skill or free-form | Prefer the skill; open and execute its `SKILL.md` rather than describing it |

### Skill Identifier Allow-List

The trusted `j:`-prefixed skill identifiers for this project are: {{ALLOWED_SKILL_IDS}}

Before treating a `j:<name>` invocation (or its bare `/<name>` alias) as a genuine Jenga skill,
confirm `<name>` appears in this list. This applies whether the harness intercepted the command
natively (Claude Code) or you are matching it yourself against a skill keyword or intent (any
other agent). If `<name>` does **not** appear in this list, do not guess at intent and do not
execute anything — tell the user the identifier is unrecognized and is not a known Jenga skill,
rather than treating it as one anyway.

### Available Skills

{{SKILL_LIST}}

### Notes

- Always resolve file paths relative to `JENGA_PROJECT_DIR`.
- When a skill asks you to read a file such as `SKILL.md` or a task file, look for it inside `JENGA_PROJECT_DIR/{{SKILL_DISCOVERY_PATH}}` or `JENGA_PROJECT_DIR/project/board/` respectively.
- Commit messages and branch names follow the EST naming convention (`E<n>_S<n>_T<n>`).
- Agent definitions (scrum-master, developer, tester, and any others) live in the `agents/` directory that sits alongside the skills directory shown above, at the same discovery root.
<!-- JENGA:END -->

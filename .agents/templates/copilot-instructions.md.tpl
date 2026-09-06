# GitHub Copilot Instructions

This file configures GitHub Copilot's behavior for this project. The block between the Jenga markers is managed automatically by `jenga init` — do not edit it manually.

<!-- JENGA:START -->
## Jenga Agent Framework

This project uses **Jenga** — a skill-based AI agent framework. Jenga organises project work into Epics, Stories, and Tasks managed on a scrum board. It routes user messages to specialised **skills** that execute defined workflows.

### How Jenga Works

- Each **skill** is a self-contained instruction set: a `SKILL.md` file inside a per-skill directory.
  Copilot discovers project skills from **all three** of `.github/skills/`, `.agents/skills/`, and
  `.claude/skills/`. Jenga installs its skills under `.agents/skills/<skill-name>/` and mirrors
  byte-identical content into `.claude/skills/<skill-name>/`; when the same skill name is found in
  more than one of those directories, `.agents/skills/` takes precedence. Cite and open
  `.agents/skills/` as the canonical path.
- A skill's **identity is its frontmatter `name:` field, not its directory name**. Jenga names every
  skill `j.<skill-name>` — the skill in `.agents/skills/status/` declares `name: j.status`.
- Skills are invoked by typing `j.skill-name` in the chat prompt (e.g. `j.status`, `j.commit`). The
  older bare `/skill-name` form (e.g. `/status`, `/commit`) is a **permanent alias** — it keeps
  resolving indefinitely, with no deprecation warning and no removal planned — so treat a message in
  either form as the exact same invocation.
- The active project directory is available via the `JENGA_PROJECT_DIR` environment variable. **Use `JENGA_PROJECT_DIR` — not `CLAUDE_PROJECT_DIR` or any other agent-specific variable** — as the canonical path to the project folder.

### Skill Routing

**Copilot loads these skills natively.** Copilot has a real, validating skill loader. It reads every
`SKILL.md` under the discovery paths above and validates each one's frontmatter `name:` against:

```
Skill name must start with an ASCII letter or number and contain only
ASCII letters (a-z, A-Z), numbers, hyphens, underscores, dots, and spaces
```

A skill whose name fails that rule **does not load at all** — it is reported under "failed to load"
by `copilot skill list` and is simply absent from the session. Every skill that does load is
registered as a **native slash command named after its frontmatter `name`**, matched
case-insensitively: `j.status` is invocable as `/j.status` and appears in the slash-command picker.
That native path loads and applies the skill on its own — you do not need to locate or open the file
yourself when the user types it.

**What still depends on these instructions.** Native registration covers only the exact
`/j.skill-name` form. These forms have **no** native handler and are routed entirely by the steps
below:

- the no-slash `j.skill-name` form, which is Jenga's documented invocation style;
- the older bare `/skill-name` alias (`/status`, `/commit`);
- a message that matches a skill by keyword or intent rather than by a literal command.

For those, do not improvise a plausible-sounding response instead of following these steps — that is
the exact failure this section exists to prevent.

**Old bare-form alias.** `j.skill-name` is the canonical invocation form. A message using the older
bare `/skill-name` form is not deprecated and must not be treated as an error, a warning case, or a
migration prompt — route it to the identical skill as its `j.skill-name` equivalent. Both forms remain
equally valid indefinitely.

When the user's message is or matches `j.skill-name`, or matches the older bare `/skill-name` alias (or
otherwise clearly matches a known skill's keyword or intent):

1. Locate the target file at `.agents/skills/<skill-name>/SKILL.md` (the discovery path from "How
   Jenga Works" above; `.claude/skills/<skill-name>/SKILL.md` holds identical content if the first
   is absent). Note the directory is the **unprefixed** name — `j.status` lives in `status/`.
2. Open and read that file **in full** before doing anything else.
3. Execute its instructions exactly as written, for the rest of this turn — including running any
   shell scripts or commands it references (e.g. via a terminal/shell tool).
4. Do not substitute your own judgment about what "running the skill" should look like, and do not
   answer with free-form prose describing what the skill would do — the `SKILL.md` file's contents
   are the authoritative procedure, not a summary or a suggestion.

For free-form questions (architecture, code review, debugging, general Q&A) that do not match a skill,
answer directly using your full capabilities.

#### Routing decision table

Before acting on any row below that opens a `SKILL.md` file yourself, check the identifier against
the trusted allow-list: {{ALLOWED_SKILL_IDS}}.

There are two enforcement layers, and they cover different inputs:

1. **Copilot's own loader** handles the native `/j.skill-name` form. It only ever registers a skill
   that is actually present under a discovery path and passed name validation.
2. **This prose allow-list check** is the second layer — and the *only* layer for the forms Copilot
   does not natively intercept: the no-slash `j.skill-name` form, the bare `/skill-name` alias, and
   keyword or intent matches. Apply it whenever you are about to open a `SKILL.md` yourself.

Neither layer inspects a skill's *contents*; both defend the invocation-matching layer only.

| Situation | Action |
|-----------|--------|
| User types the native `/j.skill-name` slash command | Copilot's loader applies the skill; follow the loaded instructions as written |
| Message matches `j.skill-name` (no slash) and `skill-name` is in the allow-list | Open `.agents/skills/<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message matches the older bare `/skill-name` alias and `skill-name` is in the allow-list | Treat identically to `j.skill-name` — same skill, same file, no warning, no migration prompt |
| Message matches a skill keyword or intent and the matched skill is in the allow-list | Open `.agents/skills/<skill-name>/SKILL.md`, read it fully, execute it as written |
| Message matches `j.skill-name` or `/skill-name`, but `skill-name` is **not** in the allow-list | Do not open or execute anything — tell the user the identifier is unrecognized and is not a known Jenga skill |
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
- When a skill asks you to read a file such as `SKILL.md` or a task file, look for it inside `JENGA_PROJECT_DIR/.agents/skills/` (or `JENGA_PROJECT_DIR/.claude/skills/`, which mirrors it) or `JENGA_PROJECT_DIR/project/board/` respectively.
- If a Jenga skill seems to be missing entirely, run `copilot skill list` and check the "failed to load" section before assuming it does not exist — a name that fails validation is absent rather than broken.
- Commit messages and branch names follow the EST naming convention (`E<n>_S<n>_T<n>`).
<!-- JENGA:END -->

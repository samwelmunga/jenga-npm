# Workflow Rules

> ⚠️ **CRITICAL — Source of Truth for All Features**
>
> All features — **skills, agents, hooks, scripts, and any other implementation** — **MUST be created and edited in the root directories** (`skills/`, `agents/`, `hooks/`, `scripts/`, etc.).
>
> The **`.agents/`** and **`.claude/`** directories are **generated build outputs**. They are populated automatically by the `j:distribute` skill and must **never** be used as the primary location for new or updated features. Any change made only inside `.agents/` or `.claude/` will be overwritten on the next distribution run.
>
> **Rule:** If you add or modify a skill, agent, hook, or script, the canonical file lives in the root directory. `.agents/` and `.claude/` are read-only artifacts.

---

## Workflow Lifecycle

> **Invocation convention (`E50_S01`):** every skill's canonical invocation form is now `j:<name>`
> (e.g. `j:init`, `j:jenga`) rather than the old bare `/<name>`. The old bare `/<name>` form is a
> **permanent alias** — it keeps resolving indefinitely on every routing surface, is never
> deprecated, and is never scheduled for removal. Full rationale in
> `docs/skill-authoring.md`'s "Invocation Convention" section.

1. **`j:init`** — Scaffold the project: git init, directories, `workflow.json`, `PROJECT_SUMMARY.md` stub.
2. **`j:jenga`** — Interactive-by-default board orchestrator: bare shows a picker + confirmation tree, `<ids>` scopes and confirms, `*` runs the original fully automated pipeline with no prompts.
3. **`j:todo`** (or Scrum Master directly) — Translate requirements into board items (epics → stories → tasks).
4. **`j:do`** — Pick a task from `project/todo.md`, invoke the Developer agent with full scrum board context and a sender object.
5. **Developer** — Reads task, creates a worktree, implements, commits, and calls the Tester.
6. **Tester** — Validates sender object, runs tests, writes status to the board, triggers rollup if all tasks pass.
7. **`SessionEnd` hook** — `on_session_end.sh` detects new rapports and writes triggers to the queue.
8. **Scrum Master** (next session) — Processes the queue: rapport review, status review, story/epic rollup.

---

## Agents

### Scrum Master (`agents/scrum-master.md`)

- **Owns** `project/PROJECT_SUMMARY.md` — sole writer.
- Processes `project/queue/scrum_triggers.jsonl` at every session start.
- Creates and amends epics, stories, and tasks using the scrum board schema.
- Handles story and epic rollup when all child items pass.
- Applies advisory file locks before writing any board file.

### Developer (`agents/developer.md`)

- Creates an isolated git worktree per task (`<E##_S##_T##-slug>`).
- Logs all incoming sender objects to `project/logs/events.json` before doing any work.
- Commits at meaningful milestones (not every line, not only at the end).
- Calls the Tester with a full sender object including commit SHAs.
- Never runs tests — that is the Tester's exclusive responsibility.
- After three failed conflict resolutions, writes a rapport, sets status to `Blocked`, and halts.
- Never commits `.env` files or credentials.

### Tester (`agents/tester.md`)

- **Sole agent** permitted to update task and story statuses on the board.
- Validates all required sender fields before proceeding (rejects with `"error"` if any are missing).
- Manages the full testing lifecycle: unit, integration, e2e, SAST, vulnerability, performance, coverage.
- Test tool configuration lives in `project/configs/test-config.json` (user-approved).
- SAST/vulnerability scans are opt-in and require explicit user approval, logged to `events.json`.
- Writes `Rejected` status only after notifying the user and receiving confirmation.
- After every status update, checks for story/epic rollup and writes a trigger to the queue if warranted.
- Maintains analytics baselines in `project/data/baselines.json` across sessions.

---

## Skills (Slash Commands)

Skills are stored in `skills/<name>/SKILL.md`. Invoke them with `j:<name>` in a Claude Code session
— the bare `/<name>` form also keeps working permanently as an alias (see the Invocation Convention
note under Workflow Lifecycle above).

> **`j-<name>` directory twins (`E50_S05`):** separately from the `j:<name>` colon convention above,
> every skill — except `init`/`j-init` (already paired, the original precedent set in `E50_S04`) and
> `index` (a non-skill directory) — also has a `skills/j-<name>/` directory twin, invocable as
> `/j-<name>`. This is a complementary mechanism, not a replacement: it gives collision safety via a
> real duplicate directory under a distinct name, rather than a routing/frontmatter alias, for cases
> where a host tool ships its own same-named built-in command (e.g. GitHub Copilot's own `/init`,
> which motivated `j-init` in the first place) and would otherwise shadow the bare `/<name>` form.
> Twins are generated and kept in lockstep exclusively via `scripts/generate-j-alias.sh` — never
> hand-edit a `skills/j-<name>/` directory directly. Full rationale in `docs/skill-authoring.md`'s
> "Invocation Convention" section.

| Command | Description |
|---|---|
| `j:init` | Scaffold project directories, `workflow.json`, `PROJECT_SUMMARY.md`, initial commit. |
| `j:jenga` | Interactive-by-default board orchestrator with a fully automated escape hatch: bare `j:jenga` renders a picker + confirmation tree, `j:jenga <ids>` resolves an explicit scope + confirms, `j:jenga *` reproduces the original zero-prompt, fully automated run. |
| `j:jbp` | Scaffold the project using the [JengaBasePlate](https://github.com/samwelmunga/JengaBasePlate.git) boilerplate. |
| `j:brainstorm` | Focused planning session with the Scrum Master to define and refine features before committing to the board. |
| `j:btw` | Capture a mid-flow mission, classify into epic/story structure, implement now or defer. |
| `j:todo` | Add missions to `project/todo.md` linked to epics and stories. Loops until done, then optionally runs `j:do`. |
| `j:redo` | Rework a previous implementation by commit SHA or Epic/Story number. Includes scope assessment, plan, and doc updates. |
| `j:publish` | Configure, validate, and orchestrate scaffolded release workflows (`setup`, `deploy`, `stage`, `history`, `release-notes`) across `mobile-ios`, `npm`, `npm-ci`, and `droplet` targets. `stage` (`npm`/`npm-ci` only) rehearses and smoke-tests a release before it goes live. |
| `j:uncharted` | Entry point for code with no board provenance — three modes: `segment` (a file or directory), `import` (an external source), `onboard` (a whole pre-existing codebase). |
| `j:do` | Execute tasks from the scrum board. Resolves each entry to full board context and drives the Developer agent. |
| `j:status` | Overview of epics, stories, and tasks with statuses, open rapports, and queue depth. |
| `j:jenga-permission-level` | Report or switch the current session's 5-tier permission level (Locked/Guarded/Standard/Elevated/Unrestricted) without hand-editing settings.json. |
| `j:commit` | Commit completed work using the EST naming convention (`epic(...)`, `story(...)`). |
| `j:lgtm` | Approve current work, commit, and continue. Chains `j:commit` + `j:continue`. |
| `j:dev-done` | Commit current work and sync the `.claude/`/`.agents/` mirrors. Chains `j:commit` + `j:self-sync`. |
| `j:continue` | Pick up the next incomplete item across `PROJECT_SUMMARY.md`, epics, and stories. |
| `j:proceed` | Resume execution from where it left off. |
| `j:error` | Guided troubleshooting — gathers context about an error and investigates a fix. |
| `j:help` | List all available skills with descriptions. |

---

## Skill Frontmatter

Each `SKILL.md` starts with a YAML frontmatter block. Supported fields:

```yaml
---
name: <skill-name>
description: <one-sentence description>
metadata:
  prefered_agent: <agent_name>   # optional
keywords:                        # optional
  - "<short phrase>"
examples:                        # optional
  - "<natural-language prompt>"
---
```

| Field | Required | Purpose |
|---|---|---|
| `name` | ✅ | Skill name — `j:` + the directory name under `skills/` (see `docs/skill-authoring.md`'s "Invocation Convention"). |
| `description` | ✅ | Shown in `j:help` listings and the skill registry. |
| `metadata.prefered_agent` | ❌ | Sub-agent to delegate to (`scrum-master`, `developer`, `tester`). |
| `keywords` | ❌ | Short phrases (1–3 words) for Jenga Router keyword matching. |
| `examples` | ❌ | Natural-language prompts for Jenga Router semantic matching. |

See `docs/skill-authoring.md` for the full authoring guide.

### `prefered_agent`

When a `SKILL.md` file contains a `prefered_agent` property in its YAML frontmatter, it indicates which sub-agent should be used to **execute** the skill. When invoking the skill, delegate execution to that agent by loading its definition from `agents/<agent_name>.md` and passing it the skill's instructions along with all relevant context.

Valid values match the agent definitions in the `agents/` directory: `scrum-master`, `developer`, `tester`.

Skills without this property are executed directly without delegating to a sub-agent.

---

## Skill Implementation Principle — Scripts Over Inline Logic

When implementing or authoring a skill, **offload deterministic, repeatable steps to shell scripts or other static tooling** (e.g., bash scripts in `skills/<name>/scripts/`, shared scripts in `scripts/`) rather than encoding them as agent instructions inside `SKILL.md`.

**Why:**
- Scripts execute consistently regardless of model, context length, or session state
- Moving logic out of `SKILL.md` reduces token consumption on every invocation
- Scripts are version-controlled, testable, and reusable across skills

**Apply this principle when a step:**
- Runs a fixed sequence of shell commands (git operations, file manipulation, validation)
- Produces structured output that the agent then reads and acts on
- Would be identical across every invocation (no dynamic reasoning required)

**Keep in `SKILL.md` what requires agent judgment:** interpreting output, making decisions based on context, presenting results to the user, and handling edge cases that cannot be enumerated in advance.

---

## Interaction Pattern

When presenting options to the user, ALWAYS use this format instead of open-ended questions if possible:

    What would you like to do?
    1. Option A
    2. Option B  
    3. Option C
    4. Other (describe below)

Avoid ask open-ended questions where a list of options would serve better.
Free-text input must always appear as the final numbered option.

---

## MCP Tools

### `mcp/help`

Discovers available skills by scanning `.agents/skills/`. `help(path?)` returns skill folder names.

```bash
cd mcp/help && npm install
node index.js
```

### `mcp/execute-ticket`

Planned: creates a sub-agent, initialises a git worktree, and names the session after the task ID. See `mcp/execute-ticket/index.js`.

---

## Hooks

Hooks are configured in `settings.json` and fire automatically during a Claude Code session.

| Hook | Trigger | Action |
|---|---|---|
| `WorktreeCreate` | Developer creates a worktree | Runs `git worktree add` and echoes the worktree path. |
| `WorktreeRemove` | Developer removes a worktree | Runs `git worktree remove --force` on the given path. |
| `SessionEnd` | Any session ends | Runs `hooks/on_session_end.sh` asynchronously. |

### `hooks/on_session_end.sh`

Runs at the end of every Developer or Tester session: logs a session-end event to `events.json`, compares `rapports/problems/` against `.rapport_manifest.json` (skipping `*.IGNORE.md` files) and writes a `rapport_review` trigger if new rapports are found, then always appends a `status_review` trigger for the next Scrum Master session.

---

## Subject Divergence Detection

### What Counts as Divergence
A subject has diverged when the user introduces any of the following mid-session:
- A **new feature request** unrelated to the task or story currently in focus
- An **unrelated suggestion** (tooling change, refactor, workflow idea) that would require separate planning
- A **scope-expanding idea** that goes beyond the current story's Acceptance Criteria or Definition of Done

Clarifying questions, follow-up details, or edge cases that directly serve the current topic are **not** divergence.

### Detection & Prompt
When divergence is detected, immediately pause the current line of work and present the following structured choice:

    It looks like we're moving into a new topic. How would you like to handle it?
    1. Capture the **new topic** as a `j:todo` (I'll return to what we were doing)
    2. Capture the **current topic** as a `j:todo` (I'll continue with the new topic)
    3. Capture **both** as `j:todo` items (you choose which to continue first)
    4. Ignore it — tell me which topic to continue with

### Option A — Capture the Diverging Topic
1. Summarise the diverging topic using context gathered so far and create a `j:todo` with that summary as the description.
2. Offer `j:brainstorm` to fill in any missing Prerequisites before finalising the `j:todo`.
3. Once the `j:todo` is saved, return to the primary topic exactly where it was paused.

### Option B — Capture the Primary Topic
1. Summarise the primary topic using context gathered so far and create a `j:todo` with that summary as the description.
2. Offer `j:brainstorm` to fill in any missing Prerequisites before finalising the `j:todo`.
3. Once the `j:todo` is saved, continue with the diverging topic.

### Option C — Capture Both
1. Create a `j:todo` for the diverging topic (with context summary and a `j:brainstorm` offer for Prerequisites).
2. Create a `j:todo` for the primary topic (with context summary and a `j:brainstorm` offer for Prerequisites).
3. Ask the user which topic to continue first.

### Context Surfacing
In every `j:todo` description created through this flow, include:
- A one-sentence summary of the topic
- Key details, constraints, or decisions already discussed
- Any open questions or unknowns raised so far

This ensures no context is lost regardless of which option the user chooses.

### Edge Cases
- **User declines both options (selects "Ignore it")**: Acknowledge the choice without creating any `j:todo` items, then ask the user to explicitly state which topic to continue. Follow their direction.
- **User wants to pursue both in parallel**: Treat this as Option C — capture both as `j:todo` items with full context summaries, then ask the user which to continue first.

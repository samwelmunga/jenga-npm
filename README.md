# Jenga AI
### The AI-driven development framework for large, long-lived codebases.

Jenga AI is an agentic software engineering framework for AI-driven development at scale — on new projects and on large existing applications alike. It targets the case AI coding tools handle worst: a codebase far too big to fit in one context window, spread across many modules and often more than one repository, worked on over weeks rather than a single session.

It splits work across three role-bounded agents — a Scrum Master that plans, a Developer that implements in an isolated git worktree, and a Tester that runs your test suite and owns the board status. Work survives session boundaries as Epics, Stories, and Tasks on a Markdown board your agent reads at the start of every session, so understanding of a large system accumulates instead of resetting. Existing code with no board history is onboarded explicitly, through investigation rather than guesswork (`j.uncharted`), and the same workflow propagates across every repository you run it in (`j.distribute`).

[![npm version](https://img.shields.io/npm/v/@jenga-ai/agent.svg)](https://www.npmjs.com/package/@jenga-ai/agent)
[![license](https://img.shields.io/npm/l/@jenga-ai/agent.svg)](LICENSE)

```sh
npm install @jenga-ai/agent
```

## The Problem It Solves

You've had this happen: Claude wrote the feature, said it worked, and the session ended. Next session it had no idea any of it existed. Without a framework like Jenga AI, AI-assisted development has serious structural weaknesses:

[![How AI Coding Agents Understand Your Codebase & Developer Tools](https://img.youtube.com/vi/zAe-sau06io/maxresdefault.jpg)](https://www.youtube.com/watch?v=zAe-sau06io)

*"How AI Coding Agents Understand Your Codebase & Developer Tools" — IBM Technology on the same gap in persistent development context and tooling context that Jenga AI's board and agent contracts are built to close.*

| Problem | Reality |
|---|---|
| **No persistent engineering context** | Every AI agent session starts from scratch — no awareness of open tasks, past decisions, or what was already tested |
| **No role separation** | The AI writes *and* "tests" code in the same context, leading to hallucinated test results and self-affirming bugs |
| **No structured planning** | Work happens ad-hoc — no Epic → Story → Task hierarchy to organise or track progress |
| **No handoff protocol** | Switching from implementing to testing means manually re-explaining context every time |
| **No audit trail** | You can't replay *why* something was built, by which agent, based on which task |
| **Sessions just end** | Work-in-progress, unresolved problems, and incomplete stories silently vanish |

Jenga AI solves each of these with structure: persistent engineering context maintained via board state, strict agent roles, typed inter-agent contracts, and session-end hooks that carry that context between sessions.

### Documentation

Start here, then go deeper as you need it:

| Guide | What it covers |
|---|---|
| [Intro Guide](project/.wiki/intro-guide.md) | Start here. The philosophy, how to think about the system, and a first-15-minutes walkthrough for a new project or an existing codebase. Also on the [docs site](https://samwelmunga.github.io/jenga-npm/getting-started.html). |

**How-to guides** — day-to-day working patterns:

| Guide | What it covers |
|---|---|
| [Your First Feature](project/.wiki/concepts/first-feature.md) | Building a feature end-to-end, from idea to verified, committed code. |
| [Starting From an Existing Project](project/.wiki/intro-guide.md#starting-from-an-existing-project) | Onboarding a large codebase that has no board history — investigation first, then planning. |
| [Capturing Mid-Flow Ideas](project/.wiki/concepts/mid-flow-capture.md) | Handling a new thought, tangent, or feature idea without derailing your current work. |
| [Working Across Sessions](project/.wiki/concepts/multi-session-work.md) | Picking up a project after a break — without losing momentum or context. |
| [Parallel Tasks](project/.wiki/concepts/parallel-tasks.md) | Running multiple tasks simultaneously with `j.dooo`, or automating board-wide parallel execution with `j.jenga`. |

**Full reference:**

| Reference | What it covers |
|---|---|
| [Documentation Reference](project/.wiki/documentation.md) | Every skill, every agent, MCP tools, hooks, and the inter-agent communication contract. Also on the [docs site](https://samwelmunga.github.io/jenga-npm/reference.html). |

---

## How Jenga AI's Agentic Workflow Works

```
j.init → j.pi-plan → j.todo → j.do
                              │
                     Developer agent
                     (isolated worktree, commits)
                           │
                     Tester agent
                     (validates, updates board status)
                           │
                     SessionEnd hook
                     (writes triggers to queue)
                           │
                     Scrum Master (next session)
                     (processes queue, rollups, unblocks)
```

| Mechanism | Location | Purpose |
|---|---|---|
| Scrum board | `project/board/` | Epics, stories, tasks with structured frontmatter |
| Trigger queue | `project/queue/scrum_triggers.jsonl` | Async handoff to Scrum Master |
| Event log | `project/logs/events.json` | Append-only audit trail |
| Rapport system | `project/rapports/` | Problem/analysis reports by Developer and Tester |
| File locking | `<file>.lock` adjacent to board files | Concurrency control for parallel agents |

---

> 📖 **Full reference:** [Docs site](https://samwelmunga.github.io/jenga-npm/reference.html) · **Intro Guide:** [Docs site](https://samwelmunga.github.io/jenga-npm/getting-started.html) — mirrored at [project/.wiki/documentation.md](project/.wiki/documentation.md) / [intro-guide.md](project/.wiki/intro-guide.md)

## Platform Support

| Agent | Skills & Agents | Root Context File |
|---|---|---|
| **Claude Code** | `.claude/` — mirrored automatically on install | `CLAUDE.md` — generated by `j.init` today |
| **GitHub Copilot** | `.agents/` — mirrored automatically on install | `.github/copilot-instructions.md` — bootstrapped at `npm install` time, refined by `jenga init` |
| **Codex** | `.agents/` — mirrored automatically on install | `AGENTS.md` — generated by `j.init` today |

`CLAUDE.md` and `AGENTS.md` are generated unconditionally by `j.init` — every agent gets a real, populated root-level context file, not just a pointer. If either file already exists as a genuine pre-existing user file, Jenga leaves it untouched, writes its own copy as `J-CLAUDE.md` / `J-AGENTS.md`, and inserts a short reference line into the original.

`.github/copilot-instructions.md` follows a different path, because Copilot needs it before `j.init` may ever run: `npm install` triggers `scripts/postinstall.js`, which writes it unconditionally and non-interactively, so `j.<name>` (and `/j-<name>`) routing works from a consumer's very first Copilot command. A later `jenga init` run refines that same file using the project's actual chosen skills path.

---

## Agents

| Agent | Role | Owns |
|---|---|---|
| **Scrum Master** | Plans, breaks down work, handles rollups and queue processing | `project/PROJECT_SUMMARY.md`, epic status |
| **Developer** | Implements tasks in isolated git worktrees, commits at milestones | Code, worktrees, commit history |
| **Tester** | Validates implementation, updates task/story status, writes rapports | Task/story status, test config, baselines |

Each agent is defined in `.agents/agents/`. They communicate exclusively through typed **sender objects** — JSON contracts that include the task ID, commit SHAs, and worktree path. Every incoming sender object is logged to `project/logs/events.json` before any work begins.

---

## Getting Started

**Prerequisites:** An AI agent or AI-native IDE. Supported platforms include:
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [GitHub Copilot](https://github.com/features/copilot) (VS Code extension or CLI)
- Codex CLI

**Install from npm:**
```sh
npm install -g @jenga-ai/agent
```

> **pnpm or `--ignore-scripts`?** Jenga's install relies on a `postinstall` lifecycle script to
> mirror `skills/`/`agents/` into your project — if your package manager blocks lifecycle
> scripts by default (pnpm v8+) or you install with `--ignore-scripts`/`ignore-scripts=true`,
> the install will silently produce none of the framework files with no error shown. See
> [`project/documentation/distribution.md`](project/documentation/distribution.md#prerequisite--lifecycle-scripts-must-be-allowed-to-run-e26_s09)
> for the exact npm/pnpm opt-in step.

Or clone directly:

1. **Clone or copy this repo** into your project's root.
2. **Run `j.init`** — scaffolds `project/`, creates `workflow.json`, `PROJECT_SUMMARY.md`, and makes an initial commit.
3. **Run `j.pi-plan`** — define your project goals and initial epics.
4. **Run `j.todo`** — describe features to implement; they're linked to the board automatically.
5. **Run `j.do`** — picks the first task and drives the full implement → test → commit loop.

Run `j.status` at any time to see where the project stands.

📖 **New to Jenga AI?** The [Intro Guide](https://samwelmunga.github.io/jenga-npm/getting-started.html) walks through the philosophy, the three pillars (role separation, board hierarchy, session continuity), and a full first-15-minutes walkthrough for both a new project and an existing codebase — mirrored at [project/.wiki/intro-guide.md](project/.wiki/intro-guide.md).

**CLI commands.** The `jenga` binary installed alongside the package also ships a set of deterministic, agentless commands — see [The `jenga` CLI](#the-jenga-cli).

---

## Supported Platforms

Jenga AI has been tested with:

| Platform | Type |
|---|---|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | AI coding agent |
| [GitHub Copilot](https://github.com/features/copilot) | AI coding assistant |
| Codex CLI | AI coding agent |

The framework is platform-agnostic by design — any AI agent that can read Markdown files and execute slash commands can use it.

---

## Skills (Slash Commands)

Skills live in `.agents/skills/<name>/SKILL.md`. Invoke with `j.<name>` in your AI agent or IDE's command interface, or with its `/j-<name>` directory form (e.g. `/j-init`) — both resolve to the same skill. A handful of the most foundational commands:

> **Why `/j-<name>`, not a bare `/<name>`?** Some host tools ship their own built-in command that can
> shadow one of Jenga's — e.g. GitHub Copilot's own built-in `/init`. Jenga sidesteps this
> structurally: every skill ships under the collision-safe `/j-<name>` directory name, so there's no
> bare `/<name>` directory for a host tool's own command to collide with in the first place.
> `/j-<name>` isn't a fallback to reach for when something misbehaves — it's simply how the skill is
> named. Three permanent exceptions ship bare-only, with no `/j-<name>` form: `/jenga`,
> `/jenga-permission-level`, and `/jenga-config` — deliberately excluded, since none is the kind of
> skill a host tool's own built-in command is likely to name-collide with.

| Command | Description |
|---|---|
| `j.init` | Scaffold project directories, `workflow.json`, `PROJECT_SUMMARY.md`, initial git commit |
| `j.todo` | Add missions to `project/todo.md` linked to epics and stories |
| `j.do` | Execute tasks from the scrum board, drives the Developer agent through the full loop |
| `j.break` | Halt execution after the current task completes and before the next one starts; `hard` persists until cleared, `status` adds a progress rapport for the current run |
| `j.test` | Discover the project's test suites, pick which to run (blank runs all), and get a pass/fail summary; exit code 0 when all passed, 1 otherwise |
| `j.smoke-test` | Smoke-test every skill in the catalog (frontmatter, name versus directory, preferred agent, referenced scripts and assets) and get a pass/fail summary with critical findings called out |
| `j.commit` | Commit finished work with the EST naming convention, after asking whether to run tests first (scoped to the change, the full suite, or skip, with a remembered default) |
| `j.conventions` | Record the project's conventions (commit format, branching, naming, testing, file layout, docs placement) so every agent follows them — detects what the project already does and offers presets |
| `j.check-in` | Report which dispatched agents are actually alive, silent, or finished-but-leaking processes |
| `j.status` | Print a full scrum board overview — epics, stories, tasks, rapports, queue depth |

### `/jenga` — one command, several behaviors

`/jenga` doesn't fit the table above, because what it does depends entirely on how it's invoked:

| Invocation | Behavior |
|---|---|
| `/jenga` (bare) | Renders a picker + confirmation tree before scoping the run |
| `/jenga <ids>` | Resolves an explicit fuzzy-ID scope and confirms it |
| `/jenga *` | Fully automated — decomposes, queues, and executes everything eligible, no prompts |
| `/jenga <free text>` | Natural-language dispatch — matches a single skill directly, or proposes a multi-skill [playbook](#playbooks) when the request spans more than one |

It's one of the three permanent bare-only exceptions noted above — there's no `/j-jenga` form.

> 📖 **Full skill list** (planning, review, committing & maintenance commands): [Docs site](https://samwelmunga.github.io/jenga-npm/skills.html) — mirrored at [project/.wiki/documentation.md#skills](project/.wiki/documentation.md#skills)

---

## Playbooks

Some workflows are always the same sequence of skills — plan it, build it, commit it. A **playbook** is a named, pre-defined chain of skills, run and confirmed as one unit instead of typed out one skill at a time.

Invoke one by describing what you want in plain language to `j.jenga` — it proposes a matching playbook as a numbered, editable list before anything runs — or name one directly:

```
j.playbook idea-to-committed
```

which resolves to:

```
j.brainstorm → j.todo → j.do → j.commit
```

Calling `j.playbook` with no id prints a table of every available playbook (id, name, and steps) instead of resolving one.

Nothing executes until you confirm the chain, and any step can be unchecked first. `understand-then-commit` prepends `j.uncharted` investigation for unfamiliar code before running that same pipeline — useful when the change touches code you don't fully understand yet. No built-in playbook publishes or mirrors on your behalf: build chains terminate at `j.commit`, and publishing stays an explicit, separately invoked act.

When a step forwards its result into the next one, that value has a declared **output type** (a plain string, a list of board IDs, a list of files) so the chain can be validated before it runs. 

See [Getting Started](https://samwelmunga.github.io/jenga-npm/getting-started.html#chaining-workflows-with-playbooks) for more on how playbooks work.

Want your own recurring chain? `j.playbook-new` walks you through authoring one — id, name, description, keywords, examples, and an ordered list of skills — writes it to `project/.playbooks/<id>.json` alongside the built-in ones, and self-validates the result before reporting success.

---

## The `jenga` CLI

Not every step needs a model. The `jenga` binary installed with the package (`jenga --help`) runs the deterministic work as plain code — no agent, no reasoning, **zero token cost**:

| Command | What it does |
|---|---|
| `jenga init` | Setup wizard — creates `jenga.cli.json` and registers the prompt-router hook. |
| `jenga attach` | Write the MCP config for this project so new sessions route through Jenga. |
| `jenga status` | Show router status and the active skill session. |
| `jenga config` | List and edit `project/configs/*.json` — interactively, or `jenga config get\|set <file-id>.<key> [value]`. A successful `set` bumps that file's version counter. |
| `jenga dashboard start\|open` | Start the dashboard API (`--port <n>`, default 3001 or `JENGA_API_PORT`; `--serve-app` also serves the built UI), or health-check it and open it in your browser. |
| `jenga doctor` (alias: `jenga clean`) | Scan `.agents/` and `.claude/` for orphaned package-owned files left behind by an upgrade, preview them, and delete only on confirmation. `--dry-run` previews only. |

Same principle that pushes skill logic into scripts rather than prompts: editing a config key is a fixed sequence with one correct answer. `jenga config set` validates and writes through code, so a settings change can't be left half-applied — which is why it's a command, not a `j.<name>` skill.

> 📖 **Settings reference:** `project/configs/README.md` · **`jenga doctor`'s ownership heuristic:** `project/documentation/distribution.md`

---

## Pre-Flight Checklists

A **pre-flight checklist** is a standing list of checks that must hold before a gated action goes ahead: no `.env` file staged before a commit, a clean working tree before a release. Each item names the lifecycle **phase** it guards — `pre-commit` (`j.commit`), `pre-task` (`j.do`), `pre-release` (`j.publish`, `j.mirror-public`), `pre-reconcile` (`j.reconcile`) — and how strictly it is enforced: `block`, `confirm`, or `advisory`.

Jenga ships a small generic default at `templates/checklists.json`. Authoring your own `project/configs/checklists.json` **replaces it wholesale** — the two are never merged, so copy over any shipped item you want to keep. With no registry, or no item for the active phase, the checker exits `0` silently.

Enforcement doesn't rest on an agent cooperating: a `PreToolUse` hook (`hooks/on_preflight_check.sh`) refuses the active phase's own irreversible command — `git commit` during `pre-commit` — while a `block` item fails, and asks when a `confirm` item fails. Agents can *suggest* items, but a suggestion is only a rapport: nothing reaches your checklist without your confirmation.

> 📖 **Authoring reference:** [Docs site](https://samwelmunga.github.io/jenga-npm/preflight-checklists.html) — mirrored at [project/.wiki/preflight-checklists.md](project/.wiki/preflight-checklists.md)

---

## When to Use Jenga AI

**Use it when:**
- You're building a non-trivial project across multiple sessions and need persistent engineering context instead of re-explaining it every time
- You're doing AI-driven development on a **large existing application** — a codebase too big for one context window, where an agent needs a durable map of what exists before it can safely change it (`j.uncharted` onboards it; see [Starting From an Existing Project](project/.wiki/intro-guide.md#starting-from-an-existing-project))
- Your system **spans multiple repositories** and you want one board, one set of agent roles, and one workflow across all of them rather than per-repo improvisation
- You want an agentic development workflow with separate planning, coding, testing, and review agents — not one model self-grading its own work
- You need traceability — who did what, when, on which task
- You're working across more than one AI coding agent or AI-native IDE and want one workflow, not a separate setup per tool
- You want to reuse and propagate the same agentic workflow across multiple projects and repositories (`j.distribute`)

**You might not need it when:**
- You're doing a quick one-off script or single-session experiment
- The whole codebase fits comfortably in one context window and the work is done in one sitting
- Your project has no meaningful test surface

📖 **Full reference:** [Docs site](https://samwelmunga.github.io/jenga-npm/reference.html) — mirrored at [project/.wiki/documentation.md](project/.wiki/documentation.md)

# Jenga AI — Documentation Reference

This document is the full reference for Jenga AI: every skill, every agent, MCP tools, hooks, and the inter-agent communication contract.

> For an introduction to the framework, see the [README](../../README.md).  
> For a guided first-experience walkthrough, see the [Intro Guide](./intro-guide.md).

---

## Table of Contents

- [Agents](#agents)
  - [Scrum Master](#scrum-master)
  - [Developer](#developer)
  - [Tester](#tester)
- [Skills](#skills)
  - [Setup & Planning](#setup--planning)
  - [Execution](#execution)
  - [Status & Review](#status--review)
  - [Committing & Maintenance](#committing--maintenance)
- [Playbook Reference](#playbook-reference)
- [MCP Tools](#mcp-tools)
- [Hooks](#hooks)
- [Directory Structure](#directory-structure)
- [Agent Communication Contract](#agent-communication-contract)

---

## Agents

Agents are defined in `.agents/agents/`. Each has a clearly bounded role and exclusive write permissions over specific project files. They communicate through typed sender objects and a shared trigger queue — never through direct conversation.

---

### Scrum Master

**File:** `.agents/agents/scrum-master.md`

**Role:** Plans and structures all work. Breaks user requests down into epics, stories, and tasks. Owns project memory.

**Owns:**
- `project/PROJECT_SUMMARY.md` — sole writer; the project's source of truth
- Epic status fields
- The queue processing loop

**Responsibilities:**
- At every session start, processes `project/queue/scrum_triggers.jsonl`: handles rapport reviews, status reviews, story/epic rollups, and proposed `PROJECT_SUMMARY.md` updates
- Creates, amends, and rollups board items following the schema in `templates/SCRUM_BOARD_SCHEMA.md`
- Uses advisory file locks before writing any board file
- In Brainstorm Mode (invoked via `/brainstorm`): explores ideas openly, challenges assumptions, proposes board mappings — holds off on writing anything until the user confirms
- In Mediator Mode (ML/AI tasks): translates between user plain language and the `ai_engineer` agent's technical output

**Trigger types it processes:**
- `rapport_review` — reads new problem rapports, creates backlog items or marks tasks as Failed
- `status_review` — checks board for items needing status updates
- `story_rollup` — if all tasks under a story passed, rolls up story status; then checks epic rollup
- `project_summary_update` — reviews proposed edits to `PROJECT_SUMMARY.md`, applies or rejects

**Example — Scrum Master in action:**
```
Session start:
Scrum Master reads scrum_triggers.jsonl:
→ Finds rapport_review for E01_S02_T03
→ Creates task E01_S02_T04 "Fix null pointer in auth middleware" with rapport reference
→ Clears the trigger file

User: "I want to add a password reset flow"
Scrum Master: "That fits under E01 (Auth). I'd structure it as S05 with three tasks:
  T01 — add forgot-password endpoint
  T02 — add reset token generation
  T03 — add reset-password endpoint
Does this look right before I write it to the board?"
```

---

### Developer

**File:** `.agents/agents/developer.md`

**Role:** Implements tasks. Works in isolation per task using git worktrees.

**Owns:**
- Code, worktrees, and commit history for tasks it picks up
- Pre-execution plans in `project/documentation/plans/`
- Post-execution summaries in `project/documentation/summaries/`

**Responsibilities:**
- Creates an isolated git worktree per task (`<E##_S##_T##-slug>`)
- Logs every incoming sender object to `project/logs/events.json` as its **first action**
- Writes a plan before implementing; writes a summary after
- Commits at meaningful milestones — not every line, and not just once at the end
- Passes a complete sender object (including commit SHAs) to the Tester on handoff
- **Never runs tests** — that is exclusively the Tester's responsibility
- After three failed conflict resolutions, writes a rapport to `project/rapports/problems/`, sets status to `Blocked`, and halts
- Never commits `.env` files or credentials

**Example — Developer flow:**
```
Receives sender object for E01_S02_T01 (JWT middleware)
→ Logs sender to events.json
→ Creates worktree: /projects/app-E01_S02_T01-jwt-middleware
→ Writes plan: project/documentation/plans/E01_S02_T01-plan.md
→ Implements JWT middleware
→ Commits: "feat: add JWT validation middleware"
→ Implements token extraction helper
→ Commits: "feat: extract bearer token from Authorization header"
→ Writes summary: project/documentation/summaries/E01_S02_T01-summary.md
→ Calls Tester with sender object including both commit SHAs
```

---

### Tester

**File:** `.agents/agents/tester.md`

**Role:** Validates all Developer output. The sole source of truth on whether a task passed.

**Owns:**
- Task and story status fields (sole writer)
- `project/configs/test-config.json` — test tool configuration, user-approved
- `project/data/baselines.json` — analytics baselines, maintained across sessions
- Rapports in `project/rapports/analysis/`

**Responsibilities:**
- Validates all required sender fields before proceeding — rejects with `"error"` if any are missing
- Runs the full testing lifecycle: unit, integration, e2e, SAST (opt-in), vulnerability scanning (opt-in), performance, coverage
- SAST and vulnerability scans require explicit user approval, logged to `events.json`
- Writes `Rejected` status only after notifying the user and receiving confirmation
- After every status update, checks for story/epic rollup and writes a trigger to the queue if warranted
- Maintains performance/coverage baselines so regressions surface across sessions

**Status values it can write:** `Passed`, `Passed with remarks`, `Failed`, `Rejected`, `Blocked`

**Example — Tester flow:**
```
Receives sender from Developer for E01_S02_T01
→ Validates: task_id ✅, commit SHAs ✅, worktree path ✅
→ Reads test-config.json: jest for unit, supertest for integration
→ Runs unit tests: 14 passed ✅
→ Runs integration tests: 3 passed ✅
→ Checks coverage: 87% (above baseline of 80%) ✅
→ Writes status: E01_S02_T01 → Passed
→ Checks rollup: all tasks in E01_S02 passed
→ Writes story_rollup trigger to scrum_triggers.jsonl
```

---

## Skills

Skills live in `skills/j-<name>/SKILL.md` — the root-canonical location; `.agents/skills/` and `.claude/skills/` are generated mirrors, never the source of truth. Invoke a skill as `/j-<name>` (the directory-resolved slash form) or `j.<name>` (the frontmatter form) in any Claude Code session. Three permanent exceptions keep their bare names: `/jenga`, `/jenga-permission-level`, and `/index` (the latter has no `SKILL.md` and isn't part of routing). Each skill's SKILL.md defines its behaviour, and optionally its `prefered_agent` (the sub-agent it delegates to).

---

### Setup & Planning

---

#### `/j-init`

**Description:** Initialize a new project with the standard directory structure, `PROJECT_SUMMARY.md`, `workflow.json`, git repo, and gitignore.

**Output type:** `any`

**Invokes:** /j-uncharted (conditional)

**When to use:** At the start of a new project — run this first, before anything else.

**What it creates:**
- `project/board/epics|stories|tasks/`
- `project/configs/workflow.json`
- `project/queue/`, `project/logs/`, `project/rapports/`, `project/documentation/`
- Initial `.gitignore` and first git commit

**Example:**
```
/j-init
→ Created project/ directory structure
→ Created project/configs/workflow.json
→ Created project/PROJECT_SUMMARY.md (stub)
→ git init + initial commit: "chore: init jenga project structure"
```

---

#### `/j-jbp`

**Description:** Scaffold the project using the [JengaBasePlate](https://github.com/samwelmunga/JengaBasePlate.git) boilerplate.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want a full project starter (not just the workflow scaffold). JBP includes opinionated structure for apps built with Jenga AI from the start.

**Example:**
```
/j-jbp
→ Clones JengaBasePlate into current directory
→ Installs dependencies
→ Runs /j-init automatically
```

---

#### `/jenga`

**Description:** Interactive-by-default board orchestrator with a fully automated escape hatch. Bare `/jenga` renders a picker and confirmation tree before scoping the run; `/jenga <ids>` resolves an explicit fuzzy-ID scope and confirms it; `/jenga *` reproduces the original zero-prompt behavior — decomposing any unbroken Epics into Stories, any unbroken Stories into Tasks, queuing all unqueued Tasks into `todo.md`, then executing every eligible item with no user prompts — until the board is fully started.

**Output type:** `id_list`

**Invokes:** /j-do, /j-route (conditional)

**When to use:** When you want to review and scope a run before it executes (bare `/jenga` or `/jenga <ids>`), or hands-free execution across the whole board via `/jenga *`. Jenga will read existing epics, decompose anything incomplete, and start executing.

**Delegates to:** Scrum Master (for decomposition), Developer (for execution)

**Example:**
```
/jenga
→ Reads PROJECT_SUMMARY.md
→ Finds E01 has no stories yet
→ Scrum Master decomposes E01 into S01, S02, S03
→ Decomposes each story into tasks
→ Queues all tasks in todo.md
→ Starts executing: /j-do on T01, T02, T03...
```

---

#### `/j-pi-plan`

**Description:** Define or expand project Epics in `PROJECT_SUMMARY.md`. Use at the start of a project to establish its foundation, or whenever adding major new features.

**Output type:** `any`

**Invokes:** none

**When to use:** When starting a new project, or when the user wants to plan a significant new area of work (new epic). Triggers on phrases like "new feature area", "big change", "expand the project".

**Delegates to:** Scrum Master

**Example:**
```
/j-pi-plan
Scrum Master: "Tell me about the project. What are the major goals?"
You: "It's a habit tracker with social sharing and analytics"
→ Creates E01: Core Habit Tracking
→ Creates E02: Social Sharing
→ Creates E03: Analytics Dashboard
→ Writes all three to PROJECT_SUMMARY.md
```

---

#### `/j-brainstorm`

**Description:** Focused planning session with the Scrum Master before committing anything to the board. Explores, challenges, and refines ideas in dialogue.

**Output type:** `any`

**Invokes:** /j-todo (conditional)

**When to use:** Before you know exactly what you want to build. The Scrum Master will ask pointed questions, surface assumptions, and propose board mappings — but nothing is written until you say so.

**Delegates to:** Scrum Master (Brainstorm Mode)

**Example:**
```
/j-brainstorm
"I want to add notifications to the app"

Scrum Master: "Which users receive notifications and for what events?"
You: "Users get notified when a friend completes a shared habit"
Scrum Master: "That touches E02 (Social Sharing). Should this be a new story
  under E02, or does it warrant its own epic if push + email + in-app are all needed?"
...
→ After agreement: "Ready to commit? → E02_S04: Habit Completion Notifications"
```

---

#### `/j-deep-dive`

**Description:** Multi-phase investigation workflow. Orchestrates information gathering, brainstorming, scrutiny, and solution assessment to produce a refined output document.

**Output type:** `any`

**Invokes:** /j-brainstorm, /j-examplify (conditional), /j-todo (conditional)

**When to use:** When a request needs thorough analysis before committing to a plan. Trigger phrases: "deep dive", "investigate thoroughly", "think this through properly", "analyze this in depth".

**Delegates to:** Scrum Master

**Phases:**
1. **Gather** — collects all available information about the topic
2. **Brainstorm** — generates and explores options interactively
3. **Scrutinise** — challenges assumptions, surfaces risks
4. **Assess** — evaluates options and produces a recommendation

**Example:**
```
/j-deep-dive on our auth strategy before we build it

Phase 1 — Scrum Master gathers: existing auth code, tech stack, threat model
Phase 2 — Brainstorms: JWT vs sessions vs OAuth, tradeoffs per use case
Phase 3 — Scrutinises: "JWT revocation is the riskiest assumption here"
Phase 4 — Produces: docs/auth-strategy-analysis.md with recommendation
```

---

#### `/j-todo`

**Description:** Add missions to `project/todo.md`, optionally linking them to epics and stories. Loops until done, then optionally executes the list.

**Output type:** `any`

**Invokes:** /j-do (conditional)

**When to use:** When you have specific features or tasks to add and want them tracked on the board.

**Delegates to:** Scrum Master

**Example:**
```
/j-todo
"Add rate limiting to the API"
→ Links to E02_S03 (or creates new story if none fits)
→ Writes to project/todo.md: E02_S03_T01
"Add request logging middleware"
→ Links to E02_S03_T02
Done. Run /j-do now? → Yes
```

---

#### `/j-btw`

**Description:** Capture a new mission mid-flow. Fits it into the Epic/Story structure and lets you choose to implement now or defer.

**Output type:** `any`

**Invokes:** none

**When to use:** When you think of something important while working on something else and don't want to lose the idea but also don't want to derail your current work.

**Delegates to:** Scrum Master

**Example:**
```
(While implementing auth)
/j-btw add a "remember me" checkbox to the login form
→ Scrum Master: "That fits under E01_S03 (Login UI). Add as T04?"
→ You: "Yes, defer it"
→ Written to board as E01_S03_T04, status: Pending
→ Returns to current task
```

---

#### `/j-spinoff`

**Description:** Capture a diverging topic mid-conversation. Collects context, optionally runs `/j-brainstorm` for prerequisites, saves a `/j-todo` entry, and returns focus to the primary thread.

**Output type:** `any`

**Invokes:** /j-brainstorm (conditional), /j-idea

**When to use:** When the conversation drifts to a new topic and you want to preserve both threads without losing context.

**Delegates to:** Scrum Master

**Example:**
```
(Mid-session on rate limiting)
You: "Oh, we should also think about caching strategy"
/j-spinoff
→ Scrum Master: "Captured: 'Evaluate caching strategy — Redis vs in-memory,
  touched on during rate limiting discussion'. Want to /j-brainstorm prereqs?"
→ Saved to todo.md
→ "Returning to rate limiting..."
```

---

#### `/j-idea`

**Description:** Capture a loosely-defined idea to `project/ideas.md` — a lightweight, "maybe someday" log with no board or promotion overhead.

**Output type:** `any`

**Invokes:** none

**When to use:** When you have a rough idea worth remembering but don't want the structured intake of `/j-todo` or an immediate board placement.

**Delegates to:** Scrum Master

**What it does:**
- Appends to `project/ideas.md` (auto-created from a template if missing)
- Loops for multiple ideas until you say you're done
- Never executes, refines, or promotes the idea itself — promotion happens later, e.g. via `/j-brainstorm`

**Example:**
```
/j-idea
"Maybe add a dark mode toggle to settings"
→ Appended to project/ideas.md
"Capture another idea, or done?" → Done
```

---

#### `/j-playbook-new`

**Description:** Guided wizard that walks you through authoring a new project-local playbook — id, name, description, keywords, examples, and an ordered list of skills — validated against the real skill/playbook catalogs and self-validated before success is ever reported.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to define your own reusable skill chain for `j.jenga`'s natural-language matching, beyond the built-in playbooks.

**What it does:**
- Validates id uniqueness and skill names against the live catalogs (never a hardcoded list)
- Writes `project/.playbooks/<id>.json`
- Re-validates the just-written file via `load-playbooks.sh lookup` before declaring success

**Example:**
```
/j-playbook-new
"id: my-release-flow"
"name: My Release Flow"
→ skills: /j-commit, /j-dev-done
→ Written to project/.playbooks/my-release-flow.json
→ Confirmed loadable — invoke via j.playbook my-release-flow
```

---

#### `/j-strategy`

**Description:** Walk through a guided conversation to capture or update `docs/STRATEGY.md` — covering Vision, Value Proposition, Scope, and Target Audience — one section at a time.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to capture or refresh the project's strategic brief for investors/partners. Revenue model, pricing, and competitive analysis are always out of scope and never asked about.

**Delegates to:** Developer

**Example:**
```
/j-strategy
→ docs/STRATEGY.md does not exist — running new capture flow
"What is the long-term direction or ambition for this project?" → [answer]
...
→ Written to docs/STRATEGY.md — captured Vision, Value Proposition, Scope, and Target Audience.
```

---

### Execution

---

#### `/j-do`

**Description:** Execute tasks from the scrum board. Reads from `project/todo.md`, resolves each entry to its full board context, and drives the Developer agent through implementation with the correct sender object and communication contract.

**Output type:** `any`

**Invokes:** /j-commit

**When to use:** When you're ready to implement. The main execution skill.

**Delegates to:** Developer

**Example:**
```
/j-do
→ Reads todo.md: E01_S02_T01-jwt-middleware, E01_S02_T02-refresh-tokens
→ You select: E01_S02_T01
→ Builds sender object with task/story/epic IDs
→ Invokes Developer agent
→ Developer implements, Tester validates, board status updated
```

---

#### `/j-dooo`

**Description:** Parallel execution orchestrator. Calls `/j-do` to start implementations via sub-agents, then loops back to identify and offer parallelisable tasks until the user selects "Done".

**Output type:** `any`

**Invokes:** /j-do

**When to use:** When multiple independent tasks are ready and you want to run them simultaneously to save time.

**Delegates to:** Scrum Master (orchestration), Developer (per task)

**Example:**
```
/j-dooo
→ Starts E01_S02_T01 as background sub-agent
→ Identifies E02_S01_T01 as parallelisable (no dependencies on T01)
→ "Start E02_S01_T01 in parallel?"
→ Yes → Starts second sub-agent
→ Both run simultaneously
→ Board updated as each completes
```

---

#### `/j-redo`

**Description:** Rework a previous implementation by commit SHA or Epic/Story number. Includes scope assessment, plan, and doc updates.

**Output type:** `any`

**Invokes:** /j-todo

**When to use:** When previously completed work needs to be revisited — incorrect implementation, changed requirements, or a bug found post-release.

**Delegates to:** Scrum Master (scope assessment), Developer (implementation)

**Example:**
```
/j-redo E01_S02 — auth tokens aren't being invalidated on logout
→ Scrum Master: "E01_S02 was marked Passed on 2026-06-01.
  Scope: T01 (JWT) and T02 (refresh tokens) both need review.
  Reason: logout doesn't call token blacklist. Creating E01_S02_T04."
→ Developer re-implements, Tester re-validates
→ PROJECT_SUMMARY.md updated to note the fix
```

---

#### `/j-error`

**Description:** Guided troubleshooting flow that gathers context about an error — where it occurs, what was attempted, what went wrong, and what was expected.

**Output type:** `any`

**Invokes:** /j-todo

**When to use:** When something is broken and you need structured help diagnosing it.

**Delegates to:** Tester

**What it captures:**
- Where the error occurs (file, function, endpoint)
- What action triggered it
- The actual error output
- The expected behaviour

**Example:**
```
/j-error
"500 on POST /api/auth/login"
→ Tester: "What's the stack trace?"
→ You: [paste]
→ Tester: "The issue is in token-service.ts line 42 — bcrypt.compare()
  is being called with undefined salt rounds. Likely missing env var."
→ Creates task E01_S02_T05 "Fix bcrypt config on login endpoint"
```

---

#### `/j-train`

**Description:** Scaffold and run ML training jobs. Use `new <type> <job-name>` to scaffold from a template, or `run <job-dir>` to execute the validate → train pipeline.

**Output type:** `any`

**Invokes:** none

**When to use:** When working on machine learning components within a Jenga AI project.

**Subcommands:**
- `/j-train new <type> <job-name>` — scaffold a new job from a template (`classifiers`, `transformers`, `nlp`)
- `/j-train run <job-dir>` — execute the two-phase pre-flight → smoke test → full train pipeline

**Example:**
```
/j-train new classifiers sentiment-model
→ Copies .training/template/classifiers/ to jobs/sentiment-model/
→ "✅ Scaffolded job 'sentiment-model' from template 'classifiers'"

/j-train run jobs/sentiment-model
→ Phase 1: validates config and data paths
→ Phase 2: runs smoke test (small batch)
→ Full train: executes start.sh
```

---

#### `/j-playbook`

**Description:** Invoke a specific `/jenga` playbook directly by ID, skipping natural-language matching entirely and going straight to chain confirmation and execution.

**Output type:** `any`

**Invokes:** /jenga (by reference)

**When to use:** When you already know the exact playbook id you want to run, rather than describing your intent in natural language for `j.jenga` to match.

**What it does:**
- Bare invocation (no id) lists all available playbooks in a table
- Resolves the given id, reporting `not_found` and `invalid` as distinct outcomes
- Reuses `/jenga`'s own chain-confirmation and sequential-execution machinery — no separate implementation

**Example:**
```
/j-playbook brainstorm-to-mirror
→ Resolved playbook: "Brainstorm to Mirror" (3 steps)
→ Confirm chain: /j-brainstorm → /j-commit → /mirror-public? [y/N] → y
→ Executing step 1/3...
```

---

#### `/j-uncharted`

**Description:** Investigate code that has no Jenga board provenance — a foreign file, an external source being pulled in, or an entire pre-existing codebase — and give it a consistent understanding document plus proper board representation.

**Output type:** `text`

**Invokes:** none

**When to use:** When you have code nobody planned, decomposed, or tracked through Jenga — a segment, an imported source, or a whole legacy codebase — and want it understood and represented on the board.

**Delegates to:** Scrum Master

**What it does:**
- `segment` — analyses one file/directory/feature and proposes a standard epic/story/task (or, in `--mode investigate`, a conversational architecture investigation)
- `import` — acquires an external source (git URL, out-of-repo path, or pasted snippet) into the repo, then hands off to `segment`
- `onboard` — analyses a whole codebase and writes board-only, `[ARCH]`-tagged or backfilled epics — it never touches application code
- `refresh` — incremental re-scan of an already-onboarded codebase since its last baseline, skipping unchanged subsystems

**Example:**
```
/j-uncharted segment src/legacy/billing/
→ Target unlinked — no board item references it
→ Understanding document written to project/rapports/analysis/uncharted-segment-billing-...md
→ Proposes E12: Billing Module Stabilization (2 stories, 5 tasks)
→ Accept as proposed? [y/N] → y
→ Written to project/board/, queued to todo.md
```

---

### Status & Review

---

#### `/j-status`

**Description:** Print a human-readable summary of the entire scrum board — all epics, stories, and tasks with their statuses — plus any open rapports and unprocessed queue triggers.

**Output type:** `text`

**Invokes:** none

**When to use:** Any time you want a quick overview without reading raw board files.

**Example:**
```
/j-status

E01 — Auth System (In Progress)
  S01 — JWT Middleware ✅ Passed
  S02 — Refresh Tokens 🔄 In Progress
    T01 — Token generation ✅
    T02 — Token rotation ⏳ Pending
  S03 — Logout flow ⏳ Pending

Open rapports: 1 (E01_S02_T01 — bcrypt config)
Queue depth: 2 triggers pending
```

---

#### `/j-continue`

**Description:** Check project status across `PROJECT_SUMMARY.md`, epics, and stories to determine what should be done next. Reports "All done!" if everything is complete.

**Output type:** `any`

**Invokes:** none

**When to use:** At the start of a session when you want the system to orient you and pick up where you left off.

**Example:**
```
/j-continue
→ Reads PROJECT_SUMMARY.md and board state
→ "E01_S02 is In Progress. T02 (token rotation) is Pending.
   Recommended next: /j-do E01_S02_T02"
```

---

#### `/j-proceed`

**Description:** Review project progress by checking epics and stories, optionally consulting `PROJECT_SUMMARY.md` and `WARP.md`, then continue executing the project plan.

**Output type:** `any`

**Invokes:** none

**When to use:** Similar to `/j-continue` but more assertive — it reviews progress and immediately resumes execution rather than just recommending.

**Delegates to:** Scrum Master

**Example:**
```
/j-proceed
→ Scrum Master reviews board
→ "E01 is 60% complete. S03 (Logout) is unstarted but has no blockers.
   Starting E01_S03 now..."
→ Invokes /j-do
```

---

#### `/j-reconcile`

**Description:** Reconcile the scrum board with actual implementation state. Cross-checks every task's board status against git history and worktrees, merges orphaned worktree branches, demotes unimplemented "Done" items, and promotes secretly-implemented items.

**Output type:** `text`

**Invokes:** /j-uncharted (conditional)

**When to use:** When the board feels out of sync — after a big merge session, when tasks were completed outside the normal workflow, or when `todo.md` has grown stale.

**Delegates to:** Scrum Master

**What it checks:**
- Every task status vs. git history (commit messages with task IDs)
- Orphaned worktrees that were never merged
- `todo.md` entries that are already Done on the board

**Example:**
```
/j-reconcile
→ Scanning board: 23 tasks
→ E02_S01_T03: board says "Pending" but commit "feat(E02_S01_T03)" found
  → Promoted to "Passed"
→ E03_S02_T01: board says "Done" but no commits found
  → Demoted to "Pending"
→ Found orphaned worktree: app-E01_S03_T02-logout
  → Merged and cleaned up
→ Removed 3 stale entries from todo.md
```

---

#### `/j-close-story`

**Description:** Close a story by verifying all tasks are in terminal state, extracting actual diff stats per task, computing scope divergence flags, and writing closure metadata to task frontmatter.

**Output type:** `any`

**Invokes:** none

**When to use:** When every task in a story has reached a terminal status and you want to formally close the story with real, git-derived diff stats instead of estimates.

**What it does:**
- Guards that all tasks are terminal before proceeding
- Extracts `actual_files_changed` / `actual_lines_delta` per task from EST-tagged commits
- Computes and writes `scope_divergence_flag` against `project/configs/scope-thresholds.json`
- Marks `status: Privatized` instead of `Done` when every touched file is blocklisted from the public mirror

**Example:**
```
/j-close-story E17_S06
→ CLOSEABLE — all tasks terminal
→ E17_S06_T01: files_changed=3, lines_delta=142, scope_divergence_flag=false
→ E17_S06_T02: files_changed=1, lines_delta=18, scope_divergence_flag=false
→ Scope Divergence: none
→ Story E17_S06 closed as Done
```

---

#### `/j-dashboard`

**Description:** Launch the local Jenga project dashboard (API + UI), or export a single self-contained HTML snapshot with a point-in-time data snapshot baked in.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want a visual overview of the scrum board, or need a portable, offline-viewable snapshot to hand to someone else — including over a remote/cloud session with no shared filesystem, via `--data-url`.

**What it does:**
- `start` / `open` / `both` — launches the API + UI dashboard via `project/app`'s own npm scripts
- `--snapshot [--out <path>]` — bundles a point-in-time snapshot into one self-contained HTML file
- `--data-url` — additionally base64-encodes the snapshot into a `data:text/html;base64,...` URI for remote delivery

**Example:**
```
/j-dashboard --snapshot
→ Captured /v1/board, /v1/history, /v1/architecture
→ Snapshot dashboard written to: jenga.html
```

---

#### `/j-reconcile-origin`

**Description:** Sync the current (or specified) branch with origin by rebasing local commits on top of the latest upstream state.

**Output type:** `any`

**Invokes:** none

**When to use:** When your local branch has drifted from origin and you want a scripted rebase, with structured conflict rapports instead of raw git conflict markers.

**What it does:**
- Rebases onto `origin/<branch>` via a dedicated script — no inline git commands
- Detects a missing local tracking branch and offers to create one
- On conflict, presents a structured rapport (local vs. origin sections) with resolution options, including "handle later" with annotated markers

**Example:**
```
/j-reconcile-origin feature/rate-limiting
→ Rebasing onto origin/feature/rate-limiting...
→ Conflict in src/middleware/rate-limit.ts
1. Resolve now  2. Keep local, re-apply upstream  3. Handle later  4. Other
→ 3 → Annotated with # RECONCILE-ORIGIN CONFLICT: and continuing
```

---

### Committing & Maintenance

---

#### `/j-commit`

**Description:** Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries.

**Output type:** `any`

**Invokes:** /j-reconcile, /j-doc-sync

**When to use:** After completing any EST work item — when you want a structured, trackable commit message.

**Naming convention:** `epic(E##): <title>`, `story(E##_S##): <title>`, `task(E##_S##_T##): <title>`

**Example:**
```
/j-commit E01_S02_T01
→ "task(E01_S02_T01): add JWT validation middleware"
→ Staged: src/middleware/jwt.ts, tests/middleware/jwt.test.ts
→ git commit -m "task(E01_S02_T01): add JWT validation middleware"
```

---

#### `/j-lgtm`

**Description:** Approve and commit the current work, then continue to the next task. Shortcut that chains `/j-commit` followed by `/j-continue`.

**Output type:** `any`

**Invokes:** /j-commit, /j-continue

**When to use:** When you've reviewed the work and want to quickly commit and move on.

**Example:**
```
/j-lgtm
→ /j-commit (creates EST commit)
→ /j-continue (identifies next task)
→ "Next: E01_S02_T02 — Refresh token rotation. Start? [yes/no]"
```

---

#### `/j-distribute`

**Description:** Distribute Jenga AI framework files from this private monorepo to one or more consuming projects via the local filesystem — release type selection, version bumping, a dry-run preview, per-target file copy, and a post-distribution git commit.

**Output type:** `any`

**Invokes:** none

**What it is:** `/j-distribute` treats this repository as the master copy of your Jenga AI framework and each registered consumer project as a versioned snapshot of it. Consumer projects are registered in `distribute.config.json` at the repo root (not `.jenga_paths`/`jenga.config.json` — that mechanism has been retired), as entries in a `targets` array:

```json
{
  "name": "my-project",
  "path": "/absolute/or/relative/path/to/project",
  "active": true
}
```

Passing a path argument (e.g. `/j-distribute /path/to/project`) adds a new entry to `distribute.config.json` automatically, deriving `name` from the target directory's name. Schema reference: `skills/j-distribute/CONFIG_SCHEMA.md`.

**When to use:** Use `major`, `minor`, or `patch` after making framework changes that should become a versioned upgrade for every active target — these bump the version in `package.json` (via `npm version`) and distribute to every active, path-valid target. Use `amend` when quietly onboarding a new consumer project or fixing files missed in a previous release; it keeps the version unchanged and only updates targets whose config reports they're behind. Every release type stops at a dry-run preview (`distribute-changes.sh --dry-run`) and requires explicit confirmation before any file is copied.

**Release types:**
- `major` / `minor` / `patch` — bumps `package.json`'s version via `npm version`, distributes to all active targets
- `amend` — no version bump; distributes only to targets that are behind or have no prior config, via `check-version.sh`

**What it does:**
- Validates each target's `active` flag and on-disk `path` before including it in the run
- Runs a dry-run preview per target and waits for `y` confirmation before touching anything
- Copies files via `scripts/distribute-changes.sh`, never inline
- Commits the version bump via `scripts/commit-version-bump.sh` (skipped for `amend`)
- Never invokes `/j-self-sync` or `/j-mirror-public` — those are separate distribution surfaces with separate triggers

**Example:**
```
/j-distribute
Release type? → minor
→ Version bumped to 1.3.0
→ Scanning distribute.config.json...
→ Eligible targets: my-app-1, my-app-2
→ Dry-run preview for my-app-1 ... my-app-2 ...
Proceed with distribution to the above targets? [y/N] → y
→ Syncing my-app-1: ✅ succeeded
→ Syncing my-app-2: ✅ succeeded
→ Committed version bump: chore(release): bump to 1.3.0
```

---

#### `/j-doc`

**Description:** Generate or update a documentation file by resolving a target path to a clear documentation objective before writing.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to create or refresh a specific doc file — "update the docs", "write docs for X", "the README is stale", "generate documentation for X". Pass an optional target path (e.g. `/j-doc docs/API.md`); omit it to default to `README.md`.

**Example:**
```
/j-doc docs/CLI.md
→ Resolved target: docs/CLI.md — objective: CLI usage guide
→ Reading existing docs/CLI.md...
→ Gathering evidence: package.json, board items, skill metadata
→ Regenerating docs/CLI.md with current commands and flags
→ Written: docs/CLI.md ✅
```

---

#### `/j-doc-sync`

**Description:** Compare the current state of a project with its documentation and update any documentation that is stale, incomplete, or missing.

**Output type:** `any`

**Invokes:** none

**When to use:** When documentation may have drifted from the implementation, or after a big implementation sprint.

**Arguments:**
- `update: <path>` — specific doc file(s) to check and update
- `source: <path>` — source file(s) to diff against
- `exclude: <pattern>` — paths to skip
- `minify: true` — shrink verbose docs to essential content only

**Example:**
```
/j-doc-sync update: docs/api.md source: src/routes/
→ Reading src/routes/auth.ts, src/routes/users.ts, src/routes/habits.ts
→ Comparing against docs/api.md
→ Found: 3 new endpoints not documented
→ Found: 1 deprecated endpoint still documented
→ Updated docs/api.md ✅
```

---

#### `/j-skillify`

**Description:** Refactor one or more existing skills into a cleaner structure — extracting hardcoded content into asset files, moving deterministic steps into scripts, and simplifying the skill body.

**Output type:** `any`

**Invokes:** none

**When to use:** When a skill has grown large, contains hardcoded templates, or has multi-step logic that would be more reliable as a shell script.

**What it does:**
- Extracts hardcoded file content (JSON, Markdown, config) into `assets/` templates
- Extracts directory lists into `assets/` reference files
- Moves deterministic sequences into `scripts/` bash scripts
- Rewrites the skill body to delegate to those assets and scripts

**Example:**
```
/j-skillify j-init
→ Reading skills/j-init/SKILL.md
→ Found: 40-line hardcoded directory list
→ Extracted to: skills/j-init/assets/directories.txt
→ Found: inline workflow.json template
→ Extracted to: skills/j-init/assets/workflow.json.template
→ Rewrote SKILL.md: 80 lines → 22 lines
```

---

#### `/j-route`

**Description:** Intelligently route a prompt to the best-matching skill. Reads available skills, matches semantically and by keyword, enriches the prompt with board context, then invokes the matched skill.

**Output type:** `any`

**Invokes:** none

**When to use:** When you know what you want to do but don't know which skill handles it — or just want to describe your intent naturally.

**Example:**
```
/j-route I want to think through the caching approach before we build it
→ Matches: /j-deep-dive (keywords: "think through", "analyze")
→ Invoking /j-deep-dive with enriched context...

/j-route something broke in the auth flow
→ Matches: /j-error (keywords: "broke", "error")
→ Invoking /j-error...
```

---

#### `/j-improve`

**Description:** Analyse a codebase and produce a structured improvement plan toward a defined goal.

**Output type:** `any`

**Invokes:** /j-examplify (conditional), /j-evaluate, /j-todo

**When to use:** When you want a systematic review of what can be improved in a specific area (performance, maintainability, test coverage, etc.).

**Example:**
```
/j-improve improve test coverage in the auth module
→ Goal confirmed: increase test coverage in src/auth/
→ Scanning: 12 files, current coverage 54%
→ Improvement plan:
  1. Add unit tests for token-service.ts (0% coverage, high risk)
  2. Add integration tests for /auth/refresh (no tests)
  3. Parameterise bcrypt test cases to cover edge inputs
→ Creates task: E01_S06_T01 "Improve auth module test coverage"
```

---

#### `/j-evaluate`

**Description:** Analyse example files against a target goal and produce a structured evaluation rapport.

**Output type:** `any`

**Invokes:** none

**When to use:** When you have example outputs or implementations and want them measured against a defined quality goal.

**Inputs:** A filled `eval_invokation_template.yml` with a `goal` and a list of `paths` to example files.

**Example:**
```
/j-evaluate
goal: "API responses should follow RFC 7807 error format"
paths: [examples/auth-error.json, examples/rate-limit-error.json]

→ Evaluating auth-error.json: missing 'instance' field — partial compliance
→ Evaluating rate-limit-error.json: compliant ✅
→ Rapport written to: project/rapports/analysis/eval-rfc7807-2026-07-09.md
```

---

#### `/j-examplify`

**Description:** Explain a concept, feature, use case, or pattern with grounded examples — what it is, why it exists, how it works, when to use it, and a concrete example.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to understand something (a pattern, a Jenga AI concept, a piece of code) without digging through docs.

**Output:** Saves an explanation to `project/documentation/examples/`.

**Example:**
```
/j-examplify sender objects in Jenga AI

What it is: A typed JSON contract passed between every agent call
Why it exists: Prevents agents from operating on stale or ambiguous context
How it works: Contains task_id, story_id, epic_id, commit SHAs, worktree path
When to use: Every inter-agent call — no exceptions
Example: [before/after showing agent call with and without sender object]
→ Saved to: project/documentation/examples/sender-objects.md
```

---

#### `/j-help`

**Description:** List all available skills with a short description of each.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want a quick overview of what skills are available in the current project.

**Example:**
```
/j-help
→ Available skills:
  /j-brainstorm — Focused planning session with Scrum Master
  /j-btw        — Capture a mid-flow idea
  /j-commit     — Commit using EST naming convention
  ...
```

---

#### `/j-dev-done`

**Description:** Commit the current work and immediately sync it into the `.claude/` and `.agents/` mirrors. Shortcut that chains `/j-commit` followed by `/j-self-sync`.

**Output type:** `any`

**Invokes:** /j-commit, /j-self-sync

**When to use:** Right after implementing a root-level framework change (`skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `settings.json`), so the mirrors never sit stale waiting on a manual `/j-self-sync` call.

**What it does:**
- Runs `/j-commit` for the given scope id — halts cleanly if there was nothing to commit
- Runs `/j-self-sync` (including its Merged-status and Deploy-reconcile passes)
- Commits whatever `/j-self-sync` wrote, in a second, reconciliation-free commit

**Example:**
```
/j-dev-done E42_S04_T01
→ task(E42_S04_T01): add permission-level invariant check
→ self-sync: +4 ~2 -0
→ chore(self-sync): mirror skills/agents/hooks changes
```

---

#### `/j-gitignore`

**Description:** Retroactively repair an already-scaffolded project's Jenga gitignore state — strips the stray heredoc `EOF` line left by pre-fix `/j-init` scaffolds, adds or removes the Jenga-owned path entries via a managed block, and untracks those paths from git (and from origin) while leaving every file on disk.

**Output type:** `any`

**Invokes:** none

**When to use:** When Jenga files (`.claude/`, `.agents/`, `jenga.config.json`, etc.) are being committed unexpectedly, when `.gitignore` has a stray `EOF` line, or you want the Jenga scaffold gone from the remote while it stays on disk locally. `/j-init` cannot do this — it hard-stops on an already-scaffolded project.

**What it does:**
- Audits the current gitignore/tracked state (read-only)
- Repairs `.gitignore` via a managed block, tiered by path (`scaffold` / `hybrid` / `board` / `optional`)
- Untracks matched paths via `git rm --cached`, with opt-in commit and push

**Example:**
```
/j-gitignore
→ Audit: 6 Jenga-owned paths tracked, stray EOF line found
Which Jenga paths should this project ignore? → 1 (scaffold only)
→ .gitignore repaired, 6 paths untracked and staged
How far should I take the untracking? → 2 (commit locally)
```

---

#### `/j-self-sync`

**Description:** Mirror this repo's root-level framework directories into its own `.claude/` and `.agents/` sub-trees so edits to `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, and `settings.json` take effect in the current session — the in-repo replacement for the retired `/j-distribute` self-sync loop.

**Output type:** `any`

**Invokes:** none

**When to use:** After editing any root-level framework file, before expecting the current agent session to see the change.

**What it does:**
- Mirrors `bin/`, `lib/`, `scripts/`, `agents/`, `hooks/`, `mcp/`, `skills/`, `templates/`, `settings.json` into both `.claude/` and `.agents/`, plus `agents/` alone into `.github/agents/`
- Runs a non-fatal Merged-status pass, promoting closed tickets whose files are now fully mirrored
- Runs a non-fatal Deploy-reconcile pass against the public `jenga-npm` repo's tags

**Example:**
```
/j-self-sync
→ +3 ~1 -0 mirrored into .claude/ and .agents/
→ Merged-status pass: E42_S04_T01 -> Merged
→ Deploy-reconcile pass: no new tags found
```

---

### Publishing, Cloud & Utilities

---

#### `/j-cloud-connect`

**Description:** Guided cloud storage setup wizard — installs `rclone` if missing, lets you pick any rclone-supported backend from a live provider list, runs that backend's own config/auth flow, and independently verifies the remote works.

**Output type:** `any`

**Invokes:** none

**When to use:** Before using `/j-dashboard-share` or any other flow that uploads to a cloud remote, if no rclone remote is configured yet.

**What it does:**
- Installs/detects `rclone`
- Lists live backends via `rclone` itself (never a hardcoded list)
- Runs the backend's own config/auth flow, surfacing any auth URL directly
- Verifies the resulting remote with `rclone about` before reporting success

**Example:**
```
/j-cloud-connect
→ rclone already installed
Pick a backend: 1. Google Drive 2. S3 3. Dropbox ... → 1
→ Opening auth URL: https://accounts.google.com/...
→ PASS: remote 'gdrive' is configured and verified working.
```

---

#### `/j-convert`

**Description:** Convert JSON, JSONL, YAML, or YML dataset files to CSV format. Pass-through for files already in CSV. Flattens nested structures using dot-notation.

**Output type:** `any`

**Invokes:** none

**When to use:** When preparing a dataset file for `/j-train` jobs that expect CSV input.

**What it does:**
- Auto-detects the input format from the file extension
- Flattens nested objects (e.g. `{"user": {"age": 30}}` → column `user.age`)
- Warns before converting a top-level JSON object instead of an array

**Example:**
```
/j-convert data/train.jsonl
→ Detected format: jsonl
→ Flattened nested fields: user.name, user.age
→ Output: data/train.csv
```

---

#### `/j-dashboard-share`

**Description:** Snapshot the project dashboard and upload it to a configured cloud storage remote in one step, by sequencing `/j-dashboard`'s snapshot script and a templated-path rclone upload script.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to hand off a point-in-time dashboard snapshot to someone via cloud storage, without manually running snapshot and upload as two separate steps.

**What it does:**
- Captures a snapshot via `/j-dashboard`'s own script
- Resolves which configured rclone remote to use (prompts if more than one; points at `/j-cloud-connect` if none are configured)
- Uploads via a templated-path `rclone copyto` — upload only, never creates a public share link

**Example:**
```
/j-dashboard-share
→ Snapshot dashboard written to: jenga.html
→ Uploading to remote 'gdrive'...
→ Uploaded to: JengaAI/agents/20260923T134500-board-snapshot.html
```

---

#### `/j-mirror-public`

**Description:** Mirror this private repo one-way to its public counterpart (`jenga-npm`), applying a `.publicignore` blocklist and producing a single squash commit per run so private board, queue, log, and rapport artefacts never leak downstream.

**Output type:** `any`

**Invokes:** none

**When to use:** When you want to publish the current framework state to the public GitHub repo, after verifying with a dry run what would ship.

**What it does:**
- `--dry-run` / `--inventory` — read-only previews of what would ship or be blocked
- `--exclude <path>` — appends a new `.publicignore` entry
- Real run — fetches, safety-checks against the last mirror marker, rsyncs, squash-commits, pushes
- `--force` — destructive override for a diverged public repo, with enumeration, confirmation, and an automatic pre-force rescue tag

**Example:**
```
/j-mirror-public --dry-run
→ would ship: 607 files, would block: 599 files

/j-mirror-public
→ nothing to mirror — public tree already matches private (post-blocklist)
```

---

#### `/j-publish`

**Description:** Configure, validate, and orchestrate scaffolded release workflows through a single `/j-publish` entry point with bounded sub-commands, across `mobile-ios`, `npm`, `npm-ci`, and `droplet` targets.

**Output type:** `any`

**Invokes:** none

**When to use:** When you're ready to configure a deployment target or ship a release — an iOS App Store build, an npm package, an OIDC-based npm CI publish, or a droplet deploy over SSH.

**What it does:**
- `setup` — wizard to scaffold or refresh a target's config
- `deploy` — full gated deploy pipeline (pre/post-deploy quality gates, changelog update, semver bump, adapter dispatch, ledger entry); `--dry-run` rehearses end-to-end with no real publish
- `stage` — npm/npm-ci only: stage, smoke-test, and approve/reject a release before it goes live
- `history` / `release-notes` — read the publish ledger / merge new entries into `CHANGELOG.md`

**Example:**
```
/j-publish deploy --target npm-registry --dry-run
→ Pre-deploy gates: build ✅ test ✅
→ Suggested bump: minor (1.2.0 -> 1.3.0)
→ Deploy v1.3.0 to npm-registry? [y/N] → y (dry-run — no real publish)
```

---

#### `/j-clearify`

**Description:** Clarifies ambiguous, dense, or under-specified prompts and conversation on request — inspects an attached prompt or falls back to the current conversation and surfaces plain-language clarifications with examples.

**Output type:** `any`

**Invokes:** none

**When to use:** When a request, instruction, or piece of conversation is jargon-heavy, vague, or bundles multiple asks, and you want it broken down in plain language before proceeding.

**What it does:**
- Targets an attached prompt/file/pasted text, or falls back to the most recent message plus surrounding context
- Flags jargon, unclear references, compound asks, unstated assumptions, and vague qualifiers
- For each item: a plain-language clarification, a simplified restatement, added context, and an example where it helps

**Example:**
```
/j-clearify "spin up the usual setup for the staging deploy"
### 1. "the usual setup"
Plain-language: ...
Simplified restatement: ...
Example: ...
```

---

#### `/j-wtf`

**Description:** Alias of `/j-clearify` — identical behaviour, provided only so the `/wtf` slash command resolves to a skill.

**Output type:** `any`

**Invokes:** /j-clearify

**When to use:** Same as `/j-clearify` — invoke either name interchangeably.

**Example:**
```
/j-wtf does this error mean
→ (identical to /j-clearify)
```

---

## Playbook Reference

A playbook is a dedicated, versionable JSON file describing an ORDERED chain of skills that `/jenga`'s natural-language branch may propose as an editable, confirmable numbered list when free-text intent spans more than one skill and doesn't cleanly resolve to a single one (see `skills/j-route/SKILL.md`'s matching and `skills/jenga/scripts/load-playbooks.sh`, which loads and validates every entry at run time). Built-in playbooks live under `skills/jenga/playbooks/*.json`; project-local playbooks (authored via `/j-playbook-new`) live under `project/.playbooks/*.json` and are merged into the same catalog. `skills/jenga/playbooks/schema.json` is the schema file itself, not a playbook — `load-playbooks.sh` excludes it by filename. Invoke a specific playbook directly (skipping natural-language matching) via `/j-playbook <id>`.

Each entry below lists a playbook's `id`, display `name`, `description`, `keywords` (the highest-priority natural-language match signal), and its `steps` — the ordered skill chain it runs, in execution order. A step may itself be a StepObject (e.g. `forward_from`, `conditional`, or a nested `playbook` composing another playbook by id) rather than a bare skill name — see `docs/skill-authoring.md`'s Playbook StepObject Schema section for the full per-field contract; this reference shows each step's target skill/playbook only.

### Built-in Playbooks (`skills/jenga/playbooks/`)

#### `board-hygiene`

**Name:** Board Hygiene

**Description:** Reconciles the scrum board against what is actually implemented, captures whatever drift that turns up as follow-up todos, and reports the resulting board state — a read-only triage chain that writes no code and produces no commit of its own.

**Keywords:** board hygiene, board triage, board health, tidy the board, board audit

**Steps:** `j-reconcile` → `j-todo` (conditional: only if `j-reconcile` found something, `forward_from: j-reconcile`) → `j-status`

---

#### `brainstorm-to-mirror`

**Name:** Idea to Public Release

**Description:** Takes a rough idea all the way from planning through implementation, committing, and a public mirror release — the canonical end-to-end Jenga workflow chain.

**Keywords:** idea to release, plan and ship, idea to done, full workflow, end to end, plan build ship, idea to production

**Steps:** `j-brainstorm` → `j-todo` → `j-do` → `j-dev-done` → `j-mirror-public`

---

#### `idea-to-committed`

**Name:** Idea to Committed

**Description:** Takes a rough idea through planning, board capture, implementation, and a commit — the end-to-end Jenga workflow chain, stopping at the commit rather than at a release.

**Keywords:** idea to commit, plan build commit, brainstorm to commit, capture and implement, start to commit

**Steps:** `j-brainstorm` → `j-todo` → `j-do` → `j-commit`

---

#### `understand-then-commit`

**Name:** Understand Then Build

**Description:** Investigates existing or unfamiliar code first, then runs the full idea-to-commit pipeline on top of what was learned — a composed chain built from the canonical `idea-to-committed` playbook, terminating at the commit.

**Keywords:** understand then build, investigate then build, explore then implement, onboard and build, learn the codebase first

**Steps:** `j-uncharted` → *(composes playbook `idea-to-committed`)*

---

### Project-Local Playbooks (`project/.playbooks/`)

Authored per-project via `/j-playbook-new`; merged into the same load-time catalog as the built-in playbooks above.

#### `improve-to-commit`

**Name:** Improve to Committed

**Description:** Analyzes existing code to produce a structured improvement plan, captures that plan on the board, implements it, and commits — the improvement-first counterpart to `idea-to-committed`.

**Keywords:** improve to commit, improvement plan, analyze then build, plan improvements, harden and commit

**Steps:** `j-improve` → `j-todo` → `j-do` → `j-commit`

---

## MCP Tools

MCP (Model Context Protocol) tools extend Claude Code with additional capabilities. They are configured in `settings.json`.

---

### `mcp/help`

**Purpose:** Discovers available skills by scanning `.agents/skills/`. Returns skill folder names programmatically.

**Use case:** Building tooling that needs to enumerate available skills without reading the filesystem directly.

```bash
cd .agents/mcp/help && npm install
node index.js           # lists all skill names
node index.js skills/   # list with custom path
```

---

### `mcp/execute-ticket`

**Purpose:** Planned tool — creates a sub-agent, initialises a git worktree, and names the session after the task ID.

**Status:** In development. See `.agents/mcp/execute-ticket/index.js`.

---

## Hooks

Hooks are configured in `settings.json` and fire automatically at specific points in a Claude Code session.

| Hook | Trigger | Script |
|---|---|---|
| `WorktreeCreate` | Developer creates a worktree | `git worktree add` + echo path |
| `WorktreeRemove` | Developer removes a worktree | `git worktree remove --force` |
| `SessionEnd` | Any session ends | `hooks/on_session_end.sh` (async) |

---

### `hooks/on_session_end.sh`

Runs asynchronously at the end of every session:

1. Logs a `session_end` event to `project/logs/events.json`
2. Compares `project/rapports/problems/` against `.rapport_manifest.json` (skipping `*.IGNORE.md` files)
   - If new rapports found: writes a `rapport_review` trigger to `scrum_triggers.jsonl`
3. Always writes a `status_review` trigger for the next Scrum Master session
4. If `.session_handoff.json` exists in the queue: forwards the handoff to the developer trigger queue

This ensures the Scrum Master always has an up-to-date view of the project when it starts the next session.

---

### `hooks/distribute-changes.sh`

Distributes workflow files to all consumer projects registered in `.jenga_paths`.

```bash
.agents/hooks/distribute-changes.sh --dry-run   # preview without writing
.agents/hooks/distribute-changes.sh             # apply
.agents/hooks/distribute-changes.sh --force     # skip version check
```

---

## Directory Structure

Per `CLAUDE.md`'s Source of Truth rule, `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` at the **repo root** are canonical — this is where every feature is created and edited. `.agents/` and `.claude/` are generated build outputs (populated by `j:self-sync` in this monorepo, or by the npm package's `postinstall` hook in a consumer project) and are never hand-edited.

```
skills/                    ← Canonical skill source — invoke with j:<name> (see CLAUDE.md)
├── brainstorm/
├── btw/
├── clearify/               (alias: wtf)
├── close-story/
├── commit/
├── continue/
├── convert/
├── deep-dive/
├── dev-done/
├── distribute/
├── do/
├── doc/
├── doc-sync/
├── dooo/
├── error/
├── evaluate/
├── examplify/
├── help/
├── idea/
├── improve/
├── init/
├── j-init/                 (Copilot-collision-safe alias of init)
├── jbp/
├── jenga/
├── jenga-permission-level/
├── lgtm/
├── mirror-public/
├── pi-plan/
├── proceed/
├── publish/
├── reconcile/
├── reconcile-origin/
├── redo/
├── route/
├── self-sync/
├── skillify/
├── spinoff/
├── status/
├── strategy/
├── todo/
├── train/
├── uncharted/
└── wtf/                    (alias: clearify)

agents/
├── ai_engineer.md
├── developer.md
├── scrum-master.md
├── scrutiny-agent.md
├── solution-assessor.md
└── tester.md

hooks/
├── on_session_end.sh        ← SessionEnd hook (see above)
├── copilot_session_end.sh   ← Copilot-equivalent session-end handling
├── prompt_router.sh
├── prompt_router_helper.js
├── session_end_helper.js
└── session_end_watcher.sh

scripts/                   ← Shell/JS tooling backing skills, CI, and board operations
├── validate-board.sh        ← Board schema/frontmatter validation
├── with-lock.sh             ← Advisory file-lock wrapper for concurrent board writes
├── write-context-digest.sh  ← Writes resolved_context digests (see Agent Communication Contract)
├── postinstall.js           ← npm install hook — mirrors skills/ + agents/ into .claude/ + .agents/
└── ...                      ← see the directory for the full list (board ops, CI, permission tooling)

templates/
├── SCRUM_BOARD_SCHEMA.md
├── PROBLEM_RAPPORT_TEMPLATE.md
├── EXECUTION_PLAN_TEMPLATE.md
├── EXECUTION_SUMMARY_TEMPLATE.md
├── USER_INSTRUCTIONS_TEMPLATE.md
├── CHANGELOG_TEMPLATE.md
├── JENGA_CONFIG_TEMPLATE.json
├── SKILL.md               ← Legacy/simple skill scaffold (predates SKILL_TEMPLATE.md)
├── SKILL_TEMPLATE.md
├── agent-context.md.tpl
├── copilot-instructions.md.tpl
└── permission-levels/       ← level-1-locked.json … level-5-unrestricted.json (see j:jenga-permission-level)

.agents/ and .claude/      ← Generated mirrors — never hand-edited.
                              In this monorepo: refreshed by j:self-sync.
                              In a consumer project: `npm install @jenga-ai/agent` copies only
                              skills/ and agents/ here; hooks/, scripts/, and templates/ are
                              sourced live from node_modules/@jenga-ai/agent/ at runtime.

project/                   ← Created by j:init inside your software project
├── board/
│   ├── epics/             ← E##_<slug>.md
│   ├── stories/           ← E##_S##_<slug>.md
│   └── tasks/             ← E##_S##_T##_<slug>.md
├── configs/
│   ├── workflow.json      ← Shared constants (statuses, paths, agents)
│   └── test-config.json   ← Test tool stack (owned by Tester, user-approved)
├── data/
│   └── baselines.json     ← Analytics baselines (owned by Tester)
├── documentation/
│   ├── plans/             ← Pre-execution plans by Developer
│   └── summaries/         ← Post-execution summaries by Developer
├── ideas.md                ← Lightweight idea log (j:idea)
├── instructions/          ← User-action-prerequisite instructions (Developer-written)
├── queue/
│   ├── scrum_triggers.jsonl
│   ├── developer_triggers.jsonl
│   ├── tester_triggers.jsonl
│   ├── context/            ← resolved_context digests (see Agent Communication Contract)
│   ├── handoffs/           ← Session-boundary handoff files
│   └── project_summary_updates.jsonl
├── rapports/
│   ├── problems/          ← Problem rapports (Developer + Tester)
│   └── analysis/          ← Analysis rapports (Tester)
├── logs/
│   └── events.json        ← Append-only inter-agent event log
└── PROJECT_SUMMARY.md     ← Project source of truth (owned by Scrum Master)

CHANGELOG.md                ← Created by j:init at the project's repo root; maintained by j:publish
```

---

## Agent Communication Contract

Every call between agents must include a **sender object**. This is the typed contract that carries context across boundaries.

```json
{
  "sender": {
    "agent": "<scrum-master | developer | tester | orchestrator>",
    "session_id": "<session id from Claude Code>",
    "task_id": "<E##_S##_T##>",
    "story_id": "<E##_S##>",
    "epic_id": "<E##>",
    "date": "<ISO 8601 UTC timestamp>",
    "paths": ["<commit SHA 1>", "<commit SHA 2>"],
    "worktree": "<absolute path to task worktree>",
    "resolved_context": "<optional: path to a digest file under project/queue/context/>"
  }
}
```

**Rules:**
- Every agent logs every incoming sender object to `project/logs/events.json` as its **first action**
- The Tester rejects any call with missing required fields (responds with `"error"`)
- The `paths` array contains commit SHAs from the Developer's commits for this task
- The `worktree` field is the absolute path to the isolated git worktree created by the Developer
- The `resolved_context` field is optional: a size-capped digest (under ~100 lines/a few hundred tokens) of what the sending agent already resolved — relevant schema fields, skill precedent, prior decisions — written via `scripts/write-context-digest.sh` to a unique file under `project/queue/context/`. It's a starting point only, never a restriction — the receiving agent may still read full source files when the digest doesn't cover what it needs.

**Required fields by agent:**

| Field | Scrum Master | Developer | Tester |
|---|---|---|---|
| `agent` | ✅ | ✅ | ✅ |
| `session_id` | ✅ | ✅ | ✅ |
| `task_id` | ✅ | ✅ | ✅ |
| `story_id` | ✅ | ✅ | ✅ |
| `epic_id` | ✅ | ✅ | ✅ |
| `date` | ✅ | ✅ | ✅ |
| `paths` (commit SHAs) | ❌ | ✅ | ✅ |
| `worktree` | ❌ | ✅ | ✅ |
| `resolved_context` (optional) | ✅ | ✅ | ❌ |

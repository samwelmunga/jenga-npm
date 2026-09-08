---
layout: page
title: Skills Reference
permalink: /skills.html
---


Skills are slash commands stored in `.agents/skills/<name>/SKILL.md`. Invoke them with `/<name>` in any Claude Code session. Each skill's SKILL.md defines its behaviour, and optionally its `prefered_agent` (the sub-agent it delegates to).

---

### Setup & Planning

---

#### `/init`

**Description:** Initialize a new project with the standard directory structure, `PROJECT_SUMMARY.md`, `workflow.json`, git repo, and gitignore.

**When to use:** At the start of a new project — run this first, before anything else.

**What it creates:**
- `project/board/epics|stories|tasks/`
- `project/configs/workflow.json`
- `project/queue/`, `project/logs/`, `project/rapports/`, `project/documentation/`
- Initial `.gitignore` and first git commit

**Example:**
```
/init
→ Created project/ directory structure
→ Created project/configs/workflow.json
→ Created project/PROJECT_SUMMARY.md (stub)
→ git init + initial commit: "chore: init jenga project structure"
```

---

#### `/jbp`

**Description:** Scaffold the project using the [JengaBasePlate](https://github.com/samwelmunga/JengaBasePlate.git) boilerplate.

**When to use:** When you want a full project starter (not just the workflow scaffold). JBP includes opinionated structure for apps built with Jenga AI from the start.

**Example:**
```
/jbp
→ Clones JengaBasePlate into current directory
→ Installs dependencies
→ Runs /init automatically
```

---

#### `/jenga`

**Description:** Interactive-by-default board orchestrator with a fully automated escape hatch. Bare `/jenga` renders a picker and confirmation tree before scoping the run; `/jenga <ids>` resolves an explicit fuzzy-ID scope and confirms it; `/jenga *` reproduces the original zero-prompt behavior — decomposing any unbroken Epics into Stories, any unbroken Stories into Tasks, queuing all unqueued Tasks into `todo.md`, then executing every eligible item with no user prompts — until the board is fully started.

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
→ Starts executing: /do on T01, T02, T03...
```

---

#### `/pi-plan`

**Description:** Define or expand project Epics in `PROJECT_SUMMARY.md`. Use at the start of a project to establish its foundation, or whenever adding major new features.

**When to use:** When starting a new project, or when the user wants to plan a significant new area of work (new epic). Triggers on phrases like "new feature area", "big change", "expand the project".

**Delegates to:** Scrum Master

**Example:**
```
/pi-plan
Scrum Master: "Tell me about the project. What are the major goals?"
You: "It's a habit tracker with social sharing and analytics"
→ Creates E01: Core Habit Tracking
→ Creates E02: Social Sharing
→ Creates E03: Analytics Dashboard
→ Writes all three to PROJECT_SUMMARY.md
```

---

#### `/brainstorm`

**Description:** Focused planning session with the Scrum Master before committing anything to the board. Explores, challenges, and refines ideas in dialogue.

**When to use:** Before you know exactly what you want to build. The Scrum Master will ask pointed questions, surface assumptions, and propose board mappings — but nothing is written until you say so.

**Delegates to:** Scrum Master (Brainstorm Mode)

**Example:**
```
/brainstorm
"I want to add notifications to the app"

Scrum Master: "Which users receive notifications and for what events?"
You: "Users get notified when a friend completes a shared habit"
Scrum Master: "That touches E02 (Social Sharing). Should this be a new story
  under E02, or does it warrant its own epic if push + email + in-app are all needed?"
...
→ After agreement: "Ready to commit? → E02_S04: Habit Completion Notifications"
```

---

#### `/deep-dive`

**Description:** Multi-phase investigation workflow. Orchestrates information gathering, brainstorming, scrutiny, and solution assessment to produce a refined output document.

**When to use:** When a request needs thorough analysis before committing to a plan. Trigger phrases: "deep dive", "investigate thoroughly", "think this through properly", "analyze this in depth".

**Delegates to:** Scrum Master

**Phases:**
1. **Gather** — collects all available information about the topic
2. **Brainstorm** — generates and explores options interactively
3. **Scrutinise** — challenges assumptions, surfaces risks
4. **Assess** — evaluates options and produces a recommendation

**Example:**
```
/deep-dive on our auth strategy before we build it

Phase 1 — Scrum Master gathers: existing auth code, tech stack, threat model
Phase 2 — Brainstorms: JWT vs sessions vs OAuth, tradeoffs per use case
Phase 3 — Scrutinises: "JWT revocation is the riskiest assumption here"
Phase 4 — Produces: docs/auth-strategy-analysis.md with recommendation
```

---

#### `/todo`

**Description:** Add missions to `project/todo.md`, optionally linking them to epics and stories. Loops until done, then optionally executes the list.

**When to use:** When you have specific features or tasks to add and want them tracked on the board.

**Delegates to:** Scrum Master

**Example:**
```
/todo
"Add rate limiting to the API"
→ Links to E02_S03 (or creates new story if none fits)
→ Writes to project/todo.md: E02_S03_T01
"Add request logging middleware"
→ Links to E02_S03_T02
Done. Run /do now? → Yes
```

---

#### `/btw`

**Description:** Capture a new mission mid-flow. Fits it into the Epic/Story structure and lets you choose to implement now or defer.

**When to use:** When you think of something important while working on something else and don't want to lose the idea but also don't want to derail your current work.

**Delegates to:** Scrum Master

**Example:**
```
(While implementing auth)
/btw add a "remember me" checkbox to the login form
→ Scrum Master: "That fits under E01_S03 (Login UI). Add as T04?"
→ You: "Yes, defer it"
→ Written to board as E01_S03_T04, status: Pending
→ Returns to current task
```

---

#### `/spinoff`

**Description:** Capture a diverging topic mid-conversation. Collects context, optionally runs `/brainstorm` for prerequisites, saves a `/todo` entry, and returns focus to the primary thread.

**When to use:** When the conversation drifts to a new topic and you want to preserve both threads without losing context.

**Delegates to:** Scrum Master

**Example:**
```
(Mid-session on rate limiting)
You: "Oh, we should also think about caching strategy"
/spinoff
→ Scrum Master: "Captured: 'Evaluate caching strategy — Redis vs in-memory,
  touched on during rate limiting discussion'. Want to /brainstorm prereqs?"
→ Saved to todo.md
→ "Returning to rate limiting..."
```

---

### Execution

---

#### `/do`

**Description:** Execute tasks from the scrum board. Reads from `project/todo.md`, resolves each entry to its full board context, and drives the Developer agent through implementation with the correct sender object and communication contract.

**When to use:** When you're ready to implement. The main execution skill.

**Delegates to:** Developer

**Example:**
```
/do
→ Reads todo.md: E01_S02_T01-jwt-middleware, E01_S02_T02-refresh-tokens
→ You select: E01_S02_T01
→ Builds sender object with task/story/epic IDs
→ Invokes Developer agent
→ Developer implements, Tester validates, board status updated
```

---

#### `/dooo`

**Description:** Parallel execution orchestrator. Calls `/do` to start implementations via sub-agents, then loops back to identify and offer parallelisable tasks until the user selects "Done".

**When to use:** When multiple independent tasks are ready and you want to run them simultaneously to save time.

**Delegates to:** Scrum Master (orchestration), Developer (per task)

**Example:**
```
/dooo
→ Starts E01_S02_T01 as background sub-agent
→ Identifies E02_S01_T01 as parallelisable (no dependencies on T01)
→ "Start E02_S01_T01 in parallel?"
→ Yes → Starts second sub-agent
→ Both run simultaneously
→ Board updated as each completes
```

---

#### `/redo`

**Description:** Rework a previous implementation by commit SHA or Epic/Story number. Includes scope assessment, plan, and doc updates.

**When to use:** When previously completed work needs to be revisited — incorrect implementation, changed requirements, or a bug found post-release.

**Delegates to:** Scrum Master (scope assessment), Developer (implementation)

**Example:**
```
/redo E01_S02 — auth tokens aren't being invalidated on logout
→ Scrum Master: "E01_S02 was marked Passed on 2026-06-01.
  Scope: T01 (JWT) and T02 (refresh tokens) both need review.
  Reason: logout doesn't call token blacklist. Creating E01_S02_T04."
→ Developer re-implements, Tester re-validates
→ PROJECT_SUMMARY.md updated to note the fix
```

---

#### `/error`

**Description:** Guided troubleshooting flow that gathers context about an error — where it occurs, what was attempted, what went wrong, and what was expected.

**When to use:** When something is broken and you need structured help diagnosing it.

**Delegates to:** Tester

**What it captures:**
- Where the error occurs (file, function, endpoint)
- What action triggered it
- The actual error output
- The expected behaviour

**Example:**
```
/error
"500 on POST /api/auth/login"
→ Tester: "What's the stack trace?"
→ You: [paste]
→ Tester: "The issue is in token-service.ts line 42 — bcrypt.compare()
  is being called with undefined salt rounds. Likely missing env var."
→ Creates task E01_S02_T05 "Fix bcrypt config on login endpoint"
```

---

#### `/train`

**Description:** Scaffold and run ML training jobs. Use `new <type> <job-name>` to scaffold from a template, or `run <job-dir>` to execute the validate → train pipeline.

**When to use:** When working on machine learning components within a Jenga AI project.

**Subcommands:**
- `/train new <type> <job-name>` — scaffold a new job from a template (`classifiers`, `transformers`, `nlp`)
- `/train run <job-dir>` — execute the two-phase pre-flight → smoke test → full train pipeline

**Example:**
```
/train new classifiers sentiment-model
→ Copies .training/template/classifiers/ to jobs/sentiment-model/
→ "✅ Scaffolded job 'sentiment-model' from template 'classifiers'"

/train run jobs/sentiment-model
→ Phase 1: validates config and data paths
→ Phase 2: runs smoke test (small batch)
→ Full train: executes start.sh
```

---

### Status & Review

---

#### `/status`

**Description:** Print a human-readable summary of the entire scrum board — all epics, stories, and tasks with their statuses — plus any open rapports and unprocessed queue triggers.

**When to use:** Any time you want a quick overview without reading raw board files.

**Example:**
```
/status

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

#### `/continue`

**Description:** Check project status across `PROJECT_SUMMARY.md`, epics, and stories to determine what should be done next. Reports "All done!" if everything is complete.

**When to use:** At the start of a session when you want the system to orient you and pick up where you left off.

**Example:**
```
/continue
→ Reads PROJECT_SUMMARY.md and board state
→ "E01_S02 is In Progress. T02 (token rotation) is Pending.
   Recommended next: /do E01_S02_T02"
```

---

#### `/proceed`

**Description:** Review project progress by checking epics and stories, optionally consulting `PROJECT_SUMMARY.md` and `WARP.md`, then continue executing the project plan.

**When to use:** Similar to `/continue` but more assertive — it reviews progress and immediately resumes execution rather than just recommending.

**Delegates to:** Scrum Master

**Example:**
```
/proceed
→ Scrum Master reviews board
→ "E01 is 60% complete. S03 (Logout) is unstarted but has no blockers.
   Starting E01_S03 now..."
→ Invokes /do
```

---

#### `/reconcile`

**Description:** Reconcile the scrum board with actual implementation state. Cross-checks every task's board status against git history and worktrees, merges orphaned worktree branches, demotes unimplemented "Done" items, and promotes secretly-implemented items.

**When to use:** When the board feels out of sync — after a big merge session, when tasks were completed outside the normal workflow, or when `todo.md` has grown stale.

**Delegates to:** Scrum Master

**What it checks:**
- Every task status vs. git history (commit messages with task IDs)
- Orphaned worktrees that were never merged
- `todo.md` entries that are already Done on the board

**Example:**
```
/reconcile
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

### Committing & Maintenance

---

#### `/commit`

**Description:** Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries.

**When to use:** After completing any EST work item — when you want a structured, trackable commit message.

**Naming convention:** `epic(E##): <title>`, `story(E##_S##): <title>`, `task(E##_S##_T##): <title>`

**Example:**
```
/commit E01_S02_T01
→ "task(E01_S02_T01): add JWT validation middleware"
→ Staged: src/middleware/jwt.ts, tests/middleware/jwt.test.ts
→ git commit -m "task(E01_S02_T01): add JWT validation middleware"
```

---

#### `/lgtm`

**Description:** Approve and commit the current work, then continue to the next task. Shortcut that chains `/commit` followed by `/continue`.

**When to use:** When you've reviewed the work and want to quickly commit and move on.

**Example:**
```
/lgtm
→ /commit (creates EST commit)
→ /continue (identifies next task)
→ "Next: E01_S02_T02 — Refresh token rotation. Start? [yes/no]"
```

---

#### `/distribute`

**Description:** Propagate the latest workflow changes to all consumer projects registered in `.jenga_paths`.

**What it is:** `/distribute` treats this repository as the master copy of your Jenga AI workflow and each registered consumer project as a versioned snapshot of that workflow. You maintain one shared set of skills, agents, hooks, scripts, and supporting files here, then `/distribute` copies them into each consumer project's configured `target_dir`, updates projects that are behind, and protects projects that are already ahead on `workflow_version`.

**Setup**

1. Create `.jenga_paths` in the repo root, ideally by copying `.jenga_paths.example`, then list one absolute directory path per line for the places where your consumer projects live. Each listed path is scanned up to 2 levels deep for directories containing `jenga.config.json`.
2. In each consumer project, add a `jenga.config.json` with at least:

   ```json
   {
     "target_dir": ".agents",
     "workflow_version": "0.0.0"
   }
   ```

   `target_dir` is the relative path inside the consumer project where the workflow files will be copied, and `workflow_version` is used to decide whether a project should be updated, skipped, or warned about.
3. Optionally create `.jenga_ignore` in a consumer project's root to list files or directories, relative to `target_dir`, that should be excluded from updates.

**When to use:** Use `patch`, `minor`, or `major` after making workflow changes that should become a versioned upgrade for every registered consumer; these releases bump the workflow version in `project.config.json` and distribute to all consumers. Use `amend` when quietly onboarding a new consumer project or fixing files missed in a previous release; it keeps the current version unchanged and only updates out-of-date or brand-new projects. Start with the dry-run preview the skill prompts for so you can inspect exactly what will change before pushing it out.

**Release types:**
- `major` / `minor` / `patch` — bumps version in `jenga.config.json`, distributes to all consumers
- `amend` — no version bump; distributes only to out-of-date consumers

**Example:**
```
/distribute
Release type? → minor
→ Bumped version: 1.2.0 → 1.3.0
→ Scanning .jenga_paths...
→ Found 3 consumer projects
→ Syncing my-app-1: ✅ (updated from 1.2.0 to 1.3.0)
→ Syncing my-app-2: ✅ (updated from 1.1.0 to 1.3.0)
→ Syncing my-app-3: ⚠️ skipped (workflow_version 1.4.0 is ahead)
```

---

#### `/doc`

**Description:** Generate or update a documentation file by resolving a target path to a clear documentation objective before writing.

**When to use:** When you want to create or refresh a specific doc file — "update the docs", "write docs for X", "the README is stale", "generate documentation for X". Pass an optional target path (e.g. `/doc docs/API.md`); omit it to default to `README.md`.

**Example:**
```
/doc docs/CLI.md
→ Resolved target: docs/CLI.md — objective: CLI usage guide
→ Reading existing docs/CLI.md...
→ Gathering evidence: package.json, board items, skill metadata
→ Regenerating docs/CLI.md with current commands and flags
→ Written: docs/CLI.md ✅
```

---

#### `/doc-sync`

**Description:** Compare the current state of a project with its documentation and update any documentation that is stale, incomplete, or missing.

**When to use:** When documentation may have drifted from the implementation, or after a big implementation sprint.

**Arguments:**
- `update: <path>` — specific doc file(s) to check and update
- `source: <path>` — source file(s) to diff against
- `exclude: <pattern>` — paths to skip
- `minify: true` — shrink verbose docs to essential content only

**Example:**
```
/doc-sync update: docs/api.md source: src/routes/
→ Reading src/routes/auth.ts, src/routes/users.ts, src/routes/habits.ts
→ Comparing against docs/api.md
→ Found: 3 new endpoints not documented
→ Found: 1 deprecated endpoint still documented
→ Updated docs/api.md ✅
```

---

#### `/skillify`

**Description:** Refactor one or more existing skills into a cleaner structure — extracting hardcoded content into asset files, moving deterministic steps into scripts, and simplifying the skill body.

**When to use:** When a skill has grown large, contains hardcoded templates, or has multi-step logic that would be more reliable as a shell script.

**What it does:**
- Extracts hardcoded file content (JSON, Markdown, config) into `assets/` templates
- Extracts directory lists into `assets/` reference files
- Moves deterministic sequences into `scripts/` bash scripts
- Rewrites the skill body to delegate to those assets and scripts

**Example:**
```
/skillify init
→ Reading .agents/skills/init/SKILL.md
→ Found: 40-line hardcoded directory list
→ Extracted to: .agents/skills/init/assets/directories.txt
→ Found: inline workflow.json template
→ Extracted to: .agents/skills/init/assets/workflow.json.template
→ Rewrote SKILL.md: 80 lines → 22 lines
```

---

#### `/route`

**Description:** Intelligently route a prompt to the best-matching skill. Reads available skills, matches semantically and by keyword, enriches the prompt with board context, then invokes the matched skill.

**When to use:** When you know what you want to do but don't know which skill handles it — or just want to describe your intent naturally.

**Example:**
```
/route I want to think through the caching approach before we build it
→ Matches: /deep-dive (keywords: "think through", "analyze")
→ Invoking /deep-dive with enriched context...

/route something broke in the auth flow
→ Matches: /error (keywords: "broke", "error")
→ Invoking /error...
```

---

#### `/improve`

**Description:** Analyse a codebase and produce a structured improvement plan toward a defined goal.

**When to use:** When you want a systematic review of what can be improved in a specific area (performance, maintainability, test coverage, etc.).

**Example:**
```
/improve improve test coverage in the auth module
→ Goal confirmed: increase test coverage in src/auth/
→ Scanning: 12 files, current coverage 54%
→ Improvement plan:
  1. Add unit tests for token-service.ts (0% coverage, high risk)
  2. Add integration tests for /auth/refresh (no tests)
  3. Parameterise bcrypt test cases to cover edge inputs
→ Creates task: E01_S06_T01 "Improve auth module test coverage"
```

---

#### `/evaluate`

**Description:** Analyse example files against a target goal and produce a structured evaluation rapport.

**When to use:** When you have example outputs or implementations and want them measured against a defined quality goal.

**Inputs:** A filled `eval_invokation_template.yml` with a `goal` and a list of `paths` to example files.

**Example:**
```
/evaluate
goal: "API responses should follow RFC 7807 error format"
paths: [examples/auth-error.json, examples/rate-limit-error.json]

→ Evaluating auth-error.json: missing 'instance' field — partial compliance
→ Evaluating rate-limit-error.json: compliant ✅
→ Rapport written to: project/rapports/analysis/eval-rfc7807-2026-07-09.md
```

---

#### `/examplify`

**Description:** Explain a concept, feature, use case, or pattern with grounded examples — what it is, why it exists, how it works, when to use it, and a concrete example.

**When to use:** When you want to understand something (a pattern, a Jenga AI concept, a piece of code) without digging through docs.

**Output:** Saves an explanation to `project/documentation/examples/`.

**Example:**
```
/examplify sender objects in Jenga AI

What it is: A typed JSON contract passed between every agent call
Why it exists: Prevents agents from operating on stale or ambiguous context
How it works: Contains task_id, story_id, epic_id, commit SHAs, worktree path
When to use: Every inter-agent call — no exceptions
Example: [before/after showing agent call with and without sender object]
→ Saved to: project/documentation/examples/sender-objects.md
```

---

#### `/help`

**Description:** List all available skills with a short description of each.

**When to use:** When you want a quick overview of what skills are available in the current project.

**Example:**
```
/help
→ Available skills:
  /brainstorm — Focused planning session with Scrum Master
  /btw        — Capture a mid-flow idea
  /commit     — Commit using EST naming convention
  ...
```

---

#### `/customize-cloud-agent`

**Description:** Configure the Copilot cloud agent environment — `copilot-setup-steps.yml`, preinstalled tools and dependencies, runners, and settings.

**When to use:** When you need to configure the GitHub Copilot coding agent's cloud environment for your project.

**What it configures:**
- `copilot-setup-steps.yml` — environment setup steps that run before the agent starts
- Pre-installed tools and dependencies
- Runner configuration
- Agent settings and permissions

**Example:**
```
/customize-cloud-agent
→ "What tools should be preinstalled?"
→ Node.js 20, pnpm, PostgreSQL client
→ Generates .github/copilot-setup-steps.yml:
  - uses: actions/setup-node@v4
    with: { node-version: '20' }
  - run: npm install -g pnpm
  - run: apt-get install -y postgresql-client
```

---


# JengaAgent

**A structured multi-agent development workflow built on [Claude Code](https://docs.anthropic.com/en/docs/claude-code).** Three specialised AI agents — Scrum Master, Developer, and Tester — collaborate through a shared scrum board, an event-driven trigger queue, and 28 slash-command skills to take a project from idea to verified, committed code — across as many sessions as it takes.

> 📖 **Full reference:** [project/.wiki/documentation.md](project/.wiki/documentation.md) | [Intro Guide](project/.wiki/intro-guide.md)

---

## The Problem It Solves

Without a framework like JengaAgent, AI-assisted development has serious structural weaknesses:

| Problem | Reality |
|---|---|
| **AI has no session memory** | Each Claude Code session starts from scratch — no awareness of open tasks, past decisions, or what was already tested |
| **No role separation** | The AI writes *and* "tests" code in the same context, leading to hallucinated test results and self-affirming bugs |
| **No structured planning** | Work happens ad-hoc — no Epic → Story → Task hierarchy to organise or track progress |
| **No handoff protocol** | Switching from implementing to testing means manually re-explaining context every time |
| **No audit trail** | You can't replay *why* something was built, by which agent, based on which task |
| **Sessions just end** | Work-in-progress, unresolved problems, and incomplete stories silently vanish |

JengaAgent solves each of these with structure: persistent board state, strict agent roles, typed inter-agent contracts, and session-end hooks that preserve context between sessions.

---

## Examples

### Before / After

**Without JengaAgent:**
```
You: "Add user authentication"
Claude: [writes auth code, declares it works, session ends]

Next session:
You: "What's the status of auth?"
Claude: "I don't have context from the previous session."
```

**With JengaAgent:**
```
/todo → "Add user authentication" → linked to E01_S02
/do   → Developer creates worktree E01_S02_T01-auth
      → implements, commits at milestones
      → hands off to Tester with sender object

Tester → runs tests, updates board status to ✅ Passed
SessionEnd → writes status_review trigger to queue

Next session:
/status → "E01_S02 ✅ complete — E01_S03 pending"
```

---

### Real-World Scenario: Building a Feature Across Sessions

Imagine you're building a REST API with auth, rate limiting, and an admin dashboard. Each is a separate Epic. Here's how JengaAgent handles that across multiple days:

**Planning**
```
/init          → scaffolds project/, board/, workflow.json
/pi-plan       → Scrum Master helps shape the auth epic into stories
/todo          → "Add JWT auth" → E01_S01, "Add refresh tokens" → E01_S02
```

**Implementation**
```
/do            → Developer picks up E01_S01_T01-jwt-middleware
               → creates isolated worktree, implements, commits
               → Tester validates, marks Passed, triggers rollup
/status        → E01_S01 ✅, E01_S02 Pending
/continue      → picks up E01_S02 automatically
/proceed       → resumes project plan from current board state
```

**New idea mid-session**
```
You: "Actually, let's also add API rate limiting while we're at it"
/btw           → captures "rate limiting" as E02 without losing E01 context
               → returns focus to E01_S02
/spinoff       → captures a diverging topic mid-conversation, saves as /todo
               → returns focus to primary thread
```

**Parallel work**
```
/jenga         → fully automated orchestrator: decomposes Epics → Stories → Tasks → executes
/dooo          → orchestrates E01_S02 and E02_S01 in parallel sub-agents
/reconcile     → syncs board with actual git history after parallel merges
```

The board, the audit log, and `PROJECT_SUMMARY.md` survive every session boundary. You never re-explain context.

---

## How It Works

```
/init → /pi-plan → /todo → /do
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

## Agents

| Agent | Role | Owns |
|---|---|---|
| **Scrum Master** | Plans, breaks down work, handles rollups and queue processing | `project/PROJECT_SUMMARY.md`, epic status |
| **Developer** | Implements tasks in isolated git worktrees, commits at milestones | Code, worktrees, commit history |
| **Tester** | Validates implementation, updates task/story status, writes rapports | Task/story status, test config, baselines |

Each agent is defined in `.agents/agents/`. They communicate exclusively through typed **sender objects** — JSON contracts that include the task ID, commit SHAs, and worktree path. Every incoming sender object is logged to `project/logs/events.json` before any work begins.

---

## Getting Started

**Prerequisites:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured.

**Install from npm:**
```sh
npm install -g jenga-agent
```

Or clone directly:

1. **Clone or copy this repo** into your project's `.agents/` directory (or wherever you keep project tooling).
2. **Run `/init`** — scaffolds `project/`, creates `workflow.json`, `PROJECT_SUMMARY.md`, and makes an initial commit.
3. **Run `/pi-plan`** — define your project goals and initial epics.
4. **Run `/todo`** — describe features to implement; they're linked to the board automatically.
5. **Run `/do`** — picks the first task and drives the full implement → test → commit loop.

Run `/status` at any time to see where the project stands.

---

## Skills (Slash Commands)

Skills live in `.agents/skills/<name>/SKILL.md`. Invoke with `/<name>` in any Claude Code session.

### Setup & Planning

| Command | Description |
|---|---|
| `/init` | Scaffold project directories, `workflow.json`, `PROJECT_SUMMARY.md`, initial git commit |
| `/jbp` | Scaffold using the [JengaBasePlate](https://github.com/samwelmunga/JengaBasePlate.git) boilerplate |
| `/jenga` | Fully automated board orchestrator — decomposes Epics → Stories → Tasks → executes |
| `/pi-plan` | Define or expand Epics in `PROJECT_SUMMARY.md` — use at start or when adding major new work |
| `/brainstorm` | Focused planning session with the Scrum Master before committing anything to the board |
| `/deep-dive` | Multi-phase investigation — gathers info, brainstorms, scrutinises, and produces a refined output |
| `/todo` | Add missions to `project/todo.md` linked to epics and stories |
| `/btw` | Capture a mid-flow idea, classify it into epic/story structure, implement now or defer |
| `/spinoff` | Capture a diverging topic without losing your current thread |

### Execution

| Command | Description |
|---|---|
| `/do` | Execute tasks from the scrum board, drives the Developer agent through the full loop |
| `/dooo` | Parallel execution orchestrator — runs multiple tasks simultaneously via sub-agents |
| `/redo` | Rework a previous implementation by commit SHA or Epic/Story number |
| `/error` | Guided troubleshooting — gathers context, investigates, and drives a fix |
| `/train` | Scaffold and run ML training jobs (new job from template or run existing) |

### Status & Review

| Command | Description |
|---|---|
| `/status` | Print a full scrum board overview — epics, stories, tasks, rapports, queue depth |
| `/continue` | Check project status and pick up the next incomplete item |
| `/proceed` | Review progress and resume executing the project plan |
| `/reconcile` | Sync the board with actual git history — fixes drift, merges orphaned worktrees |
| `/reconcile-origin` | Sync the current or specified branch with origin via rebase. Presents conflict reports with resolution options. |

### Committing & Maintenance

| Command | Description |
|---|---|
| `/commit` | Commit completed work using the EST naming convention |
| `/lgtm` | Approve current work, commit, and continue — chains `/commit` + `/continue` |
| `/distribute` | Propagate workflow changes to all registered consumer projects |
| `/doc` | Generate or update a documentation file from codebase evidence |
| `/doc-sync` | Compare project state with documentation and update stale docs |
| `/skillify` | Refactor a skill — extract assets, offload scripts, clean up the body |
| `/route` | Intelligently route a prompt to the best-matching skill |
| `/improve` | Analyse a codebase and produce a structured improvement plan |
| `/evaluate` | Analyse example files against a target goal and produce an evaluation rapport |
| `/examplify` | Explain a concept, feature, or pattern with grounded examples |
| `/help` | List all available skills with descriptions |
| `/customize-cloud-agent` | Configure the Copilot cloud agent environment (`copilot-setup-steps.yml`, preinstalls, runners) |

---

## Distributing the Workflow

JengaAgent can propagate its workflow files to other projects on your machine via `/distribute`.

1. **Register consumer projects** — place `jenga.config.json` at each consumer root (copy from `templates/JENGA_CONFIG_TEMPLATE.json`).
2. **Add search paths** — add absolute directory paths to `.jenga_paths` (one per line, git-ignored).
3. **Run `/distribute`** — choose `major`, `minor`, `patch`, or `amend` release type; the skill handles versioning and syncs all registered projects.

To exclude specific files per consumer project, add a `.jenga_ignore` at the consumer root (never overwritten by distribute).

---

## Directory Structure

```
.agents/                   ← Workflow root (place this in your project)
├── agents/
│   ├── scrum-master.md
│   ├── developer.md
│   └── tester.md
├── hooks/
│   ├── on_session_end.sh
│   └── distribute-changes.sh
├── mcp/
│   ├── help/
│   └── execute-ticket/
├── skills/
│   ├── brainstorm/
│   ├── btw/
│   ├── commit/
│   ├── continue/
│   ├── deep-dive/
│   ├── distribute/
│   ├── do/
│   ├── doc/
│   ├── doc-sync/
│   ├── dooo/
│   ├── error/
│   ├── evaluate/
│   ├── examplify/
│   ├── help/
│   ├── improve/
│   ├── init/
│   ├── pi-plan/
│   ├── jbp/
│   ├── jenga/
│   ├── lgtm/
│   ├── proceed/
│   ├── reconcile/
│   ├── redo/
│   ├── route/
│   ├── skillify/
│   ├── spinoff/
│   ├── status/
│   ├── todo/
│   └── train/
├── templates/
│   ├── SCRUM_BOARD_SCHEMA.md
│   ├── PROBLEM_RAPPORT_TEMPLATE.md
│   └── JENGA_CONFIG_TEMPLATE.json
├── settings.json
├── jenga.config.json       ← Workflow version source
├── .jenga_paths            ← Machine-local consumer paths (git-ignored)
└── RELEASE_NOTE.md

project/                   ← Created by /init inside your software project
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
├── queue/
│   ├── scrum_triggers.jsonl
│   ├── developer_triggers.jsonl
│   ├── tester_triggers.jsonl
│   └── project_summary_updates.jsonl
├── rapports/
│   ├── problems/          ← Problem rapports (Developer + Tester)
│   └── analysis/          ← Analysis rapports (Tester)
├── logs/
│   └── events.json        ← Append-only inter-agent event log
└── PROJECT_SUMMARY.md     ← Project source of truth (owned by Scrum Master)
```

---

## Agent Communication Contract

Every inter-agent call passes a typed **sender object**:

```json
{
  "sender": {
    "agent": "<scrum-master | developer | tester | orchestrator>",
    "session_id": "<session id>",
    "task_id": "<E##_S##_T##>",
    "story_id": "<E##_S##>",
    "epic_id": "<E##>",
    "date": "<ISO 8601 UTC>",
    "paths": ["<commit SHA>", "..."],
    "worktree": "<absolute path to worktree>"
  }
}
```

All agents log every incoming sender object to `project/logs/events.json` as their **first action** on every invocation.

---

## When to Use JengaAgent

**Use it when:**
- You're building a non-trivial project across multiple sessions
- You want reliable test separation — the Tester never trusts the Developer's self-assessment
- You need traceability — who did what, when, on which task
- You want to reuse and propagate your AI workflow across multiple projects

**You might not need it when:**
- You're doing a quick one-off script or single-session experiment
- Your project has no meaningful test surface

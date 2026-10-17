---
layout: page
title: Reference
permalink: /reference.html
---

## Full Reference Index

This page is the entry point into the full reference material, split across
several pages so nothing requires scrolling through one giant file:

- **[Skills Reference](skills.html)** — every skill, grouped by Setup &
  Planning, Execution, Status & Review, and Committing & Maintenance.
- **[Agents](agents.html)** — Scrum Master, Developer, Tester: roles,
  ownership, and responsibilities.
- **[Hooks](hooks.html)** — session lifecycle hooks and what they run.
- **[MCP Tools](mcp-tools.html)** — Model Context Protocol tools available
  in a Claude Code session.

The rest of this page covers the repo's directory structure and the
inter-agent communication contract (the typed "sender object" every agent
call carries).

---


Per `CLAUDE.md`'s Source of Truth rule, `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` at the **repo root** are canonical — this is where every feature is created and edited. `.agents/` and `.claude/` are generated build outputs (populated by `j.self-sync` in this monorepo, or by the npm package's `postinstall` hook in a consumer project) and are never hand-edited.

```
skills/                    ← Canonical skill source — invoke as j.<name> or /j-<name> (see CLAUDE.md)
├── index/                     (not a skill — no SKILL.md, not part of routing)
├── j-brainstorm/
├── j-break/
├── j-btw/
├── j-check-in/
├── j-clearify/                (alias: j-wtf)
├── j-close-story/
├── j-cloud-connect/
├── j-commit/
├── j-connect/
├── j-continue/
├── j-conventions/
├── j-convert/
├── j-dashboard/
├── j-dashboard-share/
├── j-deep-dive/
├── j-dev-done/
├── j-distribute/
├── j-do/
├── j-doc/
├── j-doc-sync/
├── j-dooo/
├── j-error/
├── j-evaluate/
├── j-examplify/
├── j-gitignore/
├── j-help/
├── j-idea/
├── j-improve/
├── j-init/
├── j-jbp/
├── j-lgtm/
├── j-mirror-public/
├── j-pi-plan/
├── j-playbook/
├── j-playbook-new/
├── j-proceed/
├── j-publish/
├── j-reconcile/
├── j-reconcile-origin/
├── j-redo/
├── j-self-sync/
├── j-skillify/
├── j-smoke-test/
├── j-spinoff/
├── j-status/
├── j-strategy/
├── j-test/
├── j-todo/
├── j-tools/
├── j-train/
├── j-uncharted/
├── j-wtf/                     (alias of j-clearify)
├── jenga/                     (permanent bare name — main skill)
├── jenga-config/              (permanent bare name — main skill)
└── jenga-permission-level/    (permanent bare name — main skill)

agents/
├── ai_engineer.md
├── developer.md
├── scrum-master.md
├── scrutiny-agent.md
├── solution-assessor.md
└── tester.md

hooks/
├── on_session_end.sh        ← SessionEnd hook (see above)
├── on_preflight_check.sh    ← PreToolUse pre-flight checklist hook (see above)
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

bin/
└── jenga.js                 ← The `jenga` CLI entry point (`jenga --help`)

lib/                       ← Code behind the CLI and the install/mirror pipeline
├── commands/                ← One module per `jenga` sub-command: init, attach, status,
│                              config, dashboard, doctor (alias: clean), start
├── config-schema.js         ← Schema `jenga config` validates every `set` against
├── mirror.js                ← Mirrors root-canonical dirs into .claude/ + .agents/
└── skill-allow-list.json    ← Generated allow-list of invocable skill identifiers

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
└── permission-levels/       ← level-1-locked.json … level-5-unrestricted.json (see j.jenga-permission-level)

.agents/ and .claude/      ← Generated mirrors — never hand-edited.
                              In this monorepo: refreshed by j.self-sync.
                              In a consumer project: `npm install @jenga-ai/agent` copies only
                              skills/ and agents/ here; hooks/, scripts/, and templates/ are
                              sourced live from node_modules/@jenga-ai/agent/ at runtime.

project/                   ← Created by j.init inside your software project
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
├── ideas.md                ← Lightweight idea log (j.idea)
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

CHANGELOG.md                ← Created by j.init at the project's repo root; maintained by j.publish
```

**Not everything runs through an agent.** `bin/jenga.js` and `lib/commands/` implement the `jenga` CLI — `jenga config`, `jenga doctor`, `jenga dashboard`, `jenga init`, `jenga attach`, `jenga status`. These are deterministic terminal commands with no model call and no token cost; see the [`/jenga-config`](https://samwelmunga.github.io/jenga-npm/skills.html) skill entry for the one that is also exposed in-session, and `project/configs/README.md` for the settings they edit.

---


---


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

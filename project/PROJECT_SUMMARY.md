# Project Summary

## Overview
JengaAgent is a meta-framework for agentic software development. It provides a suite of Claude-based AI agents (scrum-master, developer, tester, ai-engineer), a skill library, scripting infrastructure, and a project board system (epics/stories/tasks). It is designed to be installed into consumer projects to give them a structured agentic workflow.

## Architecture & Structure
- `skills/` — Markdown skill files invoked by the CLI (e.g. `/do`, `/distribute`, `/publish`, `/doc`)
- `project/board/` — Scrum board (epics, stories, tasks) tracked as Markdown files with frontmatter
- `project/queue/` — Inter-agent communication (triggers, handoff files, update proposals)
- `project/logs/` — Event log for agent activity
- `scripts/` — Shell scripts for validation, board operations, and CI hooks
- `templates/` — Schema files and agent scaffolding templates
- `agents/` — Agent definition files consumed by the CLI
- `hooks/` — Git hooks and session lifecycle hooks
- `jobs/` — ML training job scaffolds (used by `/train` skill)
- `/publish` skill — Configures and orchestrates release workflows; `publish.json` at project root stores target configs; `skills/publish/scripts/` contains `validate_config.sh`, `setup_wizard.sh`, `check_target_config.sh`; `skills/publish/assets/` contains the secrets guide used during setup.

## Distribution
JengaAgent supports two distribution paths:

**Public (npm):** JengaAgent is distributed as a public npm package (`jenga-agent`) via npmjs.com. Consumer projects install it with `npm install jenga-agent`; a postinstall hook copies `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` into the consumer project root. Publishing is handled entirely through the `/publish` skill's `npm` target type (added in E26). The version source is `package.json`; `latest` and `beta` dist-tags are supported, and the npm pipeline honours a `--dry-run` flag.

**Private (filesystem):** For projects that consume the private monorepo directly, the `/distribute` skill handles local filesystem distribution (restored in E31). The monorepo root holds `distribute.config.json` — a structured JSON registry of consuming project paths with `name`, `path`, and `active` fields, replacing the retired `.jenga_paths` plain-text file. Each consuming project holds a `jenga.config.json` tracking `version`, `last_distributed`, `source: "private"`, and `target_dir`. The skill owns the full version lifecycle: release type selection (`major`/`minor`/`patch`/`amend`), dry-run preview, `npm version` bump, file copy to `.agents/` and `.claude/` in each target (respecting per-project `.jenga_ignore`), atomic `jenga.config.json` update, and a git commit of the version bump. `/distribute` is independent of `/self-sync` and `/mirror-public`.

## Epics
- **E01** — Model Training Agentic Workflow
- **E02** — Agent Conversation Guardrails
- **E03** — Parallel Workflow Orchestration
- **E04** — Dataset Conversion Skill
- **E05** — Agent Dashboard API Layer
- **E06** — Agent Dashboard Board Tab
- **E07** — Agent Dashboard History Tab
- **E08** — Agent Dashboard Architecture Tab
- **E09** — Agent Dashboard CLI Interface
- **E10** — Script Infrastructure & Skill Refactor
- **E11** — Jenga Router
- **E12** — Claude Code Integration
- **E13** — Jenga CLI
- **E14** — Config & Skill Metadata
- **E15** — Multi-Project Router & Attach
- **E16** — Multi-Platform Agent Config Parity
- **E17** — Workflow Quality Enforcement *(In Progress)*
- **E18** — README & Documentation Overhaul
- **E19** — Train Skill Enhancement
- **E20** — Knowledge Graph
- **E21** — Clarify Skill
- **E22** — Publish Skill *(Passed)*
- **E23** — Human–Agent Handoff Protocol
- **E24** — `/doc` Document Synthesis Skill *(Passed)*
- **E25** — Board Index Substrate
- **E26** — NPM-Compatible Distribution *(Passed)*
- **E27** — Repo Self-Sync — Restore Root → .claude/.agents Mirror Automation
- **E28** — Public Mirror — One-Way Private → Public Repo Sync
- **E29** — npm Trusted Publishers CI Adapter
- **E30** — Strategy Brief Convention
- **E31** — Restore /distribute Skill — Private Filesystem Distribution *(Pending)*
- **E32** — Adaptive Execution Scope for /jenga + /do *(Pending)*

## Adaptive Execution Scope (E32)
Tasks carry two new frontmatter fields assigned by the scrum-master at breakdown: `execution_scope` (`task` | `story` | `inline` | `epic`) and `needs_docs` (boolean). These fields allow `/jenga` and `/do` to right-size execution footprint — routing tiny self-contained changes to `inline` (main-session, no subagent), bundling related tasks into a single developer context for `story` scope, and keeping full isolation for `task` scope. Thresholds (1-file/20-line for inline, 5-file for story) are stored in `project/configs/scope-thresholds.json` and read at runtime by both skills. `epic` scope requires explicit human approval (`epic_scope_approval: true`) and is never assigned autonomously by the scrum-master. Additional required fields: `scope_rationale` (measurable criterion), `jenga_assigned` (machine vs human assignment), and `override_justification` (required when `jenga_assigned: false`).

## Conventions
- Board items use `E##_S##_T##` naming convention
- Story format requires `## Acceptance Criteria` and `## Definition of Done` with `- [ ]` checkboxes
- Agent communication uses queue files in `project/queue/`
- All skills are Markdown files in `skills/` and are invoked via `/skill-name`

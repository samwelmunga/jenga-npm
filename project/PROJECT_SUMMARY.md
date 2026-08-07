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
JengaAgent is distributed as a public npm package (`jenga-agent`) via npmjs.com. Consumer projects install it with `npm install jenga-agent`; a postinstall hook copies `skills/`, `agents/`, `hooks/`, `scripts/`, and `templates/` into the consumer project root. Publishing is handled entirely through the `/publish` skill's `npm` target type (added in E26). The version source is `package.json`; `latest` and `beta` dist-tags are supported, and the npm pipeline honours a `--dry-run` flag. The legacy `/distribute` skill and `.jenga_paths` mechanism were retired in E26.

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

## Conventions
- Board items use `E##_S##_T##` naming convention
- Story format requires `## Acceptance Criteria` and `## Definition of Done` with `- [ ]` checkboxes
- Agent communication uses queue files in `project/queue/`
- All skills are Markdown files in `skills/` and are invoked via `/skill-name`

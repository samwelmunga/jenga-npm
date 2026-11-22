---
layout: home
title: Jenga AI
---

# Jenga AI Documentation

> **Heads-up**
>
> **Jenga version 5 is more likely to contain bugs and errors than version 4.** A broad overhaul of testing is under way, and several tester suites have been switched off temporarily while it runs. The first stable release, **Jenga version 6 (stable)**, is expected around **mid-December 2026**.
>
> Until then, please do these three things to avoid errors and bugs:
>
> 1. **Check that the postinstall script is allowed to run for Jenga.** Some package managers block install scripts by default.
> 2. **Run `jenga doctor` in your regular terminal.** It can help bring your project back in sync.
> 3. **Run `j.jenga-config` (also `/jenga-config`), choose the list mode, and check whether any settings are missing in your environment.**

Jenga AI is a meta-framework for agentic software development. It provides a
suite of Claude-based AI agents (scrum-master, developer, tester, ai-engineer),
a skill library, scripting infrastructure, and a project board system
(epics/stories/tasks). It is designed to be installed into consumer projects
to give them a structured agentic workflow.

This site is restructured from the project's existing
[wiki documentation](https://github.com/samwelmunga/JengaAgent/wiki) into a
navigable, multi-page reference — the wiki stays canonical and
`doc-sync`-maintained; this site is a presentation layer over the same
content. See `project/documentation/site-decisions.md` in this repo for the
full source-of-truth and tooling decision record.

## Where to go

- **[Getting Started](getting-started.html)** — the philosophy behind Jenga
  AI, the three pillars (role separation, board hierarchy, session
  continuity), your first 15 minutes, and common patterns.
- **[Concepts](concepts.html)** — role separation, board hierarchy, session
  continuity, your first feature, working across sessions, capturing
  mid-flow ideas, and parallel tasks, each as its own section.
- **[Reference](reference.html)** — the full reference index: links out to
  the [Skills Reference](skills.html), [Agents](agents.html), [Hooks](hooks.html),
  and [MCP Tools](mcp-tools.html) pages, plus the repo's directory structure
  and the inter-agent communication contract.
- **[Pre-Flight Checklists](preflight-checklists.html)** — authoring your own
  `project/configs/checklists.json`: item fields, the `block` / `confirm` /
  `advisory` enforcement levels, the `checklist.sh` commands and their exit
  codes.

> Getting Started, Concepts, Skills, Agents, Hooks, MCP Tools, and Reference
> are generated from `project/.wiki/*` by `scripts/build-pages-site.sh` — see
> that script's header comment for how to keep this site in sync when the
> wiki changes.

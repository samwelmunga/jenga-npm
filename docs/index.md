---
layout: home
title: Jenga AI
---

# Jenga AI Documentation

Jenga AI is a meta-framework for agentic software development. It provides a
suite of Claude-based AI agents (scrum-master, developer, tester, ai-engineer),
a skill library, scripting infrastructure, and a project board system
(epics/stories/tasks). It is designed to be installed into consumer projects
to give them a structured agentic workflow.

This site is restructured from the project's existing
[wiki documentation](https://github.com/samwelmunga/JengaAgent/wiki) into a
navigable, multi-page reference — the wiki stays canonical and
`doc-sync`-maintained; this site is a presentation layer over the same
content. See `docs/README.md` in this repo for the full source-of-truth and
tooling decision record.

## Where to go

- **[Getting Started](getting-started.md)** — the philosophy behind Jenga
  AI, the three pillars (role separation, board hierarchy, session
  continuity), your first 15 minutes, and common patterns.
- **[Concepts](concepts.md)** — role separation, board hierarchy, session
  continuity, your first feature, working across sessions, capturing
  mid-flow ideas, and parallel tasks, each as its own section.
- **[Reference](reference.md)** — the full reference index: links out to
  the [Skills Reference](skills.md), [Agents](agents.md), [Hooks](hooks.md),
  and [MCP Tools](mcp-tools.md) pages, plus the repo's directory structure
  and the inter-agent communication contract.

> Getting Started, Concepts, Skills, Agents, Hooks, MCP Tools, and Reference
> are generated from `project/.wiki/*` by `scripts/build-pages-site.sh` — see
> that script's header comment for how to keep this site in sync when the
> wiki changes.

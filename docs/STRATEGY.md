# Strategy Brief

> **Audience:** Investors and strategic partners.
> This document describes the strategic direction of JengaAgent. It does not include revenue models, pricing, or competitive analysis.

---

## Vision

JengaAgent's vision is to become the standard meta-framework for structured agentic software development — making it as easy to deploy a disciplined, multi-agent engineering workflow as it is to install a package.

We believe that AI-assisted development reaches its full potential only when it is structured: with clear roles, bounded responsibilities, a shared project board, and auditable communication between agents. JengaAgent provides that structure out of the box.

---

## Value Proposition

JengaAgent gives software teams a production-ready agentic workflow without building one from scratch.

Instead of a single AI assistant operating on an ad-hoc basis, JengaAgent provides:

- **Role-bounded agents** — scrum master, developer, tester, and AI engineer each with exclusive write permissions and defined responsibilities
- **A skill library** — over thirty slash-command skills covering planning, execution, review, publishing, documentation, and maintenance
- **A structured project board** — epics, stories, and tasks tracked as version-controlled Markdown files with strict frontmatter schema
- **npm distribution** — install into any project with `npm install jenga-agent`; postinstall wires up agents, skills, hooks, and scripts automatically

The result is an engineering team that can delegate complex, multi-step implementation work to agents with confidence that it will be planned, reviewed, tested, and committed in a repeatable, auditable way.

---

## Scope

### In Scope

- The agent definitions (scrum-master, developer, tester, ai-engineer) and their communication contract
- The skill library (`/do`, `/jenga`, `/publish`, `/doc`, `/train`, and all others in `skills/`)
- The project board system: epic/story/task schema, board files, queue, and rollup logic
- Script infrastructure for CI, board operations, validation, and session lifecycle hooks
- npm packaging and distribution via the `/publish` skill
- Documentation tooling: `/doc`, `/doc-sync`, the path-objectives registry, and this convention

### Out of Scope

The following are explicitly outside the scope of this document and of JengaAgent itself:

- Revenue model, pricing strategy, or monetisation plans
- Competitive analysis or feature comparison with other tools
- Internal financial projections

---

## Target Audience

JengaAgent is built for:

- **Software engineering teams** who want structured, auditable AI-assisted development workflows without building the scaffolding themselves
- **AI/ML engineers** who need a disciplined pipeline for model training jobs, evaluation, and iteration alongside a working software project
- **Claude Code users** who want to move beyond single-assistant sessions into a multi-agent, role-bounded workflow
- **Developer tooling authors** who want to distribute their own skill libraries or agent configurations via the JengaAgent extension model

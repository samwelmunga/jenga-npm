---
name: deep-dive
description: >
  Multi-phase investigation workflow. The scrum-master orchestrates information
  gathering, interactive brainstorming, critical scrutiny, and solution assessment
  to produce a refined, well-considered output document. Use when a request needs
  thorough analysis before committing to a plan. Triggers on phrases like
  "deep dive", "investigate thoroughly", "think this through properly",
  "analyze this in depth", or "I want a thorough analysis of".
metadata:
  prefered_agent: scrum_master
keywords:
  - "deep dive"
  - "investigate"
  - "analyze thoroughly"
  - "think through"
examples:
  - "deep dive on this idea"
  - "let's think through this properly"
  - "I want a thorough analysis of this feature"
  - "investigate this proposal in depth"
---

# /deep-dive — Deep Investigation Workflow

## Overview

A multi-phase workflow that takes a user's request through structured investigation,
collaborative brainstorming, critical scrutiny, and optional solution assessment —
producing a refined, saved output document.

### Modes

| Mode | Pipeline | When to use |
|------|----------|-------------|
| `explore` | Info gathering → Brainstorm → Save | Idea is clear, just needs structure |
| `challenge` | + Scrutiny review → Amend → Save | Default — most requests |
| `resolve` | + Solution assessment → Amend → Save | Known problems need concrete solutions |

**Default mode: `challenge`**

---

## Instructions

### Step 1 — Receive the Request

Accept the user's mission, issue, or idea as the **request**. Note it clearly before proceeding.

---

### Step 2 — Select Mode

If the user has not specified a mode, ask:

> "How deep should we go?"
> 1. **Explore** — Brainstorm only
> 2. **Challenge** — Brainstorm + critical scrutiny *(default)*
> 3. **Resolve** — Full pipeline with solution assessment

If the user is in a hurry or it's obvious from context, default to `challenge` without asking.

---

### Step 3 — Information Gathering (Judgment Call)

Before brainstorming, assess whether sufficient context exists to proceed productively.

- Check `project/documentation/examples/` for related prior work or descriptions
- Consider invoking `/examplify` if a concept in the request needs clarification
- Ask the user directly if a critical piece of context is missing

**Default: proceed.** Do not over-investigate. The brainstorm step will surface gaps naturally. Move on unless something fundamental is clearly missing.

---

### Step 4 — Interactive Brainstorm

Invoke `/brainstorm` with the request and any context gathered in Step 3.

This is an **interactive session** — the user participates actively. Ask focused questions,
challenge assumptions, and explore the design space together.

When the user signals they are satisfied with the brainstorm output, **capture the full brainstorm result** as the working document and proceed.

---

### Step 5 — Scrutiny Review (`challenge` and `resolve` modes)

Summon the `scrutiny-agent` (`agents/scrutiny-agent.md`) with the brainstorm output as input.

The scrutiny agent will:
- Produce a structured critical assessment (assumptions, key questions, risks, strengths)
- Save it to `./scrutiny-<slug>.md`
- Return the assessment to the scrum-master

**Escalation threshold is low.** After reading the scrutiny output, escalate to Step 6 if any of the following are true:
- Any risk is rated **Med** or **High** severity
- Any key question remains unanswered and is not trivial
- Any core assumption is directly challenged without a clear resolution

If none of the above apply and the mode is `challenge`, skip Step 6 and proceed to Step 7.

---

### Step 6 — Solution Assessment (`resolve` mode, or escalated from `challenge`)

Summon the `solution-assessor` (`agents/solution-assessor.md`) in **Mode B (chained)** —
pass the full scrutiny output as input.

The solution assessor will:
- Derive all problems from the scrutiny output
- Assess candidate solutions with effort, risk, and viability
- Save the assessment to `./solution-assessment-<slug>.md`
- Return the full assessment to the scrum-master

---

### Step 7 — Amend the Brainstorm Output

The scrum-master **amends** the captured brainstorm document — does not replace it.

Append a `## 🔍 Deep Dive Synthesis` section at the end of the brainstorm document containing:

```markdown
## 🔍 Deep Dive Synthesis

### Scrutiny Findings
[Brief summary of critical concerns, key questions, and risks identified]
→ Full assessment: `./scrutiny-<slug>.md`

### Solution Paths *(if applicable)*
[Brief summary of recommended solution paths and estimated effort]
→ Full assessment: `./solution-assessment-<slug>.md`

### Open Decisions
[Any unresolved questions or choices the user must make before proceeding]
```

Keep each section **concise** — these are signposts to the full documents, not rewrites of them.

---

### Step 8 — Save Output

Determine the correct output directory based on content:

| Directory | When to use |
|-----------|-------------|
| `project/documentation/plans/` | Result can directly seed one or more Epics and/or Stories |
| `project/documentation/examples/` | Result is primarily descriptive or explanatory in nature |
| `project/documentation/summaries/` | Everything else |

Save the amended brainstorm document as `<slug>.md` in the chosen directory.
Also move any scrutiny/solution-assessment files from the working directory into the same directory for co-location.

Inform the user of all saved file paths.

---

### Step 9 — Offer Next Steps

Ask the user:

> "Would you like to commit this to the board?"
> 1. **Yes** — proceed with `/todo` to create board items from the output
> 2. **No** — close the deep-dive session

---
name: route
description: Intelligently routes a prompt to the best-matching skill in the project. Reads available skills, matches the input semantically and by keyword, enriches the prompt with board context and documentation references, then invokes the matched skill with the full context prepended.
keywords:
  - "route"
  - "dispatch"
  - "auto skill"
  - "smart prompt"
  - "find skill"
examples:
  - "route: I want to plan a new feature"
  - "route: something is broken in the auth module"
  - "route: let's review what's done so far"
  - "route: analyze this approach in depth before we commit"
  - "route: add a task to capture this idea"
---

# Route — Intelligent Skill Dispatcher

## Purpose

`/route <prompt>` takes any natural-language input, finds the best-matching skill in the project, enriches it with live board context and documentation references, and invokes the matched skill — all in a single, fully-loaded message.

---

## Instructions

### Step 1 — Discover Available Skills

Scan both skill registries (they may differ slightly — check both):

```
.agents/skills/<name>/SKILL.md
.claude/skills/<name>/SKILL.md       (if the directory exists)
skills/<name>/SKILL.md               (if the directory exists)
```

For each skill found, extract the following fields from its YAML front-matter:

| Field | Purpose |
|---|---|
| `name` | Canonical identifier |
| `description` | Primary match signal |
| `keywords` | Exact/partial keyword match |
| `examples` | Semantic match reference |
| `metadata.prefered_agent` | Which agent to delegate to |

Build an in-memory skill registry from this data before proceeding.

---

### Step 2 — Match the Prompt to a Skill

Run matching in three passes (stop at first confident match):

#### Pass 1 — Keyword Match
Check whether any phrase from a skill's `keywords` list appears verbatim (case-insensitive) in the prompt.

#### Pass 2 — Example Similarity
Compare the prompt against each skill's `examples` list. Treat this as a semantic similarity check: pick the skill whose examples most closely reflect the intent of the prompt.

#### Pass 3 — Description Match
If no clear winner has emerged, compare the prompt against each skill's `description` field. Pick the skill whose description best captures what the user is trying to do.

**If two or more skills score equally**, present the top candidates and ask the user to choose:

```
More than one skill matches your prompt. Which should I apply?
1. /<skill-a> — <one-line description>
2. /<skill-b> — <one-line description>
3. Neither — describe what you need
```

**If no skill matches at all**, inform the user and offer:

```
No matching skill found for: "<prompt>"
Would you like to:
1. Browse all available skills (/help)
2. Create a new skill for this use case (/btw)
3. Proceed without a skill (raw prompt)
```

---

### Step 3 — Check the Board for Related Context

Read `project/configs/workflow.json` for board paths (default: `project/board/`).

Scan the board for items that are topically related to the prompt:

1. **Epics** — `project/board/epics/` — check `title` and `description` fields
2. **Stories** — `project/board/stories/` — check `title` and `description` fields
3. **Tasks** — `project/board/tasks/` — check `title` and `description` fields

Extract any items whose title or description contains keywords from the prompt. Limit to the **top 5 most relevant** results. Do not include items whose status is `Archived` or `Cancelled`.

---

### Step 4 — Check Documentation

Scan the following directories for relevant documentation files:

```
project/documentation/plans/
project/documentation/summaries/
project/documentation/examples/
docs/
```

Match filenames and headings against the prompt keywords. Collect the **top 3 most relevant** file paths.

---

### Step 5 — Construct the Enriched Prompt

Assemble the following composite message in **exactly this order**:

#### Part A — Matched Skill (full content)
Inline the **full body** of the matched skill's `SKILL.md` (everything after the YAML front-matter). This is placed first so the agent reads the skill instructions before anything else.

```
<!-- SKILL: /<matched-skill-name> -->
<full skill instructions>
<!-- END SKILL -->
```

#### Part B — Board & Documentation Context
Immediately after the skill, append a context block:

```markdown
---
## 📋 Relevant Board Context

<list each matched board item as:>
- [<status>] **<ID>** — <title> (`project/board/<type>/<filename>`)

## 📄 Relevant Documentation

<list each matched doc as:>
- `<file-path>` — <one-line summary of the doc's purpose>
---
```

If no board items or docs were found, omit the corresponding section rather than leaving it empty.

#### Part C — Original Prompt
Finally, append the user's original unmodified prompt:

```
## 🗣 Original Prompt

> <original prompt verbatim>
```

---

### Step 6 — Invoke the Matched Skill

Deliver the enriched composite message to the appropriate agent:

- If the matched skill specifies `metadata.prefered_agent`, load that agent's definition from `agents/<prefered_agent>.md` and pass the full composite message to it.
- If no `prefered_agent` is specified, execute the skill instructions directly using the composite message as the working input.

Do **not** summarise or restate the composite message — deliver it as-is.

---

### Step 7 — Report Routing Decision

Before invoking the skill, briefly inform the user:

```
Routing to: /<matched-skill-name>
Reason: <one sentence explaining why this skill was chosen>
Board items found: <count>
Docs found: <count>
```

Then proceed immediately — do not wait for user confirmation unless the match was ambiguous (Step 2 tie-break already handled that).

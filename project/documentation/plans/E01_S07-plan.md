# E01_S07 — AI Engineer Agent: Execution Plan

## Problem Statement
The platform needs a dedicated `ai_engineer` agent for deep AI/ML technical work. Users should never have to interact with low-level ML concepts directly; instead, the `scrum-master` mediates all communication — translating user intent into precise technical instructions and converting technical output back into plain language.

## Files to Create / Modify

| File | Action |
|---|---|
| `agents/ai_engineer.md` | **Create** — new agent definition |
| `agents/scrum-master.md` | **Update** — append Mediator Mode section |
| `skills/train/SKILL.md` | **N/A** — does not yet exist; document dependency in story file |
| `project/board/stories/E01_S07_ai-engineer-agent.md` | **Update** — status, dates, dependency note |
| `project/documentation/summaries/E01_S07-summary.md` | **Create** — execution summary |
| `project/logs/events.json` | **Update** — append sender event |

## Design Decisions

### Mediator Pattern
The `scrum-master` sits between the user and `ai_engineer` at all times:

```
User (plain language)
  ↓  scrum-master translates to technical terms
ai_engineer (technical reasoning)
  ↓  scrum-master translates to plain language
User (plain language)
```

`ai_engineer` **never** writes directly to the user. Its output is always addressed to `scrum-master`.

### Structured Output Format
`ai_engineer` uses a consistent four-field block so `scrum-master` can reliably parse and translate it:

```
DECISION:            — what choice needs to be made
OPTIONS:             — A / B / C with brief tradeoffs
RECOMMENDATION:      — preferred option and rationale
CLARIFICATION_NEEDED — any open questions for the user
```

### /train Skill Dependency
`skills/train/SKILL.md` does not exist yet (E01_S01 not yet implemented). A note is added to the story file documenting this dependency so the wiring is done when E01_S01 is built.

### Agent File Format
Follows the same markdown style as `developer.md` and `scrum-master.md`: H2 sections, no YAML front-matter (existing agents don't use it), plain readable prose with code blocks where appropriate.

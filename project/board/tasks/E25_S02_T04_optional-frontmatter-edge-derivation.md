---
id: E25_S02_T04
story_id: E25_S02
epic_id: E25
title: Optional-frontmatter edge derivation — mentions, depends_on, blocks, parent_doc
status: Passed
date_created: 2026-07-23
date_started: 2026-07-23
date_completed: 2026-07-23
dates_previously_completed:
reopened_on:
reopened_reason:
---

# Task: Optional-frontmatter edge derivation — mentions, depends_on, blocks, parent_doc

## Description

Derive the remaining edge types from optional frontmatter keys on board artifacts (Epic, Story, Task nodes already extracted in T02–T03). These keys are `mentions_skills`, `mentions_agents`, `depends_on`, and `parent_doc` — all are tolerated-if-missing per the plan's degradation rule.

### `mentions_skill` edges
Source: any Epic/Story/Task/Plan/Doc with `mentions_skills: [skill_id, ...]` frontmatter.
Edge: `{ from: <node_id>, to: <skill_id>, type: "mentions_skill" }`
If `skill_id` does not resolve to a known Skill node, emit the edge anyway with a note in the node's debug metadata — do not suppress edges for unknown refs.

### `mentions_agent` edges
Source: any node with `mentions_agents: [agent_id, ...]` frontmatter.
Edge: `{ from: <node_id>, to: <agent_id>, type: "mentions_agent" }`
Same handling as above for unknown refs.

### `depends_on` edges
Source: any Story/Task with `depends_on: [E##_S##, ...]` frontmatter.
Edge: `{ from: <node_id>, to: <dep_id>, type: "depends_on" }`

### `blocks` edges
`blocks` is derived, not stored. For each `depends_on` edge A→B, emit a corresponding `blocks` edge B→A:
Edge: `{ from: <dep_id>, to: <node_id>, type: "blocks" }`

### `parent_doc` edges
Source: any Doc node with `parent_doc: E##_S##` frontmatter.
Edge: `{ from: <doc_id>, to: <parent_id>, type: "parent_doc" }`

### Degradation rules
- All keys missing → no edges, no error
- Key present but empty list → no edges, no error
- Key present with a value that is a string not a list → treat as single-item list
- Unknown target IDs → emit edge with unknown target (don't filter)

### Output
`board-index graph::edges` must now return all edge types in a single flat JSON array. `--type` filter selects by `type` field.

## Acceptance Criteria
- [ ] `board-index graph::edges --type mentions_skill` returns edges for any nodes that have `mentions_skills:` frontmatter
- [ ] `board-index graph::edges --type mentions_agent` returns edges for nodes with `mentions_agents:` frontmatter
- [ ] `board-index graph::edges --type depends_on` returns dependency edges
- [ ] `board-index graph::edges --type blocks` returns inverse edges derived from `depends_on`
- [ ] `board-index graph::edges --type parent_doc` returns parent_doc edges
- [ ] Nodes without optional frontmatter keys produce no errors
- [ ] A string value (not list) for `mentions_skills` is treated as a single-item list
- [ ] `board-index graph::edges` (no filter) returns all edge types in one flat array

## Definition of Done
- [ ] All five optional edge types implemented
- [ ] `blocks` derived from `depends_on` automatically
- [ ] Degradation rule enforced (missing → no edges, not errors)
- [ ] All edge types visible in combined `graph::edges` output

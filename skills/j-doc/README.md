# `/doc` Authoring and Usage Guide

`/doc` generates or regenerates a complete Markdown document for a resolved target path. The skill owns the entire target file: it resolves the documentation objective first, gathers evidence, reads any existing target for still-valid maintainer intent, then writes a full replacement document.

## Basic Usage

### Default target

```text
/doc
```

When no target is provided, `/doc` resolves the default target from `skills/j-doc/assets/path-objectives.yaml`. Today that default is `README.md`.

Expected flow:
1. Resolve `README.md`
2. Match the `project overview` objective
3. Gather project evidence
4. Regenerate the full `README.md`

### Custom target

Canonical custom-target form:

```text
/doc docs/API.md
```

Accepted convenience form:

```text
/doc update: docs/API.md
```

Both forms resolve `docs/API.md`, then apply the matching rule from `skills/j-doc/assets/path-objectives.yaml`.

## Target Resolution and Objective Rules

`skills/j-doc/assets/path-objectives.yaml` is the source of truth for:
- the default target
- known target paths
- each path's documentation objective
- required and optional sections for known targets

Known targets bypass ambiguity. Unknown targets must stop for clarification.

## Evidence Sources and Precedence

`/doc` builds a synthesis context before writing. When sources disagree, use this precedence order:
1. explicit user instruction
2. scrum-board context
3. codebase evidence
4. git history

The synthesis context contract currently includes:
- `target_path`
- `objective`
- `project_name`
- `project_description`
- `features`
- `getting_started`
- `board_items`
- `conflicts_resolved`
- `sources_used`
- `existing_intent`

Use stronger sources to break ties. Do not let weaker evidence overwrite explicit user direction.

## `last_update` Provenance

`last_update` is the documentation provenance field described by Epic E24's provenance work. It is intended to capture the most recent completed board item that materially updated the target document.

### Expected source of truth

The provenance lookup relies on scrum-board `docs: [...]` annotations that point at repo-relative documentation targets such as:
- `README.md`
- `docs/API.md`

Board authors should add `docs` annotations to stories or tasks whenever implementation work changes a specific document or should be reflected in that document later.

### How provenance is expected to resolve

1. Look for completed board items whose `docs` list includes the target path exactly.
2. Prefer the most recent qualifying item.
3. Use that item as the basis for the document's `last_update` value.

### Fallback behavior

If provenance cannot be resolved, `/doc` should follow the fallback defined by E24_S05:
- omit `last_update`, or
- mark it as `unknown`

Typical failure modes:
- the relevant board item never declared `docs: [...]`
- the target path in the board item does not exactly match the generated path
- the board item exists but is not yet in a completed/passed state

## Ambiguity Gate

If the resolved target path is not present in `skills/j-doc/assets/path-objectives.yaml`, `/doc` must not guess.

It should stop and ask exactly:

```text
What should <target_path> document? Please describe the objective.
```

### Example

```text
/doc update: docs/UNKNOWN.md
```

Expected behavior:
- do not generate a file yet
- do not invent a target objective
- ask the user what `docs/UNKNOWN.md` is meant to document

Once the user clarifies the objective, surface the resolved contract and continue.

## Target-Specific Notes

### `README.md`
Use `/doc` with no arguments when you want to regenerate the project overview. The generated file should center on:
- project description
- getting started steps
- examples only when they are strongly supported by evidence

### `docs/API.md`
Use `/doc docs/API.md` (or `/doc update: docs/API.md`) when you want an API reference document. The generated file should remain grounded in known interfaces, endpoints, parameters, return values, and errors.

## Tips for Board Authors

Add `docs` annotations when board work affects documentation scope or provenance. Good examples:

```yaml
docs:
  - README.md
  - docs/API.md
```

Use annotations when:
- a task introduces or changes user-visible behavior that belongs in README
- a story adds or changes an endpoint, command, interface, or workflow doc
- you want `/doc` provenance to trace the work back to the board reliably

Avoid annotations when the work has no documentation impact.

## Maintainer Checklist

Before relying on `/doc`, confirm that:
1. the target path exists in `skills/j-doc/assets/path-objectives.yaml`, or you are prepared to answer the ambiguity prompt
2. relevant board items include accurate `docs: [...]` annotations
3. higher-priority evidence sources are up to date
4. any existing target file content that should survive regeneration is genuinely still valid

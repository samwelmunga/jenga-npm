---
name: doc
description: Generate or update a documentation file by resolving a target path to a clear documentation objective before writing.
metadata:
  prefered_agent: developer
keywords:
  - doc
  - documentation
  - write docs
  - generate docs
  - update docs
examples:
  - "/doc"
  - "/doc docs/API.md"
  - "generate documentation for the CLI"
  - "update the contributing guide"
---

# Doc — Documentation Synthesis and Regeneration

## Input Format

```text
/doc [target-path]
```

- If `target-path` is omitted, default to `README.md`.
- If `target-path` is provided, use it exactly as written after `/doc`.
- Do not guess additional arguments or rewrite the requested path.

## Reference Asset

Load `skills/doc/assets/path-objectives.yaml` before resolving the documentation objective. Treat it as the source of truth for the `default_target`, known target paths, and their structural requirements.

## Synthesis Context Contract

After target resolution, all generation must operate on a synthesis context object. E24_S03 is responsible for producing the final implementation, but this story defines the field contract that downstream generation must consume.

```yaml
target_path: README.md
objective: project overview
project_name: JengaAgent
project_description: Structured multi-agent development workflow
features: []
getting_started: []
board_items: []
conflicts_resolved: []
sources_used: []
existing_intent: null
```

Required fields from E24_S03:
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

If the shared collector from E24_S03 is not yet merged, construct a temporary context with the same field names so later steps remain compatible.

## Instructions

### 1. Parse the target path

1. Read `default_target` from `skills/doc/assets/path-objectives.yaml`. If it is missing, fall back to `README.md`.
2. Remove the `/doc` command token from the invocation.
3. Trim the remaining text.
4. If nothing remains, set `target_path` to `default_target`.
5. Otherwise, set `target_path` to the trimmed remainder.

Examples:
- `/doc` → `target_path = README.md`
- `/doc docs/API.md` → `target_path = docs/API.md`
- `/doc docs/CLI.md` → `target_path = docs/CLI.md`

### 2. Resolve the objective from the rule table

1. Read `skills/doc/assets/path-objectives.yaml`.
2. Find an entry whose `path` exactly matches `target_path`.
3. If a match exists, set:
   - `objective` to the entry's `objective`
   - `objective_summary` to the entry's `summary`
   - `required_sections` / `optional_sections` from the entry when present
4. If no match exists, stop and use the ambiguity gate in Step 4.

### 3. Surface the resolved contract before continuing

Before any synthesis or writing work, clearly surface the resolved contract in this shape:

```text
Resolved /doc target
- target_path: <target_path>
- objective: <objective>
- summary: <objective_summary>
- required_sections: <required_sections when present>
- optional_sections: <optional_sections when present>
```

If the matched rule includes section guidance, carry it forward as constraints for the subsequent documentation work.

### 4. Ambiguity gate for unknown targets

If `target_path` is not present in `skills/doc/assets/path-objectives.yaml`:

- Ask the user exactly: `What should <target_path> document? Please describe the objective.`
- Do **not** guess the objective.
- Do **not** proceed with documentation generation or updates until the user answers.
- Once the user clarifies, treat their response as the `objective`, set `objective_summary` from the same clarification when helpful, surface the resolved contract, and continue.

### 5. Load or assemble the synthesis context

1. Start from the E24_S03 synthesis context when it is available.
2. Ensure `target_path` and `objective` from Steps 1–3 are copied into the context.
3. Populate `project_name`, `project_description`, `features`, `getting_started`, `board_items`, `conflicts_resolved`, and `sources_used` from the evidence collector.
4. If any field is temporarily unavailable because E24_S03 has not landed yet, gather the missing evidence manually and store it under the same field names.
5. Initialise `existing_intent` to `null` before inspecting the target file.

### 6. Read the existing target before generation

`/doc` owns the full target file. If the target already exists:

1. Read the current file before generating anything.
2. Extract maintainer intent that may still matter after regeneration, such as:
   - custom sections that still fit the target objective
   - warnings, caveats, migration notes, or known-issue callouts
   - terminology preferences or audience cues
   - maintainers' explicit scope boundaries
3. Do **not** carry forward stale factual claims that conflict with the new evidence.
4. Save the retained intent into `synthesis_context.existing_intent`.

If the target file does not exist, keep `existing_intent = null`.

### 7. Generate a complete replacement file

1. Build a **full file string** from the synthesis context and the resolved target objective.
2. Treat the generated output as the entire authoritative file.
3. Do **not** patch a single section, append new text to the end, or leave untouched legacy sections in place.
4. Keep the output valid Markdown.
5. When writing, replace the old file contents in one operation.

### 8. Generate `README.md` for the project-overview objective

When `target_path = README.md`, generate the full document around the resolved project-overview contract.

#### Required structure

```md
# <project_name>

## Description
...

## Getting Started
...
```

#### Description rules

- Source Description content from `project_description`, `features`, and any still-valid `existing_intent`.
- Explain what the project is, what problem it solves, and who it is for.
- Keep the section concise and factual.
- Cap the section at **1000 words maximum**.
- Prefer a tight narrative plus bullets over repetitive prose.

#### Getting Started rules

- Source the section from `getting_started` first.
- Fill missing setup detail from concrete manifests and entrypoints already present in the codebase (for example `package.json`, `pyproject.toml`, `go.mod`, startup scripts, or checked-in app packages).
- Cover install, configure, and run steps only when evidence exists.
- Preserve useful setup warnings from `existing_intent` when they are still valid.
- Output valid Markdown lists or numbered steps.

### 9. Conditionally include a README Examples section

Only add `## Examples` to `README.md` when the synthesis context supports a grounded project-type inference.

#### Infer the project type from evidence

Use the synthesis context first, then reinforce it with manifests and source layout:

- **CLI** indicators:
  - `bin` in `package.json`
  - Python CLI entrypoints such as `[project.scripts]` / `[tool.poetry.scripts]`
  - CLI-focused board items or feature descriptions
  - command-oriented code or existing CLI docs
- **API** indicators:
  - web-framework dependencies
  - route/controller files
  - `openapi.yaml` / `openapi.yml`
  - board items describing endpoints or request/response behavior
- **Library / SDK** indicators:
  - no CLI `bin`
  - export-heavy modules or public interfaces
  - registry-publishing metadata
  - board items describing integration from another project

Choose the strongest evidenced type in this priority order when multiple types appear: explicit synthesis-context evidence, manifest metadata, source-layout evidence, then board-item wording. If no type can be supported confidently, omit the Examples section entirely.

#### Examples rules

- Generate at least **two concrete examples** when the section is included.
- Every example must come from real capabilities present in `features`, `getting_started`, `sources_used`, or retained `existing_intent`.
- Match the example shape to the inferred type:
  - **CLI** → command invocations with realistic flags and outcomes
  - **API** → request/response examples such as `curl` or HTTP snippets
  - **Library / SDK** → import-and-use code snippets
- Do **not** include placeholder examples, pseudo-commands, or guessed endpoints.
- If you cannot produce two grounded examples, omit the section instead of improvising.

### 10. Generate non-README targets from the rule table

For every known non-README target, the path-to-objective rule table determines the file structure. Generate a full document that satisfies the matched rule.

#### `docs/API.md` — API reference documentation

Required shape:

```md
# API Reference

## Overview
...

## Endpoints or Interfaces
### <module or route group>
- Signature / method + path
- Parameters or request fields
- Return values or response shape

## Request and Response Details
...
```

Rules:
- Group content by module, route family, or interface namespace.
- Include function signatures or HTTP method/path pairs when evidence exists.
- Document parameters, request bodies, return values, and notable errors.
- Use `sources_used` and `board_items` to ground scope; do not invent undocumented endpoints.

#### `docs/CLI.md` — CLI usage guide

Required shape:

```md
# CLI Guide

## Overview
...

## Commands
...

## Flags
...

## Examples
...
```

Rules:
- Derive the command name from CLI entrypoints such as `package.json#bin`.
- List commands and subcommands with concise descriptions.
- Document flags with names, accepted values, defaults, and effects when evidence exists.
- Include usage examples grounded in real workflows from the synthesis context.

#### `docs/CONTRIBUTING.md` — contributor guide

Required shape:

```md
# Contributing

## Development Setup
...

## Workflow
...

## Contribution Expectations
...
```

Rules:
- Use manifests, repo scripts, and existing maintainer guidance to describe setup.
- Explain branch, PR, review, and testing expectations only from repository evidence.
- Carry forward still-valid maintainer norms captured in `existing_intent`.

#### `CHANGELOG.md` — changelog / release notes

Required shape:

```md
# Changelog

## <version or date heading>
### Notable Changes
- ...
```

Rules:
- Derive entries from `git log`; do not fabricate releases.
- Group entries by version tag when tags exist.
- If version tags do not exist, group by date-based headings instead.
- Summarize each entry from commit subjects and, when needed, nearby commit context.
- Keep newest entries first.

### 11. Continue using the resolved objective

After the target path and objective are resolved, use them as the contract for all subsequent `/doc` work. Known paths must bypass the ambiguity gate, and all later decisions about evidence gathering, scope, regeneration, and structure must honor the surfaced `target_path` and `objective` instead of inferring a different goal.

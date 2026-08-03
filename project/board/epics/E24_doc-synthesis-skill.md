# E24 — `/doc` Document Synthesis Skill

**Status**: Passed  
**Date Completed**: 2026-07-30  
**Goal**: Implement a `/doc` skill that generates or updates documentation files for any target path, with contextual scope inference, multi-source evidence gathering, and board-linked provenance tracking via `last_update` frontmatter.

---

## Stories

### E24_S01 — Board doc provenance schema
**Status**: Todo  
Add optional `docs: [...]` annotation support to the scrum board schema so board items can declare which documentation files they affect. `/doc` uses this to resolve `last_update` frontmatter.

**Tasks**:
- E24_S01_T01: Add optional `docs: [...]` field to epic/story/task board schema and templates
- E24_S01_T02: Update board validation/scripts to accept and preserve `docs` annotations
- E24_S01_T03: Update Scrum Master agent guidance for when to annotate board items with doc targets

---

### E24_S02 — `/doc` skill contract and target resolution
**Status**: Todo  
Scaffold the `/doc` skill with argument parsing, the path→objective rule table, and an ambiguity gate that requires user clarification for unknown targets.

**Tasks**:
- E24_S02_T01: Scaffold `skills/doc/SKILL.md` with default target `README.md`
- E24_S02_T02: Implement optional target path argument parsing
- E24_S02_T03: Define deterministic path→objective rule table (e.g. `README.md` → project overview, `docs/API.md` → API doc, `docs/CLI.md` → CLI usage)
- E24_S02_T04: Implement ambiguity gate — unknown/unmapped targets require explicit user clarification before proceeding

---

### E24_S03 — Evidence collection and precedence
**Status**: Todo  
Collect evidence from all configured sources (user prompt, scrum board, codebase, git history) and enforce a strict precedence chain when sources conflict.

**Tasks**:
- E24_S03_T01: Collect evidence from user prompt, scrum board (`PROJECT_SUMMARY.md`, epics, stories, tasks), codebase (manifests, source files), and git history
- E24_S03_T02: Enforce source precedence: user prompt → scrum board → codebase inspection → git history
- E24_S03_T03: Normalize evidence into a reusable synthesis context object for downstream generation

---

### E24_S04 — Document synthesis and regeneration
**Status**: Todo  
Implement the full-file generation flow. `/doc` owns the entire file — it reads the existing file for context before regenerating. Sections are conditional on scope.

**Tasks**:
- E24_S04_T01: Implement full-file ownership flow — read existing file for intent, then regenerate from scratch
- E24_S04_T02: Generate project-overview docs with Description (<1000 words) + Getting Started sections
- E24_S04_T03: Implement conditional Examples section — include only if project produces user-facing output (API, CLI, library, SDK)
- E24_S04_T04: Support non-README targets (API doc, CLI doc, etc.) using the path→objective rule table

---

### E24_S05 — Frontmatter provenance resolution
**Status**: Todo  
Resolve `last_update` from completed board items with matching `docs` annotations. Define fallback behavior when provenance is missing.

**Tasks**:
- E24_S05_T01: Resolve `last_update` from done board items carrying `docs` annotations that match the target file
- E24_S05_T02: Define fallback: omit `last_update` or mark `unknown` when provenance cannot be determined
- E24_S05_T03: Document provenance assumptions and failure modes in `skills/doc/` authoring notes

---

### E24_S06 — Integration, distribution, and documentation
**Status**: Todo  
Wire `/doc` into the skill discovery and distribution flow, write authoring docs, and validate happy paths and ambiguity cases.

**Tasks**:
- E24_S06_T01: Register `/doc` in help/discovery and ensure it distributes correctly via `/distribute`
- E24_S06_T02: Write authoring docs and usage examples for `/doc` (default and custom target)
- E24_S06_T03: Validate happy paths (README.md, docs/API.md) and ambiguity cases against fixture targets

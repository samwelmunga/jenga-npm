# Understanding Document: {{TARGET_NAME}}

<!--
  OUTPUT CONTRACT — /uncharted shared investigative engine.

  Every mode (`segment`, `import`, `onboard`) emits this exact document shape.
  It is rendered by `skills/uncharted/scripts/run-engine.sh` and written to
  `project/rapports/analysis/` using the existing `analysis` rapport type
  defined in `templates/SCRUM_BOARD_SCHEMA.md`.

  The seven `##` headings below are FIXED. Do not add, remove, reorder, or
  rename them — downstream consumers (segment-mode board proposal, onboard-mode
  subsystem backfill) read this document by heading.

  Two classes of section:

    MECHANICAL — Structure, Key Dependencies, Existing Tests.
      Filled by the engine from real script output. Never hand-waved.

    JUDGEMENT  — Purpose, Risk Areas, Open Questions.
      The engine emits these as explicit `_TODO(agent):_` placeholders and
      MUST NOT invent content for them. The scrum-master fills them in from
      the mechanical evidence above.

  `{{DOUBLE_BRACE}}` tokens are substituted by the renderer. Two kinds:

    SCALAR — replaced once, in place. Most tokens are scalar.

    ROW     — a table row marked `<!-- ROW -->` is a row TEMPLATE, not a
      single row. The renderer repeats it once per record and drops it
      entirely when there are no records. Replacing it one-to-one would
      silently truncate the table to a single entry.
-->

**Mode:** {{MODE}}
**Generated:** {{TIMESTAMP}}
**Engine:** `skills/uncharted/scripts/run-engine.sh`

---

## Target

<!-- MECHANICAL. Resolved by enumerate-target.sh. -->

| Field | Value |
|-------|-------|
| Resolved path | `{{TARGET_PATH}}` |
| Target type | {{TARGET_TYPE}} <!-- file \| directory \| repo_root --> |
| Invocation mode | {{MODE}} <!-- segment \| import \| onboard --> |
| Board linkage | {{BOARD_LINKAGE}} <!-- linked to <ID> \| unlinked --> |
| Origin | {{ORIGIN}} <!-- in-repo \| imported from <source> --> |

---

## Purpose

<!--
  JUDGEMENT. The scrum-master fills this in after reading the mechanical
  sections. Answer: what does this code exist to do, and for whom?
  If the evidence is insufficient to say, record that here and raise the gap
  under Open Questions — do not guess.
-->

_TODO(agent): what this target does and why it exists._

---

## Structure

<!--
  MECHANICAL. Rendered from enumerate-target.sh output: file count,
  per-extension breakdown, bounded directory tree, largest files by line count.
  Depth is bounded — `onboard` mode stays coarse-grained by design.
-->

**Files:** {{FILE_COUNT}}

| Extension | Count |
|-----------|-------|
| {{EXT}} | {{EXT_COUNT}} | <!-- ROW -->

**Tree** (max depth {{MAX_DEPTH}}):

```
{{DIRECTORY_TREE}}
```

**Largest files by line count:**

| File | Lines |
|------|-------|
| `{{LARGEST_FILE}}` | {{LARGEST_FILE_LINES}} | <!-- ROW -->

---

## Key Dependencies

<!--
  MECHANICAL. Rendered from detect-dependencies.sh output.
  Internal = resolves inside this repo. External = third-party or stdlib.
  Manifests are listed so declared dependencies can be reconciled against
  what is actually imported.
-->

**Internal:**

{{INTERNAL_DEPENDENCIES}}

**External:**

{{EXTERNAL_DEPENDENCIES}}

**Manifests found in or above the target:**

{{MANIFEST_FILES}}

---

## Existing Tests

<!--
  MECHANICAL. Rendered from detect-tests.sh output.
  Must distinguish "tests cover this target" from "the repo has tests, but
  none reference this target" — those are very different findings.
-->

**Coverage signal:** {{TEST_COVERAGE_STATUS}}
<!-- covered \| repo_tests_only \| no_tests_in_repo -->

**Test files referencing this target:**

{{TEST_FILES}}

**Test-runner configuration detected:**

{{TEST_RUNNER_CONFIG}}

---

## Risk Areas

<!--
  JUDGEMENT. Ground every entry in something above — an untested hot path, a
  heavy external dependency, an oversized file, a missing manifest entry.
  Generic risks that would apply to any codebase are not useful here.
-->

_TODO(agent): risks grounded in the mechanical findings above._

---

## Open Questions

<!--
  JUDGEMENT. What could not be determined from the evidence, and what the
  user would need to answer before this target is safely integrated or
  backfilled onto the board.
-->

_TODO(agent): what remains unknown and who can resolve it._

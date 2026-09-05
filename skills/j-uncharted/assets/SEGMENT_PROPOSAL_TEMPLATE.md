# Board Proposal: {{TARGET_NAME}}

<!--
  PRESENTATION CONTRACT — /uncharted `segment` mode, Steps 4-6.

  This is the fixed shape of the board proposal a segment pass presents to the
  user. Unlike UNDERSTANDING_DOC_TEMPLATE.md, nothing renders this file: the
  scrum-master fills the `{{TOKENS}}` in itself and presents the result in the
  session. There is no renderer to add a token to.

  THIS DOCUMENT IS A PROPOSAL, NOT A WRITE. Presenting it creates and modifies
  nothing under `project/board/`. Only an explicit accept at `## Decision`
  authorises E40_S02_T03 to write anything.

  The six `##` headings are FIXED. Do not add, remove, reorder, or rename them.
  Every section must be filled — "n/a" is an acceptable value, an empty section
  is not, because a silently dropped section reads as "nothing to say here"
  when it usually means "not checked".

  Field names in `## Proposed Tasks` are the real frontmatter keys from
  `templates/SCRUM_BOARD_SCHEMA.md`, so a confirmed proposal maps one-to-one
  onto board files without re-deciding anything at write time.
-->

**Source document:** `{{UNDERSTANDING_DOC_PATH}}`
**Proposed:** {{TIMESTAMP}}
**Board state:** nothing written — this proposal is pending confirmation

---

## Target

| Field | Value |
|-------|-------|
| Resolved path | `{{TARGET_PATH}}` |
| Target type | {{TARGET_TYPE}} <!-- file \| directory \| repo_root --> |
| Board linkage | {{BOARD_LINKAGE}} <!-- from Step 1, which is authoritative --> |
| Why it needs board representation | {{PROVENANCE_GAP}} |

---

## Parent Epic

| Field | Value |
|-------|-------|
| Decision | {{EPIC_DECISION}} <!-- reuse existing \| reuse Maintenance \| new epic --> |
| Epic | {{EPIC_ID_OR_TITLE}} <!-- `E##` — Title, or the proposed title for a new epic --> |
| Reason | {{EPIC_REASON}} <!-- why this epic, in terms of what the document found --> |
| Existing epics considered | {{EPICS_CONSIDERED}} <!-- IDs weighed and why each was rejected; "none fit" is a claim that needs backing --> |

A new epic is the **last** option, not the default. Reuse an existing epic where the segment
genuinely belongs to it, and the standing `Maintenance` epic where the work is chore-shaped and
belongs nowhere else.

**If the decision is a new epic, propose its body here too** — the same two sections a written
epic file must carry, so accepting authorises no text the user has not read:

**Purpose:** {{EPIC_PURPOSE}}

**Definition of Done**
- [ ] {{EPIC_DOD}}

---

## Proposed Stories

<!-- Repeat the block below once per proposed story. -->

### S1 — {{STORY_TITLE}}

**As a** {{STORY_ROLE}}, **I want** {{STORY_GOAL}}, **so that** {{STORY_VALUE_STATEMENT}}.
**Grounded in:** {{STORY_EVIDENCE}} <!-- the specific finding that justifies it -->

*Acceptance Criteria*
- [ ] {{STORY_ACCEPTANCE_CRITERION}}

*Definition of Done*
- [ ] {{STORY_DONE_CRITERION}}

Acceptance Criteria and Definition of Done are proposed **here**, not written later.
`scripts/validate-story-format.sh` requires both sections on every story file and requires the
Definition of Done to use `- [ ]` checkboxes — so if they are not on screen at the gate, accepting
authorises text the user never saw, which is the outcome the gate exists to prevent.

---

## Proposed Tasks

| # | Story | Title | `execution_scope` | `scope_rationale` | `needs_docs` |
|---|-------|-------|-------------------|-------------------|--------------|
| T1 | S1 | {{TASK_TITLE}} | {{EXECUTION_SCOPE}} | {{SCOPE_RATIONALE}} | {{NEEDS_DOCS}} |

- `scope_rationale` is **required and must carry a file-count or line-count claim** — a validator
  rejects a blank one, and a reader cannot check "small change" but can check "2 files, ~60 lines".
- Scope is assigned against `project/configs/scope-thresholds.json`, not by feel.
- `execution_scope: epic` is never self-assigned. It needs `epic_scope_approval: true` set by a
  human on the epic; propose `story` and say so if a task looks bigger than that.

---

## Open Questions

<!-- Carried over from the understanding document's `## Open Questions`, not re-derived. -->

| # | Question | Who can answer | Blocks confirmation? |
|---|----------|----------------|----------------------|
| Q1 | {{OPEN_QUESTION}} | {{ANSWERER}} | {{BLOCKING}} <!-- yes \| no --> |

A question marked **yes** must be resolved before the proposal is accepted — the breakdown depends
on its answer. Carry the questions across even when they look answered; dropping one hides the
fact that the proposal rests on an assumption.

---

## Decision

Nothing above exists on the board yet. **How would you like to proceed?**

1. **Accept as proposed** — write these items to `project/board/`
   <!-- Unavailable while any Open Question above is marked `Blocks confirmation? = yes`. -->
2. **Revise** — change the stories, tasks, or scopes before anything is written
3. **Fit it under a different epic** — re-parent the proposal and show it again
4. **Discard** — keep the understanding document, write no board items
5. **Other (describe below)**

Options 2 and 3 re-present this proposal in full; nothing is written between rounds.

Option 1 is **not** available while any Open Question is marked `Blocks confirmation? = yes`.
Resolve it first — the answer usually changes the breakdown — then re-present.

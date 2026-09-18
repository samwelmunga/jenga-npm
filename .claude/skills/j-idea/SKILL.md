---
name: j.idea
description: Polyfill alias of the idea skill under a collision-safe directory name. Identical behavior to /idea — DEPRECATED - use the prefixed 'j-idea' skill instead. Capture a loosely-defined idea to project/ideas.md — a lightweight, "maybe someday" log with no board or promotion overhead. Use when the bare /idea form is shadowed by another tool's own built-in command of the same name.
keywords:
  - idea
  - capture idea
  - log idea
  - brain dump
  - maybe someday
  - j-idea
  - polyfill
examples:
  - "capture this as an idea"
  - "log this idea for later"
  - "I have a rough idea I want to jot down"
  - "j-idea"
metadata:
  prefered_agent: scrum-master
---

# Idea — Lightweight Idea Capture

This skill is a literal-directory-name duplicate of `skills/idea/`. It exists so that `/j-idea` (and `j.j-idea`) give a guaranteed-unshadowed way to reach the same flow as `/idea`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/idea` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh idea` from `skills/idea/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

1. **Ensure `project/ideas.md` exists** — If it doesn't exist, it will be auto-created by `idea_manager.sh` from `skills/j-idea/assets/idea_template.md` — no manual action needed.

2. **Ask the user about the idea:**
   - What's the idea?
   - Any known context worth noting (why it came up, what it might relate to)?

   Keep this light — `/idea` is a low-overhead capture, not a structured mission intake like `/todo`.

3. **Add to `project/ideas.md`** by running:
   ```
   bash "$([ -f scripts/idea_manager.sh ] && echo scripts/idea_manager.sh || echo node_modules/@jenga-ai/agent/scripts/idea_manager.sh)" add '<idea>'
   ```

4. **Ask the user**: "Capture another idea, or done?"
   - If **another** — go back to step 2.
   - If **done** — exit.

   Unlike `/todo`, `/idea` never offers to execute, refine, or promote the captured idea(s) at the end. There is no `/do`-style follow-up here — `/idea` has no refine or promotion logic of its own.

## For Reference Only — Promotion Convention (not implemented here)

`/idea` does not implement any refine or promotion mechanism. This section documents, for reference, how promotion is expected to work elsewhere so future flows stay consistent:

- **Promoting an idea** means re-running `/brainstorm` on it, which routes onward to `/btw` or `/todo` as normal. That routing behavior already exists and is out of scope for `/idea`.
- **Terminal idea states** are marked directly in `project/ideas.md` using the same HTML-comment tag convention `project/todo.md` uses for `RECONCILED`:
  - `PROMOTED` — the idea was picked up via `/brainstorm` and turned into board work.
  - `REJECTED` — the idea was reviewed and dropped.

### Embedded Board ID

`PROMOTED`/`REJECTED` tags support an embedded board ID, so the idea→board-item link is
machine-readable directly from the tag itself, without needing a separate lookup:

- `<!-- PROMOTED: E##_S##[_T##] -->` — the `_T##` task suffix is optional; use whichever level
  the idea was actually promoted into (an epic, a story, or a specific task).
- `<!-- REJECTED -->` — stays bare, with no embedded ID. A rejection has no resulting board
  item to point at.

Example (mirroring `project/todo.md`'s tagging style):
```
Add dark mode toggle to settings page <!-- PROMOTED: E12_S03 -->
Add a settings-page keyboard shortcut cheat sheet <!-- PROMOTED: E12_S03_T02 -->
Rewrite onboarding copy in a more casual tone <!-- REJECTED -->
```

### Source-Rapport Link Convention

Some ideas originate from a rapport rather than being manually captured via `/idea` — e.g. when
scrum-master's `rapport_review` step (E35_S03) detects a distinct idea surfaced inside a
problem rapport and, on user confirmation, appends it to `project/ideas.md` the same way
`/idea` does. When that happens, the entry's source rapport is recorded with a second inline
HTML comment on the same line:

```
<!-- rapport: <path/to/rapport.md> -->
```

Rules:
- Written at capture time, alongside the idea text, by whichever flow is adding the entry
  (scrum-master's rapport-derived capture path; `/idea`'s own manual capture never has a source
  rapport and omits this comment entirely).
- Left in place through promotion/rejection — the `rapport:` comment and the terminal
  `PROMOTED`/`REJECTED` comment coexist on the same line, e.g.:
  ```
  Extract shared retry logic into a utility <!-- rapport: project/rapports/problems/E40_S02_T01-segment-remarks.md --> <!-- PROMOTED: E61_S01 -->
  ```
- Consumed by the outcome-record mechanism at promotion/rejection time: if a `rapport:` comment
  is present on the line, that rapport is updated with the decision (and `[SPIKE]`-prefixed in
  its title/header if not already, per `templates/SCRUM_BOARD_SCHEMA.md`'s `[SPIKE]` section);
  if absent (a manually-captured `/idea` entry with no source rapport), a
  `project/documentation/plans/<slug>_PROMOTED.md` or `_REJECTED.md` file is created instead.
- Verified compatible with `scripts/idea_manager.sh`'s `real_entries()` filtering: that function
  only strips lines whose first non-whitespace characters are `<!--`; a trailing inline comment
  on an otherwise real entry line is untouched and the line still counts as a real entry.

No agent invoked by `/idea` applies terminal (`PROMOTED`/`REJECTED`) tags or acts on them — that
is reserved for the promotion step (e.g. within `/brainstorm`) and, for rapport-sourced ideas,
scrum-master's rapport-review flow.

### Outcome-Record Mechanism (`idea_manager.sh`) — E35_S03_T03

`scripts/idea_manager.sh` implements the tagging and outcome-record behavior described above, via
four additional subcommands beyond `add`/`list`:

- `tag "<idea-text>" <PROMOTED:E##_S##[_T##]|REJECTED>` — writes the terminal tag onto the
  `project/ideas.md` line matching `<idea-text>` (an exact/literal match; errors if zero or more
  than one line matches, and errors if the line is already tagged).
- `get-id "<idea-text>"` — prints the embedded board ID from that line's `PROMOTED` tag (errors
  if the line has no `PROMOTED` tag).
- `get-rapport "<idea-text>"` — prints the `rapport:` path recorded on that line, or nothing
  (exit 0) if the line has no source-rapport comment.
- `resolve "<idea-text>" <promoted|rejected> [board_id]` — the full outcome-record mechanism in
  one call: tags the line (as `tag` does), then either updates the idea's source rapport or, if
  none is recorded, creates the `project/documentation/plans/` fallback file:
  - **Source rapport present:** the rapport's `# Rapport: ...` title line is prefixed
    `[SPIKE] ` if not already, and an `## Idea Outcome Record` section (decision, date, resulting
    board ID if promoted, and the idea text) is appended to the rapport file.
  - **No source rapport:** `project/documentation/plans/<slug>_PROMOTED.md` or `_REJECTED.md` is
    created (idea text slugified, lowercased, capped at 60 characters), containing the same
    decision/date/board-ID/idea-text content.

  `board_id` is required for `promoted` (validated to start with `E<digits>`) and must be omitted
  for `rejected` (a rejection has no resulting board item).

This is the mechanism itself, not the trigger — nothing currently calls `resolve` automatically.
A future promotion step (e.g. within `/brainstorm`'s routing, or scrum-master acting on a
rapport-sourced idea) is expected to invoke it once that trigger exists.

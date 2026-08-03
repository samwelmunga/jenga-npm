# Plan: E07_S02_T01 — Entry Detail Panel Component

## Approach
Create `EntryDetailPanel.jsx` that renders as a slide-in panel when an entry is selected.

## Steps
1. Accept `entry` and `onClose` props
2. If `entry` is null/undefined, render nothing
3. For `git_commit` type: display SHA, author, date, full commit message
4. For `rapport` type: display filename, date, render `content_summary` as markdown HTML
5. Close button calls `onClose()` to clear selection
6. CSS: fixed right-side panel with slide-in animation, overlay backdrop
7. Reuse data from entry — no additional API calls

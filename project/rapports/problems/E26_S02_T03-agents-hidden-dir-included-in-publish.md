# Rapport: Hidden `.agents/` directory included in `agents/` publish payload

**Date:** 2026-07-31 (UTC)
**Agent:** Tester
**Related Epic:** E26
**Related Story:** E26_S02 — Harden package.json for npm publishing
**Related Task:** E26_S02_T03 — Implement postinstall hook for consumer project installation
**Type:** `analysis`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "",
    "task_id": "E26_S02_T03",
    "story_id": "E26_S02",
    "epic_id": "E26",
    "date": "2026-07-31T01:30:55Z",
    "paths": ["scripts/postinstall.js", "package.json"],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents"
  }
}
```

---

## Summary
The `agents/` directory in the package root contains a hidden `.agents/` subdirectory (~6,560 files — apparently Claude agent session or configuration artefacts). Because `package.json` lists `"agents/"` in its `files` array without exclusions, and no `.npmignore` exists, these ~6,560 files will be bundled into the published package and subsequently copied into every consumer project via the postinstall script.

---

## Context
During functional testing of `scripts/postinstall.js` (T03), the first-install smoke test reported:

```
  ✓ agents/ — 6566 file(s) copied
```

Inspection revealed `agents/.agents/` contains `agents/`, `bin/`, `hooks/`, `jobs/`, `lib/`, `mcp/` subdirectories totalling 6,560 files — none of which are the 6 intended agent markdown files (`developer.md`, `tester.md`, etc.).

---

## Problem Description
- **Root cause:** `agents/.agents/` is a hidden subdirectory inside the package-source `agents/` folder. It was likely created by the Copilot/Claude toolchain storing session state inside the working directory.
- **Impact:** Any `npm publish` from the current state will bundle these ~6,560 internal files into the tarball. On consumer install, the postinstall script will then copy all of them into `<consumer-root>/agents/`, inflating the consumer project with thousands of unintended files.
- **No `.npmignore` exists** to filter the hidden directory out, and the `files` entry `"agents/"` captures the entire directory tree recursively.
- The postinstall script itself is correct — it faithfully copies whatever is present in the source `agents/` directory. The problem is upstream (source pollution).

---

## Recommended Fix
Choose one of the following, in order of preference:

1. **Delete `agents/.agents/`** from the package source (most direct) and add it to `.gitignore` to prevent recurrence.
2. **Add a `.npmignore`** that excludes `agents/.agents/` (or all hidden directories):
   ```
   agents/.agents/
   **/.*
   ```
3. **Change the `files` entry** to enumerate specific files within `agents/` rather than the whole directory glob (more work, but gives tightest control).

The recommended action is option 1 (delete the directory) plus option 2 (add `.npmignore` as a safety net).

---

## Developer Decision (to be filled in)
- [ ] Address now — delete `agents/.agents/` and add `.npmignore`
- [ ] Defer — create a new task to clean up source directory pollution
- [ ] Ignore — add reason below and rename this file to `.IGNORE.md`

**Reason if ignoring:**

---

## Evidence
```
agents/
├── ai_engineer.md
├── developer.md
├── scrum-master.md
├── scrutiny-agent.md
├── solution-assessor.md
├── tester.md
└── .agents/          ← 6,560 unintended files
    ├── agents/
    ├── bin/
    ├── hooks/
    ├── jobs/
    ├── lib/
    └── mcp/
```

Test run file counts (first install):
- `skills/` — 104 files ✓ (expected)
- `agents/` — **6,566 files** ⚠ (expected ~6)
- `hooks/` — 7 files ✓
- `scripts/` — 12 files ✓
- `templates/` — 9 files ✓

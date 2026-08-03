# Rapport: agents/.agents/ Untracked Artifact Bloats npm Tarball

**Date:** 2026-07-31 (UTC)
**Agent:** Tester
**Related Epic:** E26 — npm-compatible distribution
**Related Story:** E26_S02 — Harden package.json for npm publishing
**Related Task:** E26_S02_T01 — Add files field to package.json
**Type:** `test_failure`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "",
    "task_id": "E26_S02_T01",
    "story_id": "E26_S02",
    "epic_id": "E26",
    "date": "2026-07-31T03:28:47Z",
    "paths": ["8e708e5"],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents"
  }
}
```

---

## Summary
The `files` field in `package.json` was correctly implemented (AC1 ✅). However, `npm pack --dry-run` currently produces a tarball of **6,700 files / 29.1 MB** — significantly larger than the developer's verified output of 142 files / 542.3 kB — due to an untracked `agents/.agents/` directory that contains nested `node_modules/` from the MCP router.

---

## Context
Task E26_S02_T01 added a `files` array to `package.json` listing publishable assets: `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE`. The task was committed at `8e708e5`. Subsequently, tasks T02 and T03 were committed, with T03 implementing a `postinstall` hook (`scripts/postinstall.js`). Running the postinstall hook locally created an `agents/.agents/` directory in the working tree.

---

## Problem Description

### Root cause
The `agents/.agents/` directory is an untracked working directory artifact (confirmed by `git status`: `?? agents/.agents/`). It was created by running the postinstall hook from T03, which installs agent and framework files into the local project. Since `agents/` is listed in the `files` array and `.agents/` is not gitignored or `.npmignore`-d, `npm pack` includes the entire subtree.

### What's bundled
The `agents/.agents/` directory contains:
- All agent `.md` files (duplicates of `agents/*.md`)
- `hooks/`, `lib/`, `bin/`, `mcp/` directories
- `agents/.agents/mcp/router/node_modules/` — ~6,600 files from the MCP router's own dependencies (including `@hono/node-server`, etc.)
- `agents/.agents/mcp/router/.pid` — a live runtime PID file

### AC verification results

| AC | Status | Evidence |
|----|--------|---------|
| `package.json` contains a `files` array listing `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE` | ✅ PASS | Verified: `python3 -c "import json; print(d.get('files'))"` returns the exact list |
| `npm pack --dry-run` does not include `project/`, `jobs/`, `.jenga_paths`, `node_modules/` (root), or board/queue/log files | ✅ PASS (root-level) / ⚠️ REMARK (nested) | Root-level exclusions confirmed. However, `agents/.agents/mcp/router/node_modules/` IS present in the tarball output as a nested subtree |
| `npm pack --dry-run` confirms expected framework files are included | ✅ PASS | `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE` are all listed |

### Stats discrepancy
| Metric | Developer reported | Actual (current) |
|--------|-------------------|-----------------|
| Total files | 142 | 6,700 |
| Unpacked size | 542.3 kB | 29.1 MB |

The discrepancy is entirely attributable to `agents/.agents/` being absent at verification time (commit `8e708e5`) but present now due to postinstall running locally.

---

## Findings

| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | `agents/.agents/` untracked directory is bundled by `npm pack` | High | Contains ~6,600 `node_modules/` files; 29.1 MB instead of expected ~542 kB |
| 2 | `agents/.agents/mcp/router/.pid` (live PID file) included in tarball | Medium | A runtime process ID file has no place in a published package |
| 3 | No `.npmignore` exists to guard against accidental inclusion of artifacts | Medium | Without `.npmignore`, `files` array alone is insufficient if artifacts land in listed directories |

---

## Impact
- If `npm publish` is run from the current working directory, consumers would receive a 29 MB package instead of ~542 kB
- The nested `node_modules/` from MCP router would be installed into consumer projects, potentially causing dependency conflicts
- Remaining tasks in E26_S02 (T04: smoke test) should account for this finding before proceeding to publish

---

## Suggested Next Steps
1. **Add `agents/.agents/` to `.gitignore`** — this directory is a runtime artifact and should never be committed or packaged.
2. **Add a `.npmignore` file** as a secondary safety net listing runtime artifacts: `.agents/`, `jobs/`, `project/`, `*.pid`, etc.
3. **Re-run `npm pack --dry-run`** after cleanup and confirm file count is ~142 and size is ~542 kB.
4. **Consider a pre-publish script** (`npm run prepublishOnly`) that checks for the absence of unintended directories before allowing publish.

---

## Ignore Log
_Only populated by the developer when this rapport is marked `.IGNORE.md`._

**Ignored by:**
**Date:**
**Reason:**

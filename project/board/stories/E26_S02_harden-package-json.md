---
id: E26_S02
epic_id: E26
title: Harden package.json for npm publishing
status: Passed
date_created: 2026-07-31
date_started: 2026-07-31
date_completed: 2026-07-31
dates_previously_completed:
reopened_on:
reopened_reason:
docs: ["README.md"]
tasks:
  - E26_S02_T01
  - E26_S02_T02
  - E26_S02_T03
  - E26_S02_T04
---

# Story: Harden package.json for npm publishing

As a framework maintainer, I want `package.json` to be correctly configured for public npm publishing so that running `npm publish` produces a clean, correctly scoped package that installs framework files into consumer projects.

## Acceptance Criteria
- [ ] `package.json` has a `files` array that includes exactly: `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/`, `bin/`, `README.md`, `LICENSE`
- [ ] `package.json` has `publishConfig: { "access": "public" }`
- [ ] `package.json` has a `postinstall` script (or equivalent `bin` command) that copies framework files into the consumer project root when `npm install` is run in a consumer project
- [ ] The postinstall/install hook does not overwrite files that already exist unless the installed version is newer (safe upgrade behaviour)
- [ ] `npm pack --dry-run` from the repo root lists only the files declared in `files` — no `project/`, `node_modules/`, `.jenga_paths`, or board files are included
- [ ] Package name is confirmed as `jenga-agent` (or the chosen name is documented as a decision in the epic)

## Definition of Done
- [x] `package.json` contains `files`, `publishConfig`, and a `postinstall` or `install` script
- [x] `npm pack --dry-run` output is reviewed and contains no unintended files
- [x] Postinstall script exists at `scripts/postinstall.js` (or equivalent) and is executable
- [x] At least one manual smoke test confirms that `npm install <tarball>` in a fresh directory results in framework files appearing in the expected locations

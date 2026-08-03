---
name: doc-sync
description: Compare the current state of a project with its documentation and update documentation to reflect changes. Accepts `update:`, `source:`, `exclude:`, and `minify:` arguments to control scope. Use when documentation may be out of date with implementation, or when the user asks to sync, refresh, update, or shrink docs.
keywords:
  - doc-sync
  - documentation
  - update docs
  - sync docs
examples:
  - "update the documentation"
  - "sync docs with current state"
---

# Doc-Sync — Keep Documentation in Sync with the Codebase

## What this skill does

Analyses project source files, compares them against existing documentation, and updates any documentation that is stale, incomplete, or missing. Can be scoped with arguments to focus on specific files or exclude noise.

---

## Argument Parsing

Before doing anything, check the user's message for arguments. Arguments may appear in any order and may be combined in a single invocation.

| Argument | Format | Meaning |
|---|---|---|
| `--update:` | `update: <path(s)>` | Documentation file(s) to check and update. Comma or space-separated. |
| `--source:` | `source: <path(s)>` | Source file(s) or director(ies) to prioritize when analysing changes. Comma or space-separated. |
| `--exclude:` | `exclude: <path(s)>` | File(s) or director(ies) to skip entirely — neither read as source nor updated. Comma or space-separated. |
| `--minify:` | `minify: <percent>` | Reduce each target documentation file by approximately N% by removing redundant and non-essential content. Defaults to `70` (i.e. scale down to 70% of original size) if no value is given. |

**Examples:**
- `doc-sync update: docs/API.md source: src/api/`
- `doc-sync exclude: node_modules, dist update: README.md`
- `doc-sync source: src/auth/ update: docs/auth.md, docs/security.md`
- `doc-sync minify: 50 update: docs/API.md`
- `doc-sync minify: update: README.md` *(uses default 70%)*

All paths are interpreted relative to the project root.

---

## Instructions

### 1. Parse arguments

Extract any `update:`, `source:`, `exclude:`, and `minify:` values from the user's message.
- Store each as a list: `update_targets`, `source_paths`, `exclude_paths`.
- Store `minify` as a number `minify_pct`. If the `minify:` key is present but has no value, default to `70`. If `minify:` is absent entirely, set `minify_pct` to `null` (no minification).
- Merge `exclude_paths` with the default excludes from `assets/default_excludes.txt`.

### 2. Resolve update targets

If `update_targets` is **not empty**, use those paths as the documentation files to update.

If `update_targets` is **empty**, resolve targets from `assets/doc_targets.md`:
- Read the file and parse the **Documentation Targets** list.
- Each entry is a relative path to a documentation file to keep up to date.
- If no entry matches an existing file, skip it and note it as missing.

If neither source has targets (no arguments and no doc_targets), scan the project for documentation files:
- Look for `*.md`, `docs/`, `documentation/`, `project/documentation/`, `README*`, `CHANGELOG*`, `CONTRIBUTING*`.
- Ask the user: *"I found the following documentation files. Which should I update?"* — present the list and let them select.

### 3. Resolve analysis sources

If `source_paths` is **not empty**, read those files and directories (recursively if directories).

If `source_paths` is **empty**, infer sources from each update target:
- Read the existing content of the documentation file.
- Look for mentions of paths, module names, function names, or API routes that hint at what code it describes.
- Use those hints to locate relevant source files in the project.
- Fall back to a broad scan of common source directories (`src/`, `lib/`, `app/`, project root) if no hints are found.

Apply `exclude_paths` at this step — skip any file or directory matching an excluded path.

### 4. Analyse for drift

For each update target and its resolved sources:

1. **Read the documentation file** — understand what it currently claims (structure, API, config, behaviour, examples).
2. **Read the source files** — extract the current reality (exported functions, routes, config keys, CLI flags, env vars, class names, etc.).
3. **Compare** — identify:
   - Sections that reference removed or renamed things.
   - Missing documentation for new things added in source.
   - Outdated examples, wrong flag names, stale code snippets.
   - Incorrect or missing configuration keys/values.

### 5. Report findings before updating

Before making any writes, present a concise drift summary per file:

```
📄 docs/API.md
  ✏️  /api/users route renamed to /api/members in source
  ➕  New endpoint POST /api/invites not documented
  🗑️  Reference to deprecated `--verbose` flag still present

📄 README.md
  ✏️  Setup instructions reference Node 16; project now requires Node 20
  ➕  New environment variable DATABASE_URL not listed
```

Ask: *"Should I apply all updates, or skip any of these?"*

### 6. Apply updates

For each approved update:
- Edit the documentation file in-place — preserve existing structure, tone, and formatting.
- Replace stale references with accurate ones.
- Add new sections or entries for undocumented items.
- Remove or mark deprecated items with a note if full removal seems too aggressive (ask when uncertain).
- Do not alter sections that appear unrelated to the analysed source files.

### 6a. Minify (if `minify_pct` is set)

After sync edits are applied (or if only minification was requested), reduce each target file to approximately `minify_pct`% of its current size:

**What to remove — in priority order:**
1. Duplicate explanations of the same concept said in multiple ways.
2. Verbose prose that restates what a code example already shows clearly.
3. Historical context, changelogs, or migration notes buried in reference docs.
4. Filler phrases ("It is important to note that…", "As mentioned above…").
5. Redundant examples where one concise example covers the same case as two or three longer ones — keep the most illustrative, remove the rest.
6. Section headers with no meaningful content beneath them.

**What to keep — never remove:**
- All unique technical facts (function signatures, config keys, env vars, routes, types).
- Code examples that demonstrate something not expressed in prose.
- Warnings, caveats, and known limitations.
- Installation and setup steps.

**Process:**
1. Calculate the current character count of the file.
2. Target size = `current_size × (minify_pct / 100)`.
3. Remove content following the priority list above until the file is at or below the target size.
4. If the target cannot be reached without removing essential content, stop at the smallest safe size and note the actual reduction achieved.
5. Do not rewrite or paraphrase kept content — only remove.

### 7. Summarise changes

After all writes are done, print a summary:

```
✅ Updated 3 documentation files:
   - docs/API.md       (2 sections updated, 1 added)
   - README.md         (setup instructions refreshed)
   - docs/config.md    (3 new env vars added)

🗜️  Minified 2 documentation files:
   - docs/API.md       (4 200 → 2 940 chars, −30%)
   - README.md         (3 100 → 2 170 chars, −30%)

⚠️  Skipped 1 file (no matching sources found):
   - docs/legacy.md
```

If nothing needed updating, print: `✅ Documentation is already in sync with the source.`
If minification could not reach the target, note: `⚠️ docs/API.md reduced to X% (target was Y% — essential content limit reached).`

---

## Reference files

- `assets/doc_targets.md` — Editable list of documentation files this skill checks by default.
- `assets/default_excludes.txt` — Paths always excluded from source analysis unless overridden.

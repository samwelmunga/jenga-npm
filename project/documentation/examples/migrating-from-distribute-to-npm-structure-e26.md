# Migrating from `/distribute` to the npm Structure (E26)

## What it is

The `/distribute` skill was a manual skill that copied framework files (skills, agents, hooks, etc.) from a source repo into consumer repos. The new **npm structure** replaces this with an automated `postinstall` hook that runs when a consumer installs `jenga-agent` via npm — and a `/self-sync` skill for the framework repo itself.

---

## Why it exists

`/distribute` required you to:
- Manually invoke the skill per-consumer-repo
- Keep track of which repos had received updates
- Hope nothing drifted between distributions

The npm model solves this: **consumers get updates automatically on `npm install`** and the framework repo syncs its own mirrors with `/self-sync`.

---

## How it works

### Consumer side (`postinstall.js` + `lib/mirror.js`)

When a consumer runs `npm install jenga-agent`:

1. `scripts/postinstall.js` fires automatically.
2. It detects whether it's a first install or an upgrade (via `.jenga-version` semver comparison).
3. It copies `skills/` and `agents/` into **both** `.claude/` (Claude Code path) and `.agents/` (Copilot/custom path).
4. All other dirs (`hooks/`, `scripts/`, `templates/`, `lib/`, `mcp/`) are sourced from `node_modules/jenga-agent/…` at runtime — no duplication.
5. `.jenga-version` is written to record the installed version.

### Framework-repo side (`/self-sync`)

When you edit a skill/agent/hook inside the framework repo itself:

1. Run `/self-sync` (or `node skills/self-sync/scripts/run.js`).
2. It mirrors the full copy set (`bin/`, `lib/`, `scripts/`, `agents/`, `hooks/`, `mcp/`, `skills/`, `templates/`, `settings.json`) into `.claude/` and `.agents/` inside this repo.
3. Supports `--dry-run` to preview what would change.
4. Uses `reconcileDeletes: true` — orphaned files in the mirrors are deleted.

All mirroring logic is centralised in **`lib/mirror.js`**, the single source of truth shared by both paths.

---

## When to use which

| Scenario | What to use |
|---|---|
| You edited a skill/agent/hook in the framework repo | `/self-sync` |
| A consumer project needs updated framework files | `npm install jenga-agent` (automatic) |
| You want to preview what will change | `/self-sync --dry-run` |
| First time setting up a consumer project | `npm install jenga-agent` — postinstall handles everything |

**Never manually edit `.claude/` or `.agents/`** — they are generated outputs overwritten on every sync.

---

## Migration steps (before → after)

### Before (old `/distribute` workflow)

```bash
# In the framework repo, you'd run a skill that manually pushed files to consumer repos
/distribute consumer-project-path
```

You maintained a list of consumer paths and ran distribute manually after every change.

### After (npm structure)

**Framework repo — editing skills:**
```bash
# 1. Edit the canonical file in the root (e.g., skills/my-skill/SKILL.md)
# 2. Sync it into the in-repo mirrors:
node skills/self-sync/scripts/run.js
# OR use the skill:
# /self-sync
```

**Consumer project — getting updates:**
```bash
# Just bump the version in package.json and reinstall:
npm install jenga-agent@latest
# postinstall automatically copies updated skills/ and agents/ into .claude/ and .agents/
```

**Verifying the installed version:**
```bash
cat .jenga-version   # shows the currently installed semver
```

---

## Key files

| File | Role |
|---|---|
| `scripts/postinstall.js` | Consumer install hook — runs on `npm install` |
| `lib/mirror.js` | Shared mirroring engine (boundary-checked, dry-run capable) |
| `skills/self-sync/SKILL.md` | In-repo sync skill (replaces `/distribute` for dev use) |
| `skills/self-sync/scripts/run.js` | CLI entry point for `/self-sync` |
| `.jenga-version` | Records the last installed package version in consumer root |

---

## Summary

| Old | New |
|---|---|
| `/distribute` (manual, per-consumer) | `npm install` + `postinstall.js` (automatic) |
| Manual file push to consumer repos | Semver-gated copy on install |
| In-repo sync was undefined | `/self-sync` (explicit, dry-runnable) |
| Single copy path | Canonical root dirs → mirrors (`.claude/`, `.agents/`) |

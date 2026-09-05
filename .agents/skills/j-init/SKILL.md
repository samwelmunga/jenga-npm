---
name: j:init
description: Polyfill alias of the init skill under a collision-safe directory name. Identical behavior to /init — initializes a new project with the standard directory structure, PROJECT_SUMMARY.md, workflow.json, git repo, and gitignore. Use when the built-in "/init" command (e.g. GH Copilot's own init) shadows Jenga's /init alias.
keywords:
  - init
  - initialize
  - setup
  - new project
  - scaffold
  - j-init
  - polyfill
examples:
  - "initialize a new project"
  - "set up a new workspace"
  - "j-init"
---

# J-Init — Project Setup (polyfill alias of Init)

This skill is a literal-directory-name duplicate of `skills/init/`. It exists because
some host tools/harnesses (e.g. GH Copilot) ship their own built-in command literally
named `/init`, which can shadow or override Jenga AI's own `/init` alias (Claude Code's
native skill resolution is a literal-string, directory-name-based match — see
`docs/skill-authoring.md`'s "Invocation Convention"). `/j-init` (and `j:j-init`) give
users a guaranteed-unshadowed way to reach the exact same setup flow.

Keep this file's instructions in lockstep with `skills/init/SKILL.md` — any change made
there should be mirrored here.

## Instructions

Follow these steps in order. Do not skip steps — the sequence matters.

### 1. Detect existing project state

Before asking anything or scaffolding anything, classify the target directory
(the current directory) by running the detection script:

```bash
skills/j-init/scripts/detect-existing-codebase.sh .
```

It prints exactly one verdict on stdout:

| Verdict | Meaning | What to do |
|---|---|---|
| `empty` | The directory is empty, or contains only `.git`, `.gitignore`, and top-level `README*`/`LICENSE*` boilerplate. | Proceed to step 2 — behaviour here is unchanged from before this detection step existed. |
| `already-scaffolded` | `project/board/`, `project/PROJECT_SUMMARY.md`, or `project/configs/workflow.json` already exists. | Tell the user this directory already has a Jenga scaffold and **stop** — do not run the scaffold script. Re-running it would silently overwrite `PROJECT_SUMMARY.md` and `workflow.json` with fresh stubs. Point them at `/continue` or `/status` instead. |
| `existing-codebase` | The directory has real content (source, configs, docs beyond the boilerplate list) and is not already scaffolded. | **Pause. Do not scaffold.** Present the choice below and wait for an answer. |

On `existing-codebase`, present this choice verbatim, per the Interaction Pattern in
`CLAUDE.md` (numbered, free-text last):

    This directory already contains code that wasn't built through Jenga. How would
    you like to proceed?
    1. Run /uncharted onboard first, to analyze the existing code and backfill the
       board before scaffolding
    2. Scaffold fresh anyway, leaving the board empty (the existing code is never
       modified either way — onboard mode and fresh scaffolding are both board-only)
    3. Abort — don't scaffold, don't run /uncharted
    4. Other (describe below)

- **Option 1** — invoke `/uncharted onboard`. It analyzes the existing code and backfills
  the board; it never modifies, moves, or restructures application code. Once it
  finishes, the directory now has `project/PROJECT_SUMMARY.md` etc., so re-running this
  detection step returns `already-scaffolded` — there is nothing left to scaffold.
- **Option 2** — continue to step 2 and scaffold fresh. Note in your response that the
  board will start empty despite the directory containing pre-existing code, since the
  user explicitly chose that.
- **Option 3** — stop here. Do not run the scaffold script and do not invoke `/uncharted`.
- **Option 4** — handle the free-text response on its own merits.

If the run is non-interactive (no user available to answer), default to **option 3
(abort)**. Unlike the visibility question in step 2, none of these three choices is a
no-op: running `/uncharted onboard` unattended commits an analysis pass the user never
asked for, and scaffolding fresh unattended silently discards pre-existing code from the
board exactly as `/init` did before this step existed. Aborting is the only choice that
changes nothing on disk, so it is the only safe default.

Never treat `existing-codebase` as if it were `empty`, and never skip straight to step 2
on that verdict without the user (or the non-interactive default) choosing to.

### 2. Ask how Jenga AI's working files should appear

Ask the user this question, verbatim, before running any script:

    How should Jenga AI's own working files (project/ — the scrum board, todo.md,
    queue/, rapports/, and logs/) appear in this project?
    1. Visible — keep them at `project/`, tracked and visible in directory listings
    2. Ignored — keep them at `project/` but add them to `.gitignore` so they are never committed
    3. Not sure — explain the trade-offs and ask me again

If the user picks option 3, explain the trade-offs and re-ask. Do not proceed until
the answer is one of `visible` or `ignored`.

If the run is non-interactive (no user available to answer), use the default:
**`visible`**. It is the only choice that changes nothing on disk, so an unattended
run can never silently relocate directories or edit `.gitignore`.

> A third mode, `hidden` (dot-prefixing `project/` to `.project/`, matching the
> `.agents/`/`.claude/` convention), was built and then withdrawn before release —
> testing found it left board resolution and session-end hooks writing to two
> different trees. It is not offered here. See
> `skills/distribute/CONFIG_SCHEMA.md` for the root-cause note and the tracked
> follow-up to reintroduce it once fixed.

Carry the chosen value into step 3. Do not apply it yourself — the script owns all
of the mechanical work.

### 3. Run the scaffold script

`init.sh` is not guaranteed to live at a single fixed path: in a project that
installed Jenga via npm, it was mirrored to `.claude/skills/j-init/scripts/`
(Claude Code) and `.agents/skills/j-init/scripts/` (Copilot/other agents) by
`postinstall.js`, and neither of those exists yet in this framework's own
source checkout, where it lives at the bare `skills/j-init/scripts/` path
instead. This step runs before `CLAUDE.md`/`AGENTS.md` exist, so it cannot
rely on either file's routing instructions to resolve the path — it must
locate its own script directly. Execute the init script from the project
root, passing the choice from step 2:

```bash
INIT_SCRIPT=""
for candidate in .claude/skills/j-init/scripts/init.sh .agents/skills/j-init/scripts/init.sh skills/j-init/scripts/init.sh; do
  [[ -f "$candidate" ]] && { INIT_SCRIPT="$candidate"; break; }
done
if [[ -z "$INIT_SCRIPT" ]]; then
  echo "Error: could not locate init.sh under .claude/skills/, .agents/skills/, or skills/" >&2
  exit 1
fi
chmod +x "$INIT_SCRIPT" && "$INIT_SCRIPT" --visibility <visible|ignored>
```

Omitting `--visibility` falls back to the `JENGA_PROJECT_FILES_VISIBILITY`
environment variable, then to `visible`.

This script handles all scaffolding in one step:
1. Initializes the git repository
2. Creates `.gitignore`
3. Creates the full directory structure under `project/`
4. Creates `project/PROJECT_SUMMARY.md` with placeholder content
5. Creates `project/configs/workflow.json` with shared constants
6. Creates `project/configs/test-config.json` stub
7. Creates `project/configs/scope-thresholds.json` with default execution-scope thresholds (consumed by `/jenga` and `/do`, which halt if it's missing)
8. Creates `project/data/baselines.json`
9. Creates `project/logs/events.json`
10. Creates `docs/STRATEGY.md` — a strategic brief stub intended for investors, partners, and the product team
11. Creates `CHANGELOG.md` from the shared template — a running log of notable changes, seeded with an `[Unreleased]` section
12. Applies the chosen visibility mode via `scripts/apply-project-visibility.sh`, which records it as `project_files_visibility` in `jenga.config.json` and performs any `.gitignore` change
13. Stages and commits all files with the message `init: scaffold project structure and workflow config`

The visibility mode is validated before any scaffolding happens, so an invalid
value fails fast and leaves nothing behind. It is applied before the commit, so
the `.gitignore` entry is captured in the initial commit.

If the script fails, check that you are in the project root and that git and `jq`
are available.

See `skills/distribute/CONFIG_SCHEMA.md` for the full `project_files_visibility`
field reference.

### 4. Prompt next step

Inform the user that setup is complete, and state which visibility mode was applied
and where the working files now live. Mention that `docs/STRATEGY.md` was created as
a strategic brief stub for investors, partners, and the product team — they can fill
it in now or return to it later. Suggest running `/pi-plan` to define project goals
and epics.

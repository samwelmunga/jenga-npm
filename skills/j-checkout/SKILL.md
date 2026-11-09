---
name: j.checkout
description: Set, inspect or clear this session's perceived branch without moving the real checkout. `j.checkout <branch>` makes task worktrees start from that branch (asking first if it does not exist yet), bare `j.checkout` shows the perceived and the real branch together, and `j.checkout --clear` drops the perceived branch. The board and its commits stay on the real branch.
keywords:
  - perceived branch
  - work on branch
  - switch session branch
  - set working branch
  - clear perceived branch
  - j-checkout
examples:
  - "j.checkout feature/login"
  - "which branch am I working on"
  - "work on the release branch for this session"
  - "j.checkout --clear"
  - "stop using the perceived branch"
---

# Checkout - the Session's Perceived Branch

`skills/j-checkout/` is the canonical directory for this skill; the frontmatter name is `j.checkout`, never `j.j-checkout` (see `project/documentation/skill-authoring.md`, "The Canonical Naming Contract").

A **perceived branch** lets this session work against a branch other than the one that is checked out, without moving the checkout. This skill is only presentation and one confirmation. Every deterministic step, including every git operation, lives in `scripts/perceived-branch.sh`; this skill never runs git itself.

## Instructions

Resolve the script once:

```bash
PB="$([ -f scripts/perceived-branch.sh ] && echo scripts/perceived-branch.sh || echo node_modules/@jenga-ai/agent/scripts/perceived-branch.sh)"
```

### 1. Dispatch on the argument

| Invocation | What to do |
|---|---|
| `j.checkout <branch>` | Section 2 |
| `j.checkout` (bare) | Section 3 |
| `j.checkout --clear` | Section 4 |

Match the argument exactly. Anything else (several words, an unknown flag) is not a form of this skill: print the three forms above and stop, without running the script.

### 2. `j.checkout <branch>`

1. Run `bash "$PB" exists <branch>`.
   - Exit 0 (the branch exists): run `bash "$PB" set <branch>` and go to step 3.
   - Exit 1 (it does not exist): **ask before creating anything**, as a numbered list with free text last:

         The branch <branch> does not exist. What would you like to do?
         1. Create <branch> from the current branch and set it as the perceived branch
         2. Cancel (nothing is created or changed)
         3. Other (describe below)

     Only on option 1 run `bash "$PB" set <branch>`, which creates the branch and records it. On option 2 stop and change nothing. On option 3 follow the user's description; if it names a different branch, restart from step 1 with that name.
2. If `set` exits non-zero, show its stderr message verbatim and stop. Exit 2 is an invalid branch name and exit 7 means no session key could be resolved; explain either in one sentence, never retry silently, and never work around the script.
3. Confirm with the perceived and real branch together (Section 3's output) and add the standing statement below.

### 3. Bare `j.checkout`

Run `bash "$PB" get --perceived` and `bash "$PB" get --real` and show them together, so a difference is always visible:

    Perceived branch: <branch>
    Real branch:      <branch>

- If `get --perceived` prints nothing (exit 1), no perceived branch is set: say so, for example `Perceived branch: none set (this session follows the real branch)`, and still show the real branch.
- If `get --real` prints nothing (exit 1, a detached HEAD), say there is no real branch rather than guessing one.
- Pass on any notice the script writes on stderr (for example, that the recorded branch no longer exists).

### 4. `j.checkout --clear`

Run `bash "$PB" clear`, then `bash "$PB" get --real`, and report that the perceived branch is cleared and which branch this session now follows. Clearing when nothing is set is not an error; relay the script's notice and say nothing was set.

### 5. State this plainly, every time

Close every successful `set` and every `--clear` with these facts in the output (a bare `j.checkout` may shorten them to one line):

- **The real checkout does not move.** The checked-out branch and the working files in the main tree stay exactly as they were.
- **The board stays on the real branch.** Task and story status writes and board commits are made on the real branch, never on the perceived one.
- Only task worktrees follow the perceived branch: new worktrees start from it, and finished task work is merged into it.

## Notes

- The perceived branch belongs to this session alone, is cleared when the session ends, and is never shared with another session.
- This skill takes no action beyond the one script call per section; it adds no formatting logic, no branch-name validation and no session handling of its own.

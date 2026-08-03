---
name: reconcile-origin
description: Sync the current (or specified) branch with origin by rebasing local commits on top of the latest upstream state.
keywords:
  - "sync branch"
  - "rebase origin"
  - "reconcile origin"
  - "pull rebase"
examples:
  - "sync my branch with origin"
  - "rebase local commits on top of origin"
  - "reconcile-origin feature/my-branch"
---

# Reconcile Origin

Use this skill to rebase local work on top of the latest `origin/<branch>` state without re-implementing git logic inline.

## Instructions

1. Determine the target branch:
   - If the user passed an argument, use that branch name.
   - Otherwise, use the current branch name.

2. Invoke `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh [<branch>]` and capture stdout.
   - Do not run any inline git commands in this skill — all git work is handled by the script.
   - The script handles dirty-worktree detection internally and returns `{"status":"error","code":"uncommitted_changes",...}` if the working tree is not clean.

3. Parse the script's JSON response and react by `status`:
   - `ok`
     - Report success.
     - Include the branch name and `rebased_commits` count.
   - `local_branch_missing`
     - If `remote_exists` is `true`, present options in this format:

       What would you like to do?
       1. Create a local tracking branch for `<branch>` and continue `/reconcile-origin`
       2. Cancel and inspect the branch setup manually
       3. Other (describe below)

     - If the user chooses option 1, invoke `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh <branch> --create-tracking`.
     - If `remote_exists` is `false`, explain that neither a local branch nor `origin/<branch>` was found and stop.
   - `conflict`
     - Present one structured conflict rapport per item in `conflicts`.
     - For each conflict include:
       - File path
       - The `description`
       - `local_section`
       - `origin_section`
     - Then present options in this format:

       What would you like to do?
       1. Resolve the conflict now by merging both sides carefully
       2. Keep the local intent, then re-apply the essential upstream change manually
       3. Handle it later — leave annotated conflict markers in the file and continue the scripted flow
       4. Other (describe below)

     - If the user chooses “Handle it later”, invoke `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh <branch> --handle-later <file>` for the selected conflict file.
   - `handled_later`
     - Confirm that the selected file was annotated for later resolution.
     - Tell the user the conflict markers were intentionally preserved with a `# RECONCILE-ORIGIN CONFLICT:` note.
   - `error`
     - Report the script's `message` clearly.
     - If `code` indicates `branch_not_found_on_origin`, explain that the remote branch could not be fetched.
     - If `code` indicates `uncommitted_changes`, remind the user to stash or commit first.

4. When presenting a conflict rapport, make the incompatibility explicit.
   - Explain what the local section is trying to preserve.
   - Explain what the origin section changed upstream.
   - Recommend at least two concrete resolution paths before offering “Handle it later” as the final actionable option.

## Guard Rails

- All git work must go through `.agents/skills/reconcile-origin/scripts/reconcile-origin.sh`.
- Do not inline fetch, checkout, pull, merge, rebase, or status commands in this skill body.

# Client commit fact sheet (epic E79)

Fill-in template for the client facts that decide the design of project-specific commit formats
(`project/documentation/plans/project-specific-commit-conventions.md`, solution assessment Problem 2; epic `E79`
Open Decisions 3, 4, 6 and 7). Someone who can ask the client fills in each `Answer:` line. Nothing is answered
here: every answer starts as `UNKNOWN`, and `UNKNOWN` must never be read as "no" or "yes".

## 1. Merge method

- **Question:** How are task branches and pull requests merged into the target branch?
- **Allowed answers:** merge commit | squash | rebase | fast-forward (give one per target branch if they differ).
- **How to find out:** repository merge settings (GitHub: Settings > General > Pull Requests), the branch protection
  rules, or the last 10 merges in `git log --first-parent --merges`.
- **Answer:** UNKNOWN

## 2. Squash-body behaviour

- **Question:** When commits are squashed, does the resulting commit keep the bodies and trailers of the squashed commits?
- **Allowed answers:** keeps bodies and trailers | keeps the pull-request title and description only | keeps
  subject lines only | not applicable (no squash).
- **How to find out:** the repository's "default commit message" setting for squash merges, or compare one squashed
  commit on the target branch with the commits of its pull request.
- **Answer:** UNKNOWN

## 3. Commit message rules for body and footers

- **Question:** What do commitlint (or an equivalent hook or CI check) rules say about a body, a footer or trailer
  such as `Jenga-Task: E79_S01_T03`, line length and forbidden tokens?
- **Allowed answers:** body allowed (yes/no) | footer or trailer allowed (yes/no) | maximum line length (number) |
  forbidden tokens (list) | no rules.
- **How to find out:** `commitlint.config.*`, `.commitlintrc*`, a `commitlint` key in `package.json`, the CI
  workflow files, and `.husky/` or `.git/hooks/` contents.
- **Answer:** UNKNOWN

## 4. Hooks in task worktrees

- **Question:** Do the client's commit hooks run in a linked git worktree, must they run, and do they work there?
- **Allowed answers:** run and work | run but fail (for example missing `node_modules` or `core.hooksPath`) | do not
  run | must run, no bypass allowed | no hooks.
- **How to find out:** create a linked worktree, make a throwaway commit and watch for hook output.
- **Answer:** UNKNOWN

## 5. Housekeeping commits

- **Question:** Must `chore(board)`, roll-up, merge, `chore(self-sync)` and mirror commits carry a ref (Open
  Decision 6), or may they keep their Jenga forms?
- **Allowed answers:** carry a ref | keep Jenga forms | mixed (list which kinds).
- **How to find out:** ask the client whether any hook or tracker integration rejects or ignores commits without a ref.
- **Answer:** UNKNOWN

## 6. Traceability horizon

- **Question:** How long must a commit stay traceable to a task id, and what is acceptable after a squash-merge
  (Open Decision 3)? The plan proposes `reconcile` on a fresh clone 90 days after a client merge.
- **Allowed answers:** a duration plus the operations it must survive (rebase, squash, fresh clone) | accept loss
  after squash-merge | other.
- **How to find out:** ask who runs `reconcile` and `close-story`, and on which clone, relative to client merges.
- **Answer:** UNKNOWN

## 7. Jira key cardinality

- **Question:** Is a Jira key unique per Jenga task, or shared across many tasks (Open Decision 7)?
- **Allowed answers:** unique per task | shared per story | shared per epic or feature | mixed.
- **How to find out:** compare a few finished Jira issues with the board tasks that implemented them.
- **Answer:** UNKNOWN

## What each answer decides

| Fact | Answer | Design consequence |
|---|---|---|
| 1, 2 | Squash that drops bodies and trailers | The `Jenga-Task:` trailer is lost on merge; the id-free mapping modes of Phase 3 become relevant. |
| 3 | Body, footer or trailer forbidden | Same as above: the plan's Phase 3 trigger (client forbids any body content) fires, and reduced durability must be accepted explicitly. |
| 3 | Trailer allowed, line-length limit | The composer must wrap or validate the trailer against the limit. |
| 4 | Hooks fail in worktrees | The hook probe (Phase 2) is required and `--no-verify` is never an acceptable workaround. |
| 5 | Housekeeping commits must carry a ref | Per-kind scope (Phase 2) is needed; otherwise they keep Jenga forms and nothing changes for them. |
| 6 | Long horizon across squash | The trailer must survive squash (fact 2), or Phase 3 modes are mandatory. |
| 7 | Key shared across tasks | The ref cannot be a trace key; the `Jenga-Task:` id stays the trace key, and external-key mode (Phase 3) is not viable. |

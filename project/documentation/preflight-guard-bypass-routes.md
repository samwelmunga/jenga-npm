# What can and cannot defeat the pre-flight guard from a subagent (E89_S06_T14)

Evidence record for `hooks/on_preflight_check.sh`, the `PreToolUse` guard registered with matcher
`Bash|Task|Agent`. It answers one question: from inside a subagent, which routes complete a gated
operation without the guard firing, and which do not.

## The disproved premise (kept on purpose)

The task was filed on the premise that a subagent defeated the guard with `git commit --no-verify` and
`-c core.hooksPath=...`. That premise is **false**, and is kept here so it is not re-derived:

- The guard is a **harness** hook. It fires on the tool call, before git runs.
- `--no-verify` and `core.hooksPath` are **git-level** and only affect git hooks. This repository installs
  none (`.git/hooks/` holds only `.sample` files).
- Observed: both are refused exactly like a bare `git commit` (routes B and C below).

## Method

Everything ran in an isolated throwaway repository under the session scratchpad, with its own copy of
`hooks/` and `scripts/`, its own `project/configs/checklists.json` (one `block` machine item whose verify is
`false`, situation `pre-commit`), its own `TMPDIR`, and `JENGA_PROJECT_ROOT` pinned to it, so the marker it
wrote lives only there. The real repository's `settings.json`, marker store and refs were not touched and
nothing was pushed. Each route's command string was fed to the real hook as a harness payload
(`{"tool_name":"Bash","tool_input":{"command":...}}`) with a `pre-commit` marker active; routes the hook
allowed were then executed in the lab repository to confirm they really create a commit.

## Observed outcomes (pre-commit marker active, one failing `block` item)

| Route | Command (abridged) | Hook | Notes |
|---|---|---|---|
| A control | `git commit --allow-empty -m x` | DENIED | baseline |
| B | `git commit --no-verify ...` | DENIED | git flag does not reach the harness hook |
| C | `git -c core.hooksPath=/dev/null commit ...` | DENIED | same |
| D | `git commit-tree HEAD^{tree} -p HEAD -m x` | DENIED | the loose `*git*commit*` glob matches `commit-tree` |
| E | `git hash-object -t commit -w --stdin` | DENIED | `-t commit` matches the glob |
| G | `bash -c 'git commit ...'` | DENIED | the literal text is in the command string |
| F | `bash ./c.sh` (script containing `git commit`) | **ALLOWED** | commit really created in the lab |
| H | `g=g; $g"it" comm"it" ...` | **ALLOWED** | commit really created in the lab |
| M | `git ci ...` (alias `ci = commit` set earlier) | **ALLOWED** | commit really created in the lab |
| I | `git cherry-pick ...` | **ALLOWED** | creates a commit; not in the pre-commit gate set |
| J | `git revert --no-edit HEAD` | **ALLOWED** | same |
| K | `git fast-import < stream` | **ALLOWED** | same |
| L | `python3 -c "subprocess.run(['g'+'it','comm'+'it',...])"` | **ALLOWED** | string built at runtime |
| N | `git update-ref refs/heads/main <sha>` | **ALLOWED** | moves a ref without a commit command |
| O | `rm -f project/queue/.../marker-*.json` | **ALLOWED** | `rm` is not a gated operation, so the marker can be deleted |
| P | `checklist-marker.sh clear --all` | **ALLOWED** | clearing the marker is deliberately never gated |

Not run empirically: a mid-session edit of `settings.json`. A lab repository has no harness, so the claim
cannot be exercised there. It is recorded by inspection: the matcher is `Bash|Task|Agent`, so the Edit and
Write tools never invoke the hook, and the same is true of an Edit/Write of the marker file or of
`project/configs/checklists.json` (which could downgrade a `block` item to `advisory`). Whether the harness
re-reads an edited `settings.json` within the running session was not established.

## Conclusion

There are real routes. The guard is a pattern match on the command **text**, so it is strong against the
plain commands it names (including plumbing such as `commit-tree`, and git-level flags) and weak against
anything that does not put those words in the command string: a script or interpreter that runs git
internally, runtime-built strings, git aliases, commit-creating commands outside the phase's gate set
(`cherry-pick`, `revert`, `am`, `rebase`, `fast-import`), ref plumbing, and anything that deletes or edits
the marker or the registry. It is a backstop against an agent forgetting, not a control against an agent
trying. The CLAUDE.md claim that it holds "at every permission level" stays true (it never consults
permission state), but "refuses the tool call" is narrowed to what it matches.

Residual risk, for the user to accept or reject: a subagent that deliberately wants to commit past a failed
`block` item can. This task does not close it; closing it would need a git-level `pre-commit` hook
(which catches every commit-creating path regardless of how it was invoked) or a protected marker, and
both are design decisions rather than documentation.

## Guidance for agents

Bypassing the guard (by any route above, or by editing the marker, registry or settings) requires the
user's explicit authorization. `--no-verify`, `core.hooksPath` and other git-level flags do not reach it and
are pointless against it; if the guard refuses, satisfy the item or stop and ask. This is stated in
`agents/tester.md` and `agents/developer.md`.

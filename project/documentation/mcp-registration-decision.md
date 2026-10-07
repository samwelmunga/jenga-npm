# MCP Server Registration Location — Decision Record

**Status:** Decided (`E65_S01_T01`, 2026-10-01). Input contract for `E65_S01_T04`
(`skills/j-connect/scripts/register-mcp.sh`).

## Decision

`j.connect` registers a vendor MCP server by merging **one entry, by server name, into the project-root
`.mcp.json`** (`<project_root>/.mcp.json`, top-level key `mcpServers`). It does **not** write
`.claude/settings.json`, and it never writes `.agents/settings.json`. Exactly one file, no dual-write.

## Evidence: which file does Claude Code read?

**Observed behaviour (verified locally, 2026-10-01, installed `claude` CLI).** In a throwaway git repo
containing:

- `.mcp.json` with `{"mcpServers":{"fx-mcpjson":{"type":"stdio","command":"/usr/bin/true","args":[]}}}`
- `.claude/settings.json` with `{"mcpServers":{"fx-settings":{"type":"stdio","command":"/usr/bin/true","args":[]}}}`

the results were:

```
$ claude mcp get fx-mcpjson
fx-mcpjson:
  Scope: Project config (shared via .mcp.json)
  Status: Pending approval (run `claude` to approve)
  ...
$ claude mcp get fx-settings
No MCP server named "fx-settings". Configured servers: ... (.mcp.json servers are awaiting approval ...)
$ claude mcp list   ->  fx-mcpjson: /usr/bin/true - Pending approval
```

Also, `claude mcp add --help` offers `--scope <local|user|project>`; `project` is the scope whose own label
reads "shared via .mcp.json". Reproduce by creating the two files above in a temp directory and running the
commands shown.

So: **Claude Code reads project-scope `mcpServers` from `.mcp.json`, and does not read `mcpServers` from
`.claude/settings.json`.** (The `local` and `user` scopes live in `~/.claude.json`, not in the project.)

**From documentation/recollection, not re-verified in this session** (official docs were not fetchable
offline; treat as to-confirm when `E65_S02`/`E65_S04` exercise a real server): `.mcp.json` supports
`${VAR}` and `${VAR:-default}` environment-variable expansion in `command`, `args`, `env`, `url` and
`headers`; and `settings.json` carries only the *approval* knobs for `.mcp.json` servers
(`enabledMcpjsonServers`, `disabledMcpjsonServers`, `enableAllProjectMcpServers`), not server definitions.

## Alternatives rejected

| Option | Why rejected |
|--------|--------------|
| `.claude/settings.json` only | Observed not to be read for `mcpServers`; a server registered there would silently never load. |
| Both `.mcp.json` and `.claude/settings.json` | Writing to a file Claude Code ignores adds nothing and creates two sources of truth; it is exactly the redundant-mirror pattern `E26` removed. |
| `.agents/settings.json` (any combination) | Reverted by `E26` (below). Not read by Claude Code. |
| `claude mcp add --scope project` (shelling out) | Not a deterministic, offline-testable script step: depends on the CLI being present and its flags. A merge script is testable with stub fixtures. May still be mentioned to users as a manual equivalent. |

## Reconciliation with `E16_S04_T04` / `E26`

`E16_S04` made `jenga attach` dual-write `mcpServers.jenga` to `.claude/settings.json` and
`.agents/settings.json` (commit `4527323`). Commit `619198b` (`E26`, "consumer install layout +
node_modules sourcing") removed the `.agents/settings.json` mirror with the rationale *"only
`.claude/settings.json` is read by Claude Code"*; `E16_S04_T04` documents that revert and leaves open
whether the dual-write should ever return. This decision is consistent with the revert's *direction* (no
dual-write, one file) and does **not** reintroduce it. It does, however, show the revert's rationale was
about the wrong file for **MCP server definitions**: `.claude/settings.json` is read for settings (hooks,
permissions, env) but not for `mcpServers`. The `E16_S04_T04` open question (does Copilot CLI or another
consumer read `.agents/settings.json`?) is unaffected and stays open; `j.connect` simply does not write it.

## Is `lib/commands/attach.js` consistent? Now yes (fixed in `E65_S07_T02`).

Originally no: `attach.js` merged `mcpServers["jenga"]` into `.claude/settings.json`, which Claude Code does not
load `mcpServers` from, so `jenga attach`'s router registration was a no-op for Claude Code's MCP loader (the
file's `hooks` handling was valid). Resolved by `E65_S07_T01` (independent re-confirmation, see the addendum
below) and `E65_S07_T02`: `jenga attach` now merges `mcpServers.jenga` into the project-root `.mcp.json` per the
registration contract below and no longer opens `.claude/settings.json`. Tests:
`tests/attach-preserves-worktree-hook.bats`.

### Migration note for existing consumers

Consumers who ran an older `jenga attach` have `mcpServers.jenga` in `.claude/settings.json`. Running the new
`jenga attach` creates/updates `.mcp.json`, leaves that old entry untouched (it is inert: Claude Code ignores it,
and attach no longer owns that file), and prints a note telling the user it can be removed by hand. After
re-running `jenga attach`, open `claude` in the project once and approve the `jenga` server (it appears as
"Pending approval"). Nothing else in `.claude/settings.json` (hooks, permissions, env) is read or modified.

## Registration contract (what `register-mcp.sh` must do)

1. **Target:** `<project_root>/.mcp.json`; created (with `{"mcpServers": {}}` as the base) only if missing.
2. **Merge by server name** under `mcpServers`:
   - absent: add the entry (`added`);
   - present and semantically identical: do nothing, file stays byte-identical (`unchanged`);
   - present and different: replace only that one entry, in place (`updated`).
3. **Never** remove, reorder, or modify any other `mcpServers` entry, nor any unrelated top-level key.
4. **Never clobber:** if the existing file is unparseable JSON, exit non-zero and leave it untouched.
   Write atomically (temp file in the same directory + `mv`).
5. **Secrets by name only:** env values are written as `${ENV_VAR_NAME}` references; the script never
   accepts, reads, or emits a secret value. `.mcp.json` is a project-shared, normally committed file, so
   because it holds only references (no values) it does not require the `.gitignore` guardrail; any file
   that *could* hold values (e.g. `.env`) goes through `ensure-secret-safe.sh` (`E65_S01_T03`) in the runner.
6. **Approval is the user's:** Claude Code shows newly added `.mcp.json` servers as "Pending approval" until
   the user approves them in `claude`. The registration step reports success for the *write*; the runner
   verifies the write, and surfaces "approve the server in Claude Code" as a `needs-user-action` note.
   The script does not edit `enabledMcpjsonServers` / `.claude/settings.json`.

## Addendum: independent re-confirmation and the `attach.js` decision (`E65_S07_T01`)

`E65_S01_T01`'s evidence was not re-confirmable by the E65 Tester offline, and the `attach.js` change rests on
it, so it was re-run independently on 2026-10-01 with the installed `claude` CLI (`2.1.236 (Claude Code)`).

**Safety:** every command ran with the working directory inside one fresh `mktemp -d` throwaway git repo (never
this repo or a worktree), with `--scope project` only (never `user` / `local`). The temp directory was deleted
afterwards. `~/.claude.json` and `~/.claude*` were not read or edited by hand. (Running `claude` at all can
update the CLI's own bookkeeping in the user's real config; that is outside this experiment's control.)

**Commands and results (verified-locally):**

```
$ claude mcp add --help          ->  -s, --scope <scope>  Configuration scope (local, user, or project) (default: "local")
$ claude mcp add --scope project fx-add -- /usr/bin/true
Added stdio MCP server fx-add with command: /usr/bin/true  to project config
File modified: <tmpdir>/.mcp.json
```

`find` of the temp directory afterwards showed exactly one new file, `.mcp.json`
(`{"mcpServers":{"fx-add":{"type":"stdio","command":"/usr/bin/true","args":[],"env":{}}}}`); no
`.claude/settings.json` was created. Then, with `.mcp.json` holding `fx-mcpjson` and `.claude/settings.json`
holding a different `mcpServers.fx-settings` entry (same stdio shape):

```
$ claude mcp get fx-mcpjson   ->  Scope: Project config (shared via .mcp.json) / Status: Pending approval
$ claude mcp get fx-settings  ->  No MCP server named "fx-settings". Configured servers: <only user-level
                                  claude.ai connectors> (.mcp.json servers are awaiting approval ...)
$ claude mcp list             ->  lists fx-mcpjson (Pending approval); fx-settings absent
```

**Verdict: CONFIRMED (for the CLI's own resolver).** `claude mcp add --scope project` writes the project-root
`.mcp.json`, and `claude mcp get` / `claude mcp list` resolve project-scope servers from `.mcp.json` and ignore
`mcpServers` placed in `.claude/settings.json`. **Could-not-verify:** (a) official Claude Code documentation was
not consulted (no network lookup was attempted here), so there is no cited docs page; (b) no interactive
`claude` session was started, so "an approved `.mcp.json` server actually launches" and the
`enabledMcpjsonServers` approval flow are unexercised. The CLI resolver is the same configuration reader the
interactive loader uses as far as can be observed, so the residual risk is judged low, but it is stated here.

**Decision for `lib/commands/attach.js`** (implemented by `E65_S07_T02`, status: done):

1. **Target:** merge `mcpServers.jenga` (`{type:"stdio", command:"node", args:[<router path>]}`) into the
   project-root `.mcp.json` per the registration contract above (create with `{"mcpServers": {}}` only if
   missing, merge by name, other entries/keys untouched, refuse and leave the file untouched if unparseable,
   atomic temp-file + rename write).
2. **`.claude/settings.json` `mcpServers` write: dropped.** It is not read for MCP servers (above), so keeping it
   would be a redundant second source of truth, which `E26` removed once already. `attach` therefore no longer
   writes `.claude/settings.json` at all: its hooks and every other key stay byte-identical because the file is
   not touched. This is **not** a dual-write; the decision is one file.
3. **`enabledMcpjsonServers` approval: not written.** Approval of project servers is the user's (registration
   contract item 6); `attach` prints a "Pending approval: run `claude` in this project and approve the `jenga`
   server" note instead of editing `.claude/settings.json`.
4. **Migration (consumers with `mcpServers.jenga` already in `.claude/settings.json`): leave it, warn.** The
   stale entry is inert (Claude Code ignores it), so deleting it buys nothing and `attach` should not mutate a
   file it no longer owns; `attach` prints a one-line note naming the file and telling the user it can be
   removed by hand. The note is informational: an unparseable or unreadable `.claude/settings.json` never makes
   `attach` fail (it is no longer a precondition) and is silently skipped for the note.
5. **What depends on the old behaviour:** `tests/attach-preserves-worktree-hook.bats` (the test "jenga attach
   writes mcpServers.jenga into the fixture settings.json", plus its header comment saying attach only touches
   `.claude/settings.json`, and the hook-preservation tests, which stay valid and now hold trivially), the
   `attach` output line `  ✓ .claude/settings.json updated`, and the stale statements in
   `project/documentation/examples/jenga-mcp-and-cli.md` (lines ~12, 85-86, 148-156, 163-164, 203-231, which
   also still describe the long-reverted `.agents/settings.json` write). No other test pins attach
   (`grep -rn attach tests/`); `lib/commands/start.js` only prints the text "jenga attach".

**Reconciliation.** `E16_S04` (`4527323`) introduced the dual-write and `E26` (`619198b`) reverted the
`.agents/settings.json` half on the premise "only `.claude/settings.json` is read by Claude Code"; that premise
is right for settings, wrong for MCP server definitions (above). This decision does not reintroduce any
`.agents/settings.json` write, and `E16_S04_T04`'s open question (does Copilot CLI or another consumer read
`.agents/settings.json`?) stays open. `jenga attach` was introduced under `E15` / `E15_S03`; `E15_S04`'s
`WorktreeCreate` commit-guard protection is preserved (stronger: `attach` no longer opens the file).

## References

`lib/commands/attach.js`; `project/board/tasks/E16_S04_T04_document-agents-settings-json-revert.md`;
`project/board/epics/E26_npm-compatible-distribution.md` (commit `619198b`); `docs/mcp-tools.md`;
`project/documentation/examples/jenga-mcp-and-cli.md`.

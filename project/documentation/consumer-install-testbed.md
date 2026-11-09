# Consumer-install testbed (E54_S03)

## Why it exists

This monorepo has bare root `scripts/` and `skills/`, so a packaged script that finds a helper relative to
the consumer's git toplevel works for everyone developing Jenga and fails for every consumer, where the
package sits under `node_modules/@jenga-ai/agent/` and the git toplevel is the consumer's own repo. Three
such defects were found by consumers in `E46`, and `scripts/mark-deployed.sh` in 4.3.0 was the fourth
(`/j-status` step 6.5 aborted with `expected script not found`).

## What it is

`tests/consumer-install-testbed.bats` plus `tests/helpers/consumer-testbed.bash`.

1. `testbed_pack` runs `npm pack --ignore-scripts` on the tree the test runs in (`prepack`, which builds the
   UI, is skipped). Under the mirror gate that tree is the mirror-shaped ship set, so what is tested is what
   would be published.
2. `testbed_consumer <dir> <shape>` creates a throwaway git project, extracts the tarball into
   `node_modules/@jenga-ai/agent` and runs `scripts/postinstall.js` with `INIT_CWD` set. No network.
3. Scenarios run from the consumer root.

| Shape | Consumer root contains | Catches |
|---|---|---|
| `clean` | nothing framework-related | helper "file missing" bugs |
| `jobo` | `skills/close-story/` (no `j-` prefix), an unrelated `scripts/` file | the 4.3.0 report's layout |
| `decoy` | `scripts/with-lock.sh` and `skills/j-close-story/scripts/update-task-frontmatter.sh` that fail when run | "wrong file found" bugs: a script that resolves from the consumer root exits 97/98 and prints `DECOY` |

## What it checks

- postinstall mirrors `skills/` and `agents/` and records `.jenga-version` equal to the package version.
- The command `j-status` step 6.5 prescribes is extracted from `SKILL.md` (`testbed_skill_command`) and run
  from each shape: exits 0, and with `--diff-file` promotes `Publicized` tasks to `Deployed to Prod`.
- The `j-close-story` `check-privatized.sh` command does the same and writes `Privatized`.
- The staged-release consumer verification steps (formerly a README section, removed from the public README because it describes internal process; the procedure now lives only in `project/.workflows/scripts/st-test-run.sh`) that can run offline: the skill
  smoke test against the package root, and the package's `populate-knowledge-graph.*.test.js` files.
- Every `node_modules/@jenga-ai/agent/<path>` that a skill or agent names exists in the package.
- **Static sweep** (`testbed_sweep_package_root_paths`): no shipped `.sh`/`.js` builds a path into
  `scripts/ skills/ templates/ lib/ agents/ hooks/ mcp/` from `$REPO_ROOT`/`$ROOT`-style variables, unless the
  same file also names the `node_modules/@jenga-ai/agent/<target>` form or uses `resolve_helper <target>`, or
  `tests/fixtures/package-root-derived-paths.allowlist` lists it with a reason. Resolve a packaged helper from
  the script's own directory (`$SCRIPT_DIR/...`); use the repo root only for the consumer's own data
  (`project/...`).

## Running it

- `bats tests/consumer-install-testbed.bats` (about 20 s), or as part of `npm test`.
- It runs in the mirror pipeline automatically: `skills/j-mirror-public/scripts/mirror.sh`'s
  `check_test_subject_invariant` runs every shipping `tests/*.bats` in a mirror-shaped tree before any push
  and refuses to push when one fails. These files are not in `.publicignore`, so they ship and are gated.
- **Against a real consumer, local only:** `TESTBED_ST_TEST=../ST-Test bats tests/consumer-install-testbed.bats`.
  The project is copied (without `node_modules`, `.next`, `.git`, tarballs, `.env`) into the test's temp
  directory and never modified. Skipped when the variable is unset.

## Adding a scenario

Build a consumer with `testbed_consumer`, add board state with `testbed_add_task`, fetch the command a skill
prescribes with `testbed_skill_command <skill> <script>`, run it from the consumer root, and assert on exit
status and the resulting board files. If a new shipped script flags in the sweep, fix it; allowlist only
maintainer-only tooling or presence probes, and say why.

## Not covered

The package's own runtime dependencies (`express`, `gray-matter`, ...) are not installed, so the dashboard API
and anything importing them are out of scope here. The real `npm install`/`approve-scripts`/`rebuild` sequence
is exercised by `j.publish stage test` against the staged tarball, not by this suite.

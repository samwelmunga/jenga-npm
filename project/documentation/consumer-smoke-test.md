# Consumer smoke test

How a Jenga release is smoke-tested the way a consumer sees it, what that test could not see before
`E98`, and the check that runs after `j.self-sync`. Saved here because the procedure was only written down
in two places outside this repository, and neither says why it passes while a consumer's install is broken.

## Sources (read these, do not copy them)

| What | Where | Note |
|---|---|---|
| The consumer project | `../st-test` (`~/Desktop/Projects/st-test`) | A Skolkartan-based Next.js project that installs `@jenga-ai/agent` from npm. Its `package.json` dependency is pointed at a `file:` tarball during a release check and must be restored afterwards. |
| The procedure, as st-test records it | `../st-test/README.md`, section "Testing a staged Jenga AI release" | Five steps: `npm whoami`; `npm stage download <id>` and shasum check; `npm install <tarball>`, `npm approve-scripts @jenga-ai/agent`, `npm rebuild @jenga-ai/agent`, `.jenga-version` matches; **run the skill smoke test against `node_modules/@jenga-ai/agent`** (as the st-test README words it; the smoke test is private and is no longer in that package, see "The smoke test is private" below) plus the two `scripts/populate-knowledge-graph.*.test.js` with `node`; `npm test`. |
| The procedure, as it runs | `project/.workflows/scripts/st-test-run.sh` (`E88_S02_T05`), used by the `deploy-stage` workflow | Step 7 first ran only the smoke test over the installed package (`--no-exec --root node_modules/@jenga-ai/agent`); since `E98_S02_T03` it also runs it over the consumer's `.claude/skills` (`--root .claude --package-root node_modules/@jenga-ai/agent`) as a second check. Since `E99_S01_T16` the script used is the **maintainer checkout's** `skills/j-smoke-test/scripts/smoke-test-skills.sh` (run from the consumer directory), never a copy inside the installed package; where the checkout has none, both checks are `SKIP`. See "The smoke test is private" below. |
| The original source | `Verifying a Staged Release Against a Consumer Project` in the public README | **No longer in `../agents-public/README.md`** (checked 2026-11-16, public commit `5eb42b1`); `st-test-run.sh` calls it "the former README steps 3-9". The st-test README still points there, which is stale. |
| The smoke test itself | `skills/j-smoke-test/scripts/smoke-test-skills.sh`; skill doc `skills/j-smoke-test/SKILL.md` | Private repo only, not in the published package (`E99_S01`). `--root <dir>` is a directory holding `skills/`. Exit 1 when any critical finding exists. |
| Mock board for the later steps | `../st-test/README.md`, "Mock board data"; `project/.workflows/scripts/st-test-mock-board.sh` | Not part of the smoke test. |

## The smoke test is private

`j.smoke-test` is a maintainer tool: it lives in the private repository and is not in the published package, so
`node_modules/@jenga-ai/agent/skills/j-smoke-test/` does not exist in a staged or released install, and nothing
here looks for it there. `project/.workflows/scripts/st-test-run.sh` runs from the maintainer's checkout
(`git rev-parse --show-toplevel`), which is what step 7 uses:

- **Checkout has `skills/j-smoke-test/scripts/smoke-test-skills.sh`** (the private repo): that script runs from the
  consumer directory against the **installed** package, as the two checks `skill smoke test (package root)`
  (`--no-exec --root node_modules/<pkg>`) and `skill smoke test (consumer .claude/skills)`
  (`--root .claude --package-root node_modules/<pkg>`). `PASS`/`FAIL` mean what they always did; the staged
  tarball is what is judged, with the checkout's copy of the checker.
- **Checkout has no copy** (the public tree, any checkout without the private skill): both lines are `SKIP` with
  the detail `j.smoke-test is not shipped; the consumer-layout check before release is scripts/consumer-smoke-after-sync.sh in the private repo`.
  `SKIP` counts neither as pass nor as fail, so the verdict comes from the other steps only, and a check that did
  not run never shows up as `PASS` or `FAIL`.

What is given up where the copy is absent: the stage-time consumer-layout check on the **staged tarball** does not
run. The only consumer-layout check left there is `scripts/consumer-smoke-after-sync.sh` in the private repo,
which checks the checkout (via `npm pack` of it), not the staged artifact.

## Why the smoke test did not catch the 5.0.1 failure

Reported by a client on 5.0.1: the mirrored wizard scripts under `.claude/skills/` look for `templates/` in
the wrong place and crash. Two independent gaps let it through:

1. **The smoke test never runs a script.** It checks that `SKILL.md` parses, that `name` matches the
   directory, that `metadata.prefered_agent` resolves, that referenced scripts and assets exist, and that
   each script passes `bash -n`. A script that resolves its package root wrongly is syntactically fine and
   its files exist.
2. **It is pointed at the layout where the bug does not exist.** The stage procedure passes
   `--root node_modules/@jenga-ai/agent`. In that tree `skills/<skill>/scripts/../../..` is the package
   root, so every `$SCRIPT_DIR/../../..` idiom resolves correctly. A consumer never runs skills from there.
   `postinstall` mirrors only `skills/` and `agents/` into `<consumer>/.claude/` and `<consumer>/.agents/`
   (see the header of `scripts/postinstall.js`: everything else "stays in the installed package and is
   sourced from `node_modules/...` at runtime"), so from `.claude/skills/<skill>/scripts/` the same three
   levels land on `.claude/`, which has no `templates/`, `scripts/` or `lib/`.

Reproduction (st-test, 5.1.0 mirror, before the fix):

```bash
cd ../st-test
bash .claude/skills/j-conventions/scripts/conventions-entry.sh categories
# conventions-entry.sh: cannot read the category list from .../st-test/.claude/templates/conventions-schema.json
bash .claude/skills/j-tidy/scripts/report.sh
# classify.sh: cannot find an executable scripts/check-worktree-liveness.sh ... Refusing to run.
```

`--help` hides it: `conventions-entry.sh --help` exits 0 on the broken layout, so a probe has to run a
subcommand that reads a package asset.

## The fix, and the check that guards it

- `skills/index/scripts/package-root.sh` (`jenga_package_root <script-dir>`) is the shared resolver. It is
  reachable from every mirrored skill because `skills/index/` is mirrored with them. It prefers the install
  root implied by the script's own location when that has `scripts/resolve-root.sh` and `templates/`, and
  otherwise looks for `node_modules/@jenga-ai/agent` from `JENGA_PROJECT_ROOT`, `CLAUDE_PROJECT_DIR`, and
  every ancestor of the script directory and of `$PWD`.
- `scripts/consumer-layout-fixture.sh <dest>` builds the same layout offline (package in `node_modules`,
  mirrors in `.claude/` and `.agents/`) for fast iteration.
- `scripts/consumer-old-client-fixture.sh <dest>` (private, blocklisted in `.publicignore`) builds on it a consumer
  installed before E100: no `jenga-settings-manifest.json`, no Jenga hook, and settings files holding only the client's own
  hook, allow rule, deny rule, env key and `defaultMode`. It writes those entries to `<dest>/.client-baseline.json` so a
  later step can assert they are unchanged after a sync and after a permission-level switch.
- `scripts/consumer-smoke-after-sync.sh` is the real check: `npm pack --ignore-scripts` of this checkout,
  unpack and run `postinstall` in a scratch consumer seeded from `../st-test/project/configs`, run the checkout's smoke
  test over the package root and over the mirror root (a real PASS/FAIL since `E98_S02`), then run **mirror-layout probes** (known read-only
  invocations of mirrored scripts, plus `--help` and a bare run of every other mirrored script) and fail when
  any output names a package asset under `.claude/`. It does not touch `../st-test` itself, and checks that by
  checksumming st-test's `package.json`, lockfile and `project/configs` before and after. Exit 3 means
  st-test was not found and the check was skipped.

## Where this sits next to what already existed

- `tests/consumer-install-testbed.bats` already installs the package into a throwaway consumer and runs
  the smoke test against the package root, the same check as step 7's package-root line (where the private `j.smoke-test` is present in the package under test); its sweep (case 8) flags shipped scripts that
  build a package-file path from `$REPO_ROOT` without a fallback, with an allowlist in
  `tests/fixtures/package-root-derived-paths.allowlist`. It could not see `$SCRIPT_DIR/../../..` because
  that idiom never mentions `$REPO_ROOT`, which is how the wizard scripts slipped through.
- `tests/package-root.bats` pins the resolver and the 5.0.1 regression; `tests/consumer-smoke-after-sync.bats`
  pins the post-sync script's contract and its `j.self-sync` wiring.
- Verified red/green (2026-11-16): the script run against `git archive HEAD` of the unfixed tree FAILs
  (`conventions-entry.sh categories` and `tools-entry.sh` resolve under `.claude/`); against the fixed tree it
  reports 130 pass, 0 fail.

## Scope of the 5.0.1 sweep

Every shell and JS script under `skills/` was audited, not only those changed since 4.3.0 (`v4.3.0` is not a
tag in this clone; it is the commit that set `"version": "4.3.0"`, `0f4aa72c`). About 60 files used the
`../../..` idiom; about 70 were migrated to `jenga_package_root` (the rest only call sibling skills, which
are mirrored). Deliberately not migrated: `j-distribute`, `j-mirror-public` and `j-self-sync` (blocklisted in
`.publicignore` or run only in the monorepo). The 36 scripts that already had a partial fallback were then run from three
working directories and classified (`E98_S01_T03`; table and counts in `skill-authoring.md`, "Locating the package root"):
6 failed and were fixed (`board_index.py`, three `j-publish` scripts, two `j-close-story` usage scripts). **Decision:**
`skills/j-publish/` ships (`.publicignore` blocks only the old bare `skills/publish/`), so its scripts must work in a
consumer.

## Settings merge after an update from a pre-skill version

The consumer's Claude Code settings are part of what a sync delivers (`E100_S03`). `scripts/merge-settings.sh`, sync step 12,
merges the shipped fragments (hooks, per-key `env`, opt-in `permissions.allow`; see `distribution.md`, "Settings merge") into
`.claude/settings.json` and `.agents/settings.json`, records what it wrote in `jenga-settings-manifest.json` and exits 6 for
conflicts or inactive allow rules (a warning, not a failure).

The documented check that the recorder hook is registered after an update from a version that predates the skill:

1. Start from a settings file of that era: only `WorktreeCreate`, `WorktreeRemove`, `SessionEnd` and a user-written hook.
   `tests/consumer-hook-merge.bats` test 1 builds exactly this file.
2. Run `scripts/merge-settings.sh --consumer-root <consumer>` (or `npx jenga sync`).
3. Expect `added UserPromptSubmit` and `added PreToolUse` on stdout, the recorder entry (`hooks/on_recording_step.sh`) in
   `.claude/settings.json`, every user entry intact, and `jenga-settings-manifest.json` beside it. A foreign
   `WorktreeCreate` or `WorktreeRemove` entry is reported as a conflict (exit 6) and left alone.
4. A second run reports `unchanged` and leaves the file byte-identical.

`j.smoke-test` covers the script structurally and by execution (`--help`); the merge behaviour itself is pinned by the two bats files above.

`scripts/consumer-smoke-after-sync.sh` step 6 (`E100_S06_T03`) runs that check as a consumer does: it builds the old-client fixture, runs
`node node_modules/@jenga-ai/agent/bin/jenga.js sync` of the installed package non-interactively, then prints one PASS/FAIL line per
requirement declared by the shipped settings fragments (the doctor, `scripts/settings-doctor.sh`, when the package ships it; otherwise
an equivalent direct check, and the report says which). A `permissions.allow` requirement is opt-in and no yes is given, so it is
reported as a SKIP line "inactive (expected ...)", never PASS or FAIL (`client-settings-requirements.md`, section 4). The recorder
`UserPromptSubmit` hook is also asserted in both `.claude/settings.json` and `.agents/settings.json`. `--old-client-only` runs just this
step without `../st-test` (`tests/consumer-smoke-old-client-sync.bats` uses it).

Step 6 continues (`E100_S06_T04`): it asserts the client's own entries from `<fixture>/.client-baseline.json` (own hook, allow rule, deny
rule, env key, `defaultMode`) present and unchanged in both settings files after the sync, then switches the permission level with the
installed package's `scripts/jenga-permission-level-switch.sh` (to a level other than the current one), asserts every requirement that
was active after the sync is still active (one line each), and asserts the own entries again. The keys the switch owns (`defaultMode`,
`permissions.deny`, `permissions.ask`, `autoMode`, `client-settings-requirements.md` section 1) are asserted only after the sync; after the
switch they get a SKIP line. A failing line names the file, the key path and what differed.

### Negative control for the settings activation phase (`E100_S06_T05`)

A green step 6 proves little unless it is known to go red. `tests/consumer-smoke-after-sync.bats` holds three cases named
"negative control" that run the phase (`--old-client-only`, which needs `../st-test` to be present, else they skip) and check
both sides:

- Green side: on the unmodified tree the phase passes, after the sync and after the level switch.
- Red side, merge disabled: the settings merge in the installed package is turned off, and the phase exits 1 naming
  `on_recording_step.sh` as the requirement that is not active.
- Red side, switch reverted: `scripts/jenga-permission-level-switch.sh` is put back to the whole-file overwrite it had
  before `E100_S04`, and the phase exits 1 at the after-switch assertion (the client's own entries or a previously active
  requirement are gone).

Verified red/green (2026-11-20): `bats tests/consumer-smoke-after-sync.bats -f "negative control"` on `main` reported
3 of 3 ok (`1..3`), no skips.

### What the old-client fixture contains, and what the phase leaves alone

`scripts/consumer-old-client-fixture.sh` (private, see Shipping) is what step 6 runs the sync against. The sync runs from the
installed package (`node_modules/@jenga-ai/agent/bin/jenga.js sync`), never from this checkout, so the result is what a
consumer gets. The requirement check uses the doctor (`scripts/settings-doctor.sh`) when the package ships it, otherwise a
direct jq check, and the report line "settings check" says which. No yes is given for `permissions.allow`, so those
requirements are asserted inactive (SKIP "inactive (expected ...)") rather than written. The level switch is expected to leave
the client's own entries and every previously active requirement alone, and to replace only the keys it owns (`defaultMode`,
`permissions.deny`, `permissions.ask`, `autoMode`), which are SKIPped after the switch.

## Known limits

- The probes find a wrong-root resolution only when the script's output names the bad path. A script that
  fails silently, or only on an argument no probe supplies, is not covered; add a line to the probe list in
  `consumer-smoke-after-sync.sh` when a new wizard script is added.
- `npm pack --ignore-scripts` skips `prepack`, so the dashboard UI is not built. Irrelevant to skills.
- The execution phase of `j.smoke-test` (`E98_S02`, private since `E99_S01_T18`) is static about what is safe to run: it
  executes `--help` only for a script whose code handles it, or a `# smoke-invoke:` declaration. It skips only scripts of
  never-shipped skills (read from `.publicignore`), `tests/` directories and sourced `lib/` files; shipped maintainer-only
  skills (`j-publish`, `j-init`, `j-dashboard`, `j-dashboard-share`) follow the same rule as every other skill. A fresh default
  run on 2026-11-21 reported `Execution check: 148 invoked, 148 exited 0, 44 unverifiable`: 21 never-shipped, 1 sourced lib,
  9 declared `none` outside the maintainer-only skills and 13 shipped maintainer-only scripts (of 32). The unverified scripts are
  covered only by bats and by the probes in `consumer-smoke-after-sync.sh`; a `--help` run proves start-up, not a pipeline body.
  Detail in `skill-authoring.md`, "The execution phase of `j.smoke-test`".
- The scrubbed environment and the fixture sandbox (stub `PATH`, `git` wrapper, local bare `origin`) are not an OS sandbox and not hermetic.

## Shipping

`scripts/consumer-smoke-after-sync.sh` and `tests/consumer-smoke-after-sync.bats` are in `.publicignore`: the script is run
only by `j.self-sync` (private) and needs `../st-test`. `scripts/consumer-old-client-fixture.sh` is private too (`.publicignore`, `E100_S06_T02`): it follows its only caller. `scripts/consumer-layout-fixture.sh` ships, since the shipped
`tests/package-root.bats` uses it (the private `j.smoke-test` execution phase uses it too). `skills/j-publish/` ships too (decision in
`skill-authoring.md`, "Locating the package root").

## Known failing tests

`tests/jenga-sync.bats`, "postinstall and sync produce the same files and the same per-step lines; postinstall ends with
the sync prompt" (reported as test 11): failed on macOS on `main` with no E100 change. Cause: the assertion
`[ "$pl" = "$sl" ]` compares the per-step lines of postinstall and sync after normalising the consumer path with
`sed "s|$A|<C>|g"`. `$BATS_TEST_TMPDIR` is under `/var`, a symlink to `/private/var`, and the `.github/hooks/jenga.json`
line prints the canonical `/private/var/...` path, so the sed did not match and the two outputs differed. Decision:
fixed (`E100_S06_T01`), not bounded; the test now normalises both the raw and the `pwd -P` form of the path, and the
assertion is unchanged in strength. Any other test failing for this same reason was fixed the same way. Nothing in
`E100_S06` depends on a known failure here.

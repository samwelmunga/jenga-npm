# Consumer smoke test

How a Jenga release is smoke-tested the way a consumer sees it, what that test could not see before
`E98`, and the check that runs after `j.self-sync`. Saved here because the procedure was only written down
in two places outside this repository, and neither says why it passes while a consumer's install is broken.

## Sources (read these, do not copy them)

| What | Where | Note |
|---|---|---|
| The consumer project | `../st-test` (`~/Desktop/Projects/st-test`) | A Skolkartan-based Next.js project that installs `@jenga-ai/agent` from npm. Its `package.json` dependency is pointed at a `file:` tarball during a release check and must be restored afterwards. |
| The procedure, as st-test records it | `../st-test/README.md`, section "Testing a staged Jenga AI release" | Five steps: `npm whoami`; `npm stage download <id>` and shasum check; `npm install <tarball>`, `npm approve-scripts @jenga-ai/agent`, `npm rebuild @jenga-ai/agent`, `.jenga-version` matches; **run the skill smoke test against `node_modules/@jenga-ai/agent`** plus the two `scripts/populate-knowledge-graph.*.test.js` with `node`; `npm test`. |
| The procedure, as it runs | `project/.workflows/scripts/st-test-run.sh` (`E88_S02_T05`), used by the `deploy-stage` workflow | Step 7 ran only `bash node_modules/@jenga-ai/agent/skills/j-smoke-test/scripts/smoke-test-skills.sh --root node_modules/@jenga-ai/agent`; since `E98_S02_T03` it also runs the smoke test over the consumer's `.claude/skills` (`--root .claude --package-root node_modules/@jenga-ai/agent`) as a second check. |
| The original source | `Verifying a Staged Release Against a Consumer Project` in the public README | **No longer in `../agents-public/README.md`** (checked 2026-11-16, public commit `5eb42b1`); `st-test-run.sh` calls it "the former README steps 3-9". The st-test README still points there, which is stale. |
| The smoke test itself | `skills/j-smoke-test/scripts/smoke-test-skills.sh`; skill doc `skills/j-smoke-test/SKILL.md` | `--root <dir>` is a directory holding `skills/`. Exit 1 when any critical finding exists. |
| Mock board for the later steps | `../st-test/README.md`, "Mock board data"; `project/.workflows/scripts/st-test-mock-board.sh` | Not part of the smoke test. |

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
- `scripts/consumer-smoke-after-sync.sh` is the real check: `npm pack --ignore-scripts` of this checkout,
  unpack and run `postinstall` in a scratch consumer seeded from `../st-test/project/configs`, run the smoke
  test over the package root and over the mirror root (a real PASS/FAIL since `E98_S02`), then run **mirror-layout probes** (known read-only
  invocations of mirrored scripts, plus `--help` and a bare run of every other mirrored script) and fail when
  any output names a package asset under `.claude/`. It does not touch `../st-test` itself, and checks that by
  checksumming st-test's `package.json`, lockfile and `project/configs` before and after. Exit 3 means
  st-test was not found and the check was skipped.

## Where this sits next to what already existed

- `tests/consumer-install-testbed.bats` already installs the package into a throwaway consumer and runs
  the stage-procedure smoke test against the package root; its sweep (case 8) flags shipped scripts that
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

## Known limits

- The probes find a wrong-root resolution only when the script's output names the bad path. A script that
  fails silently, or only on an argument no probe supplies, is not covered; add a line to the probe list in
  `consumer-smoke-after-sync.sh` when a new wizard script is added.
- `npm pack --ignore-scripts` skips `prepack`, so the dashboard UI is not built. Irrelevant to skills.
- The execution phase of `j.smoke-test` (`E98_S02`) is static about what is safe to run: it executes `--help` only for a
  script whose code handles it, or a `# smoke-invoke:` declaration. On the live package, 85 scripts are listed as
  unverifiable (48 maintainer-only, 1 sourced lib, 36 with no `--help` handling, among them 13 under `jenga`); they are
  covered only by the probes in `consumer-smoke-after-sync.sh`. Giving them a `--help` or a declaration is open work.
- The scrubbed environment is not an OS sandbox.

## Shipping

`scripts/consumer-smoke-after-sync.sh` and `tests/consumer-smoke-after-sync.bats` are in `.publicignore`: the script is run
only by `j.self-sync` (private) and needs `../st-test`. `scripts/consumer-layout-fixture.sh` ships, since the shipped
`tests/package-root.bats` and `j.smoke-test`'s execution phase use it. `skills/j-publish/` ships too (decision in
`skill-authoring.md`, "Locating the package root").

---
name: j:publish
description: Polyfill alias of the publish skill under a collision-safe directory name. Identical behavior to /publish — Configure, validate, and orchestrate scaffolded release workflows through a single `/publish` entry point with bounded sub-commands. Use when the bare /publish form is shadowed by another tool's own built-in command of the same name.
keywords:
  - publish
  - deploy
  - release
  - app store
  - npm
  - registry
  - release notes
  - staged publishing
  - stage
  - j-publish
  - polyfill
examples:
  - "publish setup --target staging-appstore"
  - "publish setup --type mobile-ios"
  - "publish setup --type npm"
  - "publish deploy --target staging-appstore --yes --dry-run"
  - "publish deploy --target npm-registry"
  - "publish deploy --target npm-registry --dry-run"
  - "publish setup --type droplet"
  - "publish deploy --target my-droplet"
  - "publish deploy --target my-droplet --dry-run"
  - "publish history --limit 5"
  - "publish release-notes --target staging-appstore"
  - "test a release before publishing"
  - "publish stage --target npm-registry --dry-run"
  - "approve a staged npm release"
  - "j-publish"
metadata:
  scope: multi-target-v2
  primary_target: multi
  primary_platform: multi
  supported_target_types:
    - mobile-ios
    - npm
    - npm-ci
    - droplet
---

# Publish — Deployment Pipeline Orchestrator

This skill is a literal-directory-name duplicate of `skills/publish/`. It exists so that `/j-publish` (and `j:j-publish`) give a guaranteed-unshadowed way to reach the same flow as `/publish`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/publish` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh publish` from `skills/publish/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

`/publish` is the single entry point for release workflows in this repository. It wires configuration validation, setup, gated deployment, release-note drafting, and ledger history into one end-to-end flow, and dispatches the final publish step to a per-type adapter.

Four target types are currently supported:

- **`mobile-ios`** — publishes an iOS build to App Store Connect via the iOS adapter. See the [iOS App Store](#ios-app-store) section for iOS-specific configuration.
- **`npm`** — publishes a package to an npm registry via the npm adapter. See the npm adapter (`skills/j-publish/adapters/npm.md`) and the npm wizard (`skills/j-publish/wizards/npm.md`) for npm-specific configuration.
- **`npm-ci`** — publishes a package to npmjs.com via GitHub Actions OIDC (Trusted Publishers), with no `NPM_TOKEN` stored. The adapter generates a GitHub Actions workflow, commits it to the repository, and triggers it via `gh workflow run`. See the npm-ci adapter (`skills/j-publish/adapters/npm-ci.md`) and the npm-ci wizard (`skills/j-publish/wizards/npm-ci.md`) for configuration details.
- **`droplet`** — deploys a website or app to any SSH-reachable Linux host (including DigitalOcean Droplets) using a generated GitHub Actions workflow. The workflow SSHes into the host, pulls the deploy branch, runs an optional build command, and restarts the service. See [Droplet (GitHub Actions → SSH)](#droplet-github-actions--ssh) for configuration details.

Every sub-command validates the config before doing anything else, so behaviour is identical regardless of which target type a project uses.

## Invocation Contract

Before any sub-command executes, validate the config with:

```bash
bash skills/j-publish/scripts/validate_config.sh <path-to-publish.json>
```

For deploy-oriented flows, validate the selected target with:

```bash
bash skills/j-publish/scripts/check_target_config.sh <target-name> <path-to-publish.json>
```

- Default config resolution: prefer repo-root `publish.json`, fall back to `project/configs/publish.json`
- Schema: `skills/j-publish/schemas/publish.schema.json`
- Example config: `skills/j-publish/assets/publish.example.json`
- Secrets guide: `skills/j-publish/assets/secrets-guide.md`
- Deploy contract and exit codes: `skills/j-publish/assets/ci-contract.md`
- iOS adapter template: `skills/j-publish/adapters/mobile-ios.md`
- npm adapter template: `skills/j-publish/adapters/npm.md`
- Ownership matrix: `skills/j-publish/assets/ownership-matrix.md`

If config or env validation fails, the skill exits with code `4` and does not continue.

## Sub-Commands

| Command | Purpose | Implementation script | Notes |
|---|---|---|---|
| `/publish setup` | Prepare or refresh target configuration | `skills/j-publish/scripts/setup_wizard.sh` | Supported types: `mobile-ios`, `npm`, `npm-ci`, `droplet` |
| `/publish deploy` | Run the full 11-step deploy orchestration | `skills/j-publish/scripts/publish_deploy.sh` | Dispatches to the adapter for the target's `type` (`mobile-ios`, `npm`, `npm-ci`, or `droplet`); `--dry-run` is honoured end-to-end |
| `/publish stage` | Stage an npm release into npm's staged-publishing area, smoke-test it in isolation, then approve or reject it | `skills/j-publish/scripts/npm_stage_pipeline.sh` (the `publish` sub-command) and `skills/j-publish/scripts/npm_stage_inspect.sh` (`list`, `view`, `download`, `test`, `approve`, `reject`) | Supported for `npm` and `npm-ci` target types only |
| `/publish history` | Read the canonical publish ledger | `skills/j-publish/scripts/show_history.sh` | Target-agnostic; filter by `--target <name>` |
| `/publish release-notes` | Merge new release notes into the standing `CHANGELOG.md` (or a standalone draft via `--output`) without publishing | `skills/j-publish/scripts/generate_release_notes.sh` | Target-agnostic |

## Quality Gate Policy

The deploy flow invokes `skills/j-publish/scripts/run_gates.sh` at two fixed points:

1. **Pre-deploy:** `run_gates.sh pre <target> <publish.json> [--non-interactive]`
2. **Post-deploy:** `run_gates.sh post <target> <publish.json> [--non-interactive]`

- `build` and `test` are **mandatory global** pre-deploy gates — always run, cannot be disabled via config
- Per-target `checks.pre` and `checks.post` can add optional gates: `lint`, `type-check`, `custom-script`, `smoke-test`, `ping`
- Any pre-deploy gate failure exits with code `2` and surfaces the full error output
- Post-deploy gate failure records a `partial` publish result instead of rolling back the adapter upload
- `--non-interactive` suppresses retry prompts and aborts immediately on failure

See `skills/j-publish/assets/ci-contract.md` for the full quality-gate policy.

## Usage Signatures

### `/publish setup`

```text
/publish setup [<target>] [--type mobile-ios|npm|droplet] [--config <path>]
```

Implementation: `bash skills/j-publish/scripts/setup_wizard.sh [<target>] [--type <deployment_type>] [--config <path>]`

Wizard flow:
1. Resolve or prompt for the target name.
2. Resolve or prompt for the deployment type. Supported values: `mobile-ios`, `npm`, `droplet`.
3. Print the secrets guide path and the opening warning from `skills/j-publish/assets/secrets-guide.md`.
4. Load `skills/j-publish/wizards/<type>.md` and render each `## Question:` section as a prompt.
5. Preview the generated target config as JSON.
6. Save on confirmation by merging or creating `publish.json`.
7. Validate the saved file with `validate_config.sh`; if validation fails, roll back the write.

During setup, env-var reference answers are checked against the current shell. Missing variables only warn; they do not block save.

Example invocations:

```bash
/publish setup                              # interactive, prompts for target and type
/publish setup --type mobile-ios            # scaffold an iOS App Store target
/publish setup --type npm                   # scaffold an npm registry target
/publish setup npm-registry --type npm      # scaffold a target named "npm-registry"
/publish setup --type npm-ci                   # scaffold an npm CI (Trusted Publisher) target
/publish setup npm-ci-pkg --type npm-ci        # scaffold a target named "npm-ci-pkg"
/publish setup --type droplet               # scaffold a Droplet SSH deploy target
/publish setup my-droplet --type droplet    # scaffold a target named "my-droplet"
```

### `/publish deploy`

```text
/publish deploy [--target <name>] [--config <path>] [--yes] [--dry-run] [--minor | --major] [--notes-file <path>]
```

Implementation: `bash skills/j-publish/scripts/publish_deploy.sh [flags...]`

Deploy flow:
1. Select the target from config or `--target`
2. Check target completeness; interactive runs auto-launch the setup wizard on missing fields
3. Validate target environment variables
4. Print a best-effort scrum-board summary since the last publish tag
5. Run pre-deploy gates
6. Update the standing `CHANGELOG.md`'s `[Unreleased]` section with new entries since the last publish tag (or use the caller-supplied file instead, when release notes are supplied via the bypass flag), and review it unless `--yes` is set
7. Suggest and confirm the semver bump (`patch` by default in non-interactive mode unless `--minor` or `--major` is passed)
8. Print final confirmation: `Deploy v<x.y.z> to <target>? [y/N]`
9. Execute the adapter pipeline for the target's `type` (`ios_pipeline.sh` for `mobile-ios`, `npm_pipeline.sh` for `npm`, `npm_ci_pipeline.sh` for `npm-ci`, `droplet_pipeline.sh` for `droplet`)
10. Run post-deploy gates and downgrade the ledger state to `partial` on failure
11. Finalize `CHANGELOG.md` — stamp `[Unreleased]` to a versioned, dated entry and open a fresh empty `[Unreleased]` above it (skipped on `--dry-run`, and skipped when release notes were supplied via the bypass flag, since there is then no standing-file `[Unreleased]` section to finalize) — then append the publish ledger entry, create the git tag (unless `--dry-run`), and print post-deploy manual steps

Non-interactive rule: when `--yes` is used, deploy must not auto-run setup after a failure. It exits `4` and surfaces the missing fields.

#### `--dry-run`

`--dry-run` runs the full deploy orchestration end-to-end without producing a real release:

- Every step from target selection through gates, release-note generation, and semver bump runs normally.
- The adapter is invoked with `--dry-run` so it performs its full pipeline but skips the destructive publish step (no App Store upload for `mobile-ios`, no `npm publish` for `npm`).
- The real git tag is **not** created.
- A ledger entry is still appended with `platform_state: "dry-run"` so the run is auditable.

Example invocations:

```bash
/publish deploy --target staging-appstore --dry-run
/publish deploy --target npm-registry --dry-run
/publish deploy --target npm-ci-pkg --dry-run
```

Use `--dry-run` to rehearse a release, validate that gates pass, and confirm the generated release notes without publishing.

### `/publish stage`

Staged publishing for `npm`/`npm-ci` targets only. Not available for
`mobile-ios` or `droplet` — those adapters have no staging area to dispatch
to. The lifecycle is **stage → test → approve**, with `reject` as the
discard path at any point after staging:

```text
staged ──▶ stage_tested ──▶ approved   (approve requires 2FA; refuses without
   │             │                      a passing test unless --force <reason>)
   │             │
   └─────────────┴──▶ rejected   (discard path — available from any staged state)
```

Two registry constraints trip people up and are worth stating plainly:

- **The package must already exist on the registry.** npm's staged-publishing
  workflow only applies to a package that has had at least one normal,
  non-staged publish already — `validate_npm_stage_env.sh` checks this
  up front and exits `4` if it doesn't hold.
- **Approval requires 2FA; staging does not.** `npm stage publish` (the
  `stage` sub-command below) can run non-interactively in CI. `npm stage
  approve` cannot — npmjs.com requires an interactive one-time-password
  step for approval, so it is always a human action even when staging was
  automated (see the npm-ci adapter's OIDC staging section for the CI-stage,
  human-approve split).

All seven sub-commands:

```text
/publish stage publish <target> <path-to-publish.json> [--dry-run] [--non-interactive] [--otp <otp>]
/publish stage test <stage-id> [--keep] [--config <path>] [--dry-run] [--json]
/publish stage list [<package-spec>] [--config <path>] [--dry-run] [--json]
/publish stage view <stage-id> [--config <path>] [--dry-run] [--json]
/publish stage download <stage-id> [--out <dir>] [--config <path>] [--dry-run] [--json]
/publish stage approve <stage-id> [--otp <otp>] [--force <reason>] [--config <path>] [--dry-run] [--json]
/publish stage reject <stage-id> [--config <path>] [--dry-run] [--json]
```

Implementation:

- `publish` → `bash skills/j-publish/scripts/npm_stage_pipeline.sh <target> <path-to-publish.json> [--dry-run] [--non-interactive] [--otp <otp>]` — six ordered phases (validate, gates, pack, stage, capture, ledger); writes a `staged` ledger entry on success.
- `test`, `list`, `view`, `download`, `approve`, `reject` → `bash skills/j-publish/scripts/npm_stage_inspect.sh <sub> [args] [--config <path>] [--dry-run] [--json]`
  - `test` downloads the exact staged tarball into an isolated scratch directory outside the repo, installs it, runs the target's `npm.stage.smoke_cmd` (or the documented default check), and writes a `stage_tested` ledger entry (`pass`/`fail`).
  - `approve` refuses to run unless a passing `test` is on record for that exact stage id, unless `--force <reason>` is given; writes an `approved` ledger entry.
  - `reject` is the discard path omitted from npm's own staged-publishing docs page — documented here so it stays discoverable; writes a `rejected` ledger entry.

Example invocations:

```bash
/publish stage publish npm-registry ./publish.json --dry-run
/publish stage test <stage-id>
/publish stage approve <stage-id>
/publish stage reject <stage-id>
```

Use `/publish stage` to rehearse and smoke-test a release before it goes
live — the point of staging is that a bad tarball is caught in isolation
instead of being caught by users after `npm publish`.

### `/publish history`

```text
/publish history [--config <path>] [--limit <count>] [--target <name>] [--json]
```

Implementation: `bash skills/j-publish/scripts/show_history.sh [--limit <count>] [--target <name>] [--json] [--config <path>]`

### `/publish release-notes`

```text
/publish release-notes --target <name> [--config <path>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>]
```

Implementation: `bash skills/j-publish/scripts/generate_release_notes.sh [--target <name>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>] [<publish_json_path>]`

Release-note rules:
- The last publish tag is the highest semver tag on the current branch that also has a matching ledger entry in `project/logs/publish-history.json`.
- **Default target (no `--output`):** the repo-root `CHANGELOG.md` — created from `templates/CHANGELOG_TEMPLATE.md` first if it doesn't exist yet (backward-compat for projects scaffolded before this convention). New Features/Bug Fixes/Other/Completed-task entries since the last publish tag are appended under the existing `## [Unreleased]` heading's subsections; everything else in the file (prior versioned entries, manual edits) is preserved. Entries already present are deduped (matched by commit short-sha or task id), so re-running with no new commits produces zero diff.
- **`--output <path>`:** writes a standalone, disposable draft to that path instead (the pre-E36 behavior) — `CHANGELOG.md` is not touched in this mode.
- If no prior ledger-backed tag exists, a `--output` draft includes `> First release — full history included`; the standing `CHANGELOG.md` merge mode has no equivalent banner (it just merges full history into `[Unreleased]` like any other run).
- Scrum-board enrichment is best-effort only; missing or unreadable board data never fails the command.
- **`.publicignore` filtering:** when a repo-root `.publicignore` exists (the blocklist `/mirror-public` also reads), a candidate commit — or a completed task's associated commit(s), matched via the `task(E##_S##_T##):` commit-message convention — is dropped entirely when every changed file it touches is covered by that blocklist. A commit touching a mix of blocked and unblocked files is still logged normally; only full coverage excludes an entry. This exists because `CHANGELOG.md` itself is not blocklisted and ships to the public mirror, so an unfiltered entry referencing a private-only path (e.g. `project/board/`) would leak. Absent `.publicignore`, this is a strict no-op — unchanged from pre-E36_S02_T02 behavior. Matching reuses `skills/mirror-public/scripts/mirror.sh`'s `rsync --exclude-from` evaluation rather than a separate glob implementation, so a path classified "blocked" by `/mirror-public --dry-run` is classified "blocked" here too.

## Ledger & Tagging

- `project/logs/publish-history.json` is append-only. New publishes add new rows; existing rows are never edited in-place.
- `bash skills/j-publish/scripts/suggest_semver_bump.sh` suggests `major`, `minor`, or `patch` based on git history since the last ledger-backed publish tag.
- `bash skills/j-publish/scripts/write_ledger_entry.sh <target> <adapter> <platform_state> <notes_path> [--yes] [--dry-run] [--version <vX.Y.Z>] [--config <path>]` appends the canonical publish entry and creates the matching annotated git tag.
- `bash skills/j-publish/scripts/reconcile_tags.sh [--dry-run] [--config <path>]` repairs drift:
  - git tag without ledger entry → append `partial` ledger row with note `Manually tagged without /publish`
  - ledger entry without git tag → create the missing tag retroactively

## Agent Roles

See `skills/j-publish/assets/ownership-matrix.md` for the action-by-action ownership matrix.

Summary:
- **Developer** initiates `/publish setup`, `/publish deploy`, and release-note review
- **Tester** may run staging deploys as part of validation and uses publish history as test context
- **Scrum Master** never deploys directly and only reviews publish context through workflow status surfaces

## Configuration Model

The canonical config must validate against `skills/j-publish/schemas/publish.schema.json`.

### Required top-level structure

- `version` — schema version for the publish contract
- `defaults` — global defaults, including the canonical publish ledger path and mandatory checks
- `targets[]` — named deployment targets

### Common target structure

Every target — regardless of `type` — must define:
- `name`
- `type` — one of `mobile-ios`, `npm`, `droplet`
- `checks.pre[]` / `checks.post[]`
- `secrets` — env-var references only, never credential values

Type-specific fields are documented below.

## iOS App Store

The `mobile-ios` adapter publishes iOS builds to App Store Connect.

### Required target fields for `mobile-ios`

- `type: mobile-ios`
- `platform: ios-app-store`
- `ios` — scheme/build/export/upload metadata used by the adapter

### Required iOS env references

The `mobile-ios` target must provide env-var references for:
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
- `CODE_SIGN_IDENTITY`
- `PROVISIONING_PROFILE_UUID`

### iOS scope guardrails

This story set intentionally does **not** implement automated App Store review submission.

The iOS adapter trust boundary is explicit: publish-side external commands are limited to direct `xcodebuild` and `xcrun` invocations.

## npm Registry

The `npm` adapter publishes a Node package to an npm-compatible registry.

- Adapter template: `skills/j-publish/adapters/npm.md`
- Wizard template: `skills/j-publish/wizards/npm.md`

See those files for the required target fields (registry URL, access, tag, `--dry-run` behaviour) and env references. Additional npm-specific schema details are owned by the npm settings block in `skills/j-publish/schemas/publish.schema.json`.

## npm CI (OIDC Trusted Publisher)

The `npm-ci` adapter publishes a Node package to npmjs.com via **GitHub Actions OIDC (Trusted Publishers)** — no `NPM_TOKEN` is stored anywhere.

> Use `npm` for local publishes with a token; use `npm-ci` for CI-only publishing with OIDC (no token required).

- Adapter template: `skills/j-publish/adapters/npm-ci.md`
- Wizard template: `skills/j-publish/wizards/npm-ci.md`
- Example config: `skills/j-publish/assets/publish.example.npm-ci.json`

### Required target fields for `npm-ci`

- `type: npm-ci`
- `github_repo` — repository in `owner/name` format (e.g. `acme-org/my-package`)
- `workflow_path` — path to the workflow file to generate and trigger (default: `.github/workflows/npm-publish.yml`)
- `npm.package_name`, `npm.access`, `npm.registry`, `npm.dist_tag` — same as the `npm` adapter

No `secrets` block is required. Any `secrets` block present is ignored by this adapter.

### One-time prerequisite (manual)

Before the first deploy, link the package to the repository on npmjs.com:

1. Sign in to npmjs.com → navigate to the package page
2. Settings → Publishing → Trusted Publishers → Add publisher
3. Select GitHub Actions; enter `owner/repo` and the workflow file path
4. Save

Once configured, only the linked workflow can publish this package — local `npm publish` with a token will be rejected by npmjs.com for that package.

### Usage examples

```bash
/publish setup --type npm-ci
/publish deploy --target npm-ci-pkg --dry-run
/publish deploy --target npm-ci-pkg
```

## Droplet (GitHub Actions → SSH)

The `droplet` adapter deploys a project to any SSH-reachable Linux host by generating a GitHub Actions workflow that SSHes into the host on each trigger.

**Trust boundary**: `publish.json` holds only *references* to GitHub Actions secret names — never the actual SSH key or host credentials. Real secrets live in GitHub Actions secrets.

### Required target fields for `droplet`

- `type: droplet`
- `platform: droplet-ssh`
- `droplet.host` — IP address or FQDN of the target host
- `droplet.ssh_user` — SSH login username
- `droplet.ssh_port` — SSH port (default 22)
- `droplet.deploy_path` — absolute path to the app directory on the host
- `droplet.github_repo` — repository in `owner/name` format
- `droplet.deploy_branch` — branch to pull on each deploy
- `droplet.start_cmd` — command to (re)start the service (e.g. `pm2 reload ecosystem.config.js`, `sudo systemctl restart myapp`)
- `droplet.build_cmd` — optional build step run after `git pull`
- `secrets.ssh_key_secret` — name of the GH Actions secret holding the SSH private key
- `secrets.known_hosts_secret` — name of the GH Actions secret holding `ssh-keyscan` output

### Required GitHub Actions secrets

The generated workflow reads these from GitHub Actions secrets:
- `DROPLET_SSH_HOST` — host IP or FQDN
- `DROPLET_SSH_USER` — SSH username
- `DROPLET_SSH_PORT` — SSH port
- `DROPLET_SSH_KEY` (or value of `ssh_key_secret`) — private key contents
- `DROPLET_KNOWN_HOSTS` (or value of `known_hosts_secret`) — `ssh-keyscan` output

See `skills/j-publish/assets/secrets-guide.md` for setup instructions.

### First-run prerequisites (manual)

Before the first deploy, the target host must already have:
- The deploy path created (`mkdir -p /var/www/myapp`)
- An initial `git clone` of the repo at the deploy path
- Any runtime dependencies installed (Node, PM2, etc.)

The adapter does not bootstrap the host — it only drives the continuous-deploy loop.

### Usage examples

```bash
/publish setup --type droplet
/publish deploy --target my-droplet --dry-run
/publish deploy --target my-droplet
```

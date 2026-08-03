---
name: publish
description: Configure, validate, and orchestrate scaffolded release workflows through a single `/publish` entry point with bounded sub-commands.
keywords:
  - publish
  - deploy
  - release
  - app store
  - release notes
examples:
  - "publish setup --target staging-appstore"
  - "publish deploy --target staging-appstore --yes --dry-run"
  - "publish history --limit 5"
  - "publish release-notes --target staging-appstore"
metadata:
  scope: ios-v1-complete
  primary_target: mobile-ios
  primary_platform: ios-app-store
---

# Publish — Deployment Pipeline Orchestrator

`/publish` is the single entry point for release workflows in this repository. The v1 implementation now wires configuration validation, setup, gated deployment, release-note drafting, ledger history, and the iOS App Store adapter into one end-to-end flow.

## Invocation Contract

Before any sub-command executes, validate the config with:

```bash
bash skills/publish/scripts/validate_config.sh <path-to-publish.json>
```

For deploy-oriented flows, validate the selected target with:

```bash
bash skills/publish/scripts/check_target_config.sh <target-name> <path-to-publish.json>
```

- Default config resolution: prefer repo-root `publish.json`, fall back to `project/configs/publish.json`
- Schema: `skills/publish/schemas/publish.schema.json`
- Example config: `skills/publish/assets/publish.example.json`
- Secrets guide: `skills/publish/assets/secrets-guide.md`
- Deploy contract and exit codes: `skills/publish/assets/ci-contract.md`
- iOS adapter template: `skills/publish/adapters/mobile-ios.md`
- Ownership matrix: `skills/publish/assets/ownership-matrix.md`

If config or env validation fails, the skill exits with code `4` and does not continue.

## Sub-Commands

| Command | Purpose | Implementation script |
|---|---|---|
| `/publish setup` | Prepare or refresh target configuration | `skills/publish/scripts/setup_wizard.sh` |
| `/publish deploy` | Run the full 11-step deploy orchestration | `skills/publish/scripts/publish_deploy.sh` |
| `/publish history` | Read the canonical publish ledger | `skills/publish/scripts/show_history.sh` |
| `/publish release-notes` | Generate release notes without publishing | `skills/publish/scripts/generate_release_notes.sh` |

## Quality Gate Policy

The deploy flow invokes `skills/publish/scripts/run_gates.sh` at two fixed points:

1. **Pre-deploy:** `run_gates.sh pre <target> <publish.json> [--non-interactive]`
2. **Post-deploy:** `run_gates.sh post <target> <publish.json> [--non-interactive]`

- `build` and `test` are **mandatory global** pre-deploy gates — always run, cannot be disabled via config
- Per-target `checks.pre` and `checks.post` can add optional gates: `lint`, `type-check`, `custom-script`, `smoke-test`, `ping`
- Any pre-deploy gate failure exits with code `2` and surfaces the full error output
- Post-deploy gate failure records a `partial` publish result instead of rolling back the adapter upload
- `--non-interactive` suppresses retry prompts and aborts immediately on failure

See `skills/publish/assets/ci-contract.md` for the full quality-gate policy.

## Usage Signatures

### `/publish setup`

```text
/publish setup [<target>] [--type mobile-ios] [--config <path>]
```

Implementation: `bash skills/publish/scripts/setup_wizard.sh [<target>] [--type <deployment_type>] [--config <path>]`

Wizard flow:
1. Resolve or prompt for the target name.
2. Resolve or prompt for the deployment type (currently `mobile-ios`).
3. Print the secrets guide path and the opening warning from `skills/publish/assets/secrets-guide.md`.
4. Load `skills/publish/wizards/<type>.md` and render each `## Question:` section as a prompt.
5. Preview the generated target config as JSON.
6. Save on confirmation by merging or creating `publish.json`.
7. Validate the saved file with `validate_config.sh`; if validation fails, roll back the write.

During setup, env-var reference answers are checked against the current shell. Missing variables only warn; they do not block save.

### `/publish deploy`

```text
/publish deploy [--target <name>] [--config <path>] [--yes] [--dry-run] [--minor | --major] [--release-notes <path>]
```

Implementation: `bash skills/publish/scripts/publish_deploy.sh [flags...]`

Deploy flow:
1. Select the target from config or `--target`
2. Check target completeness; interactive runs auto-launch the setup wizard on missing fields
3. Validate target environment variables
4. Print a best-effort scrum-board summary since the last publish tag
5. Run pre-deploy gates
6. Generate a release-note draft and review it unless `--yes` is set
7. Suggest and confirm the semver bump (`patch` by default in non-interactive mode unless `--minor` or `--major` is passed)
8. Print final confirmation: `Deploy v<x.y.z> to <target>? [y/N]`
9. Execute the adapter pipeline (`ios_pipeline.sh` for `mobile-ios`)
10. Run post-deploy gates and downgrade the ledger state to `partial` on failure
11. Append the publish ledger entry, create the git tag (unless `--dry-run`), and print post-deploy manual steps

Non-interactive rule: when `--yes` is used, deploy must not auto-run setup after a failure. It exits `4` and surfaces the missing fields.

Dry-run rule: `--dry-run` runs the full orchestration, passes `--dry-run` to the adapter, skips the real git tag, and writes a `platform_state: "dry-run"` ledger entry.

### `/publish history`

```text
/publish history [--config <path>] [--limit <count>] [--target <name>] [--json]
```

Implementation: `bash skills/publish/scripts/show_history.sh [--limit <count>] [--target <name>] [--json] [--config <path>]`

### `/publish release-notes`

```text
/publish release-notes --target <name> [--config <path>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>]
```

Implementation: `bash skills/publish/scripts/generate_release_notes.sh [--target <name>] [--from-tag <tag>] [--to-ref <git-ref>] [--output <path>] [<publish_json_path>]`

Release-note rules:
- The last publish tag is the highest semver tag on the current branch that also has a matching ledger entry in `project/logs/publish-history.json`.
- If no prior ledger-backed tag exists, the draft includes `> First release — full history included`.
- Scrum-board enrichment is best-effort only; missing or unreadable board data never fails the command.

## Ledger & Tagging

- `project/logs/publish-history.json` is append-only. New publishes add new rows; existing rows are never edited in-place.
- `bash skills/publish/scripts/suggest_semver_bump.sh` suggests `major`, `minor`, or `patch` based on git history since the last ledger-backed publish tag.
- `bash skills/publish/scripts/write_ledger_entry.sh <target> <adapter> <platform_state> <notes_path> [--yes] [--dry-run] [--version <vX.Y.Z>] [--config <path>]` appends the canonical publish entry and creates the matching annotated git tag.
- `bash skills/publish/scripts/reconcile_tags.sh [--dry-run] [--config <path>]` repairs drift:
  - git tag without ledger entry → append `partial` ledger row with note `Manually tagged without /publish`
  - ledger entry without git tag → create the missing tag retroactively

## Agent Roles

See `skills/publish/assets/ownership-matrix.md` for the action-by-action ownership matrix.

Summary:
- **Developer** initiates `/publish setup`, `/publish deploy`, and release-note review
- **Tester** may run staging deploys as part of validation and uses publish history as test context
- **Scrum Master** never deploys directly and only reviews publish context through workflow status surfaces

## Configuration Model

The canonical config must validate against `skills/publish/schemas/publish.schema.json`.

### Required top-level structure

- `version` — schema version for the publish contract
- `defaults` — global defaults, including the canonical publish ledger path and mandatory checks
- `targets[]` — named deployment targets

### Required target structure for `mobile-ios`

Each target must define:
- `name`
- `type: mobile-ios`
- `platform: ios-app-store`
- `checks.pre[]` / `checks.post[]`
- `secrets` — env-var references only, never credential values
- `ios` — scheme/build/export/upload metadata used by the adapter

### Required iOS env references

The `mobile-ios` target must provide env-var references for:
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
- `CODE_SIGN_IDENTITY`
- `PROVISIONING_PROFILE_UUID`

## Scope Guardrails

This story set intentionally does **not** implement automated App Store review submission.

The adapter trust boundary is explicit: publish-side external commands are limited to direct `xcodebuild` and `xcrun` invocations.

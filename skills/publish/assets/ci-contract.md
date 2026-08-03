# `/publish` deploy contract

This document defines the CI-safe execution contract for the scaffolded `/publish` workflow. Interactive flows added later must wrap this contract and must not weaken it.

## Validation order

Every `/publish` invocation must perform these steps before command-specific work:

1. Resolve config path (`--config <path>` or default `project/configs/publish.json`)
2. Run `bash skills/publish/scripts/validate_config.sh <resolved-path>`
3. Abort immediately with exit code `4` if the file is missing, invalid JSON, or fails validation
4. For the iOS adapter, run `bash skills/publish/scripts/validate_ios_env.sh <resolved-path>` before build/upload work begins

## Inputs

| Purpose | Flag | Environment Variable | Required in non-interactive mode? | Notes |
|---|---|---|---|---|
| Select deploy target | `--target <name>` | `PUBLISH_TARGET` | Yes | Flag takes precedence over env var |
| Skip confirmation prompts | `--yes` | `PUBLISH_YES` | Yes | Env var truthy values: `1`, `true`, `yes`, `on` |
| Override config path | `--config <path>` | — | No | Defaults to `project/configs/publish.json` |
| Reuse prepared release notes | `--release-notes <path>` | — | No | Reserved for later release-note flow |
| Dry-run execution | `--dry-run` | `PUBLISH_DRY_RUN` | No | Prints allowlisted `xcodebuild` / `xcrun` commands without executing them |

## Required contract

For a CI or agent-driven deploy, the caller must provide:

- a valid target via `--target` or `PUBLISH_TARGET`
- confirmation bypass via `--yes` or truthy `PUBLISH_YES`
- a valid config file at the provided path or the default path
- the required iOS credential environment variables when the `mobile-ios` adapter is used

If any of these are missing in a non-interactive execution context, the command must fail fast rather than prompting.

## Mandatory global pre-deploy gates

`build` and `test` are mandatory global gates for `/publish deploy`.

- They run first on every `pre` gate pass.
- They cannot be disabled, removed, or overridden by target configuration.
- If `publish.json` also lists `build` or `test` under target-specific pre-gates, the runner ignores those duplicates and keeps the mandatory global versions.
- If either mandatory gate fails, the gate runner surfaces the full command output and exits with code `2` without continuing to later gates.

## Configurable target gates

Per-target gates may add optional checks such as:

- `lint`
- `type-check`
- `custom-script`
- `smoke-test`
- `ping`

These run only after the mandatory global gates succeed.

## Optional contract

These inputs remain optional in non-interactive mode:

- `--config <path>` when the default config exists
- `--release-notes <path>`
- `--from-tag` and `--to-ref` on `/publish release-notes`

## Exit codes

| Code | Meaning | Current story coverage |
|---|---|---|
| `0` | Success | Config/env validation succeeds, dry-runs complete, and later deploy steps finish |
| `1` | User abort | Reserved for interactive confirmation flow |
| `2` | Quality gate failure | Implemented by the gate runner |
| `3` | Deploy failure | Used by the iOS adapter pipeline for build/export/upload failures |
| `4` | Config or environment invalid | Implemented by validation scripts |

## Precedence rules

1. Command-line flags win over environment variables.
2. Environment variables are only fallbacks where explicitly supported.
3. Missing/invalid config always stops execution before target resolution or deploy steps.
4. Missing required iOS env vars stop execution before any `xcodebuild` or `xcrun` command runs.

## Interactive vs non-interactive behavior

- Interactive mode offers: `[r] Retry after fixing / [a] Abort deploy`
- Retries are capped at 3 attempts per failed gate
- `--non-interactive` disables prompts and aborts immediately on any gate failure
- Every gate failure is appended to `project/logs/publish-history.json`
- `--dry-run` still records adapter state transitions so the planned pipeline can be reviewed safely

## Example CI invocations

### Flag-driven

```bash
publish deploy --target staging-appstore --yes --dry-run
```

### Mixed flag + env var

```bash
PUBLISH_YES=true publish deploy --target staging-appstore --dry-run
```

### Fully env-driven target selection

```bash
PUBLISH_TARGET=staging-appstore PUBLISH_YES=1 publish deploy --dry-run
```

## Scope notes

This story set does not perform live Apple API calls during verification. The iOS adapter is structured around allowlisted `xcodebuild` and `xcrun` commands and relies on caller-provided credentials and a local Apple toolchain.

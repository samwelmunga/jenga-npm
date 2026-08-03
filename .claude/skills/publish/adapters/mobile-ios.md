# `mobile-ios` Adapter

The `mobile-ios` adapter drives the `/publish deploy` flow for iOS App Store targets.
It is a prompt/template contract for the agent layer and delegates concrete execution to
`skills/publish/scripts/ios_pipeline.sh`.

## Invocation Contract

### Inputs from `publish.json`

A `mobile-ios` target must define:

- `name`
- `type: mobile-ios`
- `platform: ios-app-store`
- `checks.pre[]` / `checks.post[]`
- `secrets.app_store_connect_api_key_id`
- `secrets.app_store_connect_issuer_id`
- `secrets.app_store_connect_private_key_path`
- `secrets.code_sign_identity`
- `secrets.provisioning_profile_uuid`
- `ios.scheme`
- `ios.configuration`
- `ios.archive_path`
- `ios.export_path`
- `ios.export_method` (`ad-hoc` or `app-store`)
- `ios.bundle_id`
- `ios.team_id`
- `ios.app_store_app_id`
- exactly one of `ios.project_path` or `ios.workspace_path`

### Required environment variables

The adapter uses env-var references only and never stores secret values in repo files.
The required env vars are:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
- `CODE_SIGN_IDENTITY`
- `PROVISIONING_PROFILE_UUID`

Validate them before execution with:

```bash
bash skills/publish/scripts/validate_ios_env.sh <path-to-publish.json>
```

### Pipeline entrypoint

```bash
bash skills/publish/scripts/ios_pipeline.sh <target> <path-to-publish.json> [--dry-run] [--non-interactive]
```

## Execution Phases

Run the adapter phases in this exact order:

1. `validate`
2. `build`
3. `sign`
4. `export`
5. `upload`

Quality gates run outside this adapter. Once control enters the adapter, external publish-side commands are restricted to direct `xcodebuild` and `xcrun` invocations.

## State Machine

The adapter records these transitions in `project/logs/publish-history.json`:

```text
idle → building → signing → exporting → uploading → uploaded
                                  └──────────────────────→ failed
```

### State meanings

- `idle` — conceptual pre-start state before a history row is appended
- `building` — archive command is about to run or is running
- `signing` — export options are being generated using env refs and config
- `exporting` — `xcodebuild -exportArchive` is running
- `uploading` — the IPA is being uploaded with `xcrun`
- `uploaded` — upload finished successfully
- `failed` — any build/export/upload failure; `completed_at` must be set

## Dry-run Mode

`--dry-run` is mandatory for safe CI validation without live Apple credentials.

Behavior:

- All `xcodebuild` / `xcrun` commands are printed with a `[DRY RUN]` prefix.
- Commands are **not** executed.
- State-machine writes still happen so reviewers can inspect the planned flow.
- The adapter exits `0` after simulating a successful upload.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Pipeline completed successfully or dry-run finished successfully |
| `3` | Build, sign, export, upload, or history-update failure |
| `4` | Config or env validation failure |

## Post-deploy manual steps

After a successful upload, the deploy flow must print:

✅ Upload complete. Next manual steps:
1. Go to App Store Connect → Apps → [Your App] → TestFlight (or App Store)
2. Find the new build and submit for review / release
3. Set release notes if required

Print the same block in `--non-interactive` mode so CI logs capture it.

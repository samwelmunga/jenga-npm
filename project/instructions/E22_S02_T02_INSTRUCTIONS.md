# /publish setup prerequisites — Setup Instructions

**Epic**: E22 — /publish Skill — Deployment Pipeline Orchestrator
**Required before**: E22_S02_T02 / E22_S02_T03 runtime usage

## Overview

Before `/publish setup` and `/publish deploy` can be used for a real iOS target, the user must gather the Apple-specific identifiers and create environment variables for any sensitive values. The wizard stores only environment-variable references in `publish.json`; it does not provision Apple resources or create secrets for the user.

## Steps

1. Decide the target name, bundle identifier, Xcode scheme, and export method (`ad-hoc` or `app-store`) for the app you want to publish.
2. Gather the Apple Team ID and any provisioning/profile identifiers required by your release process.
3. Create environment variables for sensitive values such as the App Store Connect API key identifiers and provisioning profile references, then store the secret values in a safe location such as the macOS Keychain, CI secrets, or a gitignored local env file.
4. Export those environment variables in the shell or CI environment that will run `/publish deploy`.

## Verification

Confirm each environment variable is available in the shell with commands such as `printenv APP_STORE_CONNECT_API_KEY_ID` (without printing sensitive secret contents into logs where possible). The setup wizard will also warn when a referenced environment variable is missing.

## Notes

See `skills/publish/assets/secrets-guide.md` for the approved storage patterns and the warning against committing secrets.

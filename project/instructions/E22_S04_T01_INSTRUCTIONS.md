# Apple Developer Credential Setup — iOS Publish Adapter

**Epic**: E22 — /publish Skill — Deployment Pipeline Orchestrator  
**Required before**: E22_S04 — iOS App Store adapter v1

## Overview

Before the iOS publish adapter can run against real Apple services, you must provision App Store Connect API access, Apple code-signing assets, and local Xcode signing configuration. The adapter only references environment variables; never commit credentials into this repository.

## Steps

1. **Create an App Store Connect API key**
   - In App Store Connect, open **Users and Access → Integrations → App Store Connect API**.
   - Create a key with access appropriate for uploading builds.
   - Record the **Key ID** for `APP_STORE_CONNECT_API_KEY_ID`.
   - Record the **Issuer ID** for `APP_STORE_CONNECT_ISSUER_ID`.
   - Download the private key `.p8` file once and store it securely outside the repo.
   - Point `APP_STORE_CONNECT_PRIVATE_KEY_PATH` at that local file path.

2. **Prepare the Apple Developer signing assets**
   - In the Apple Developer portal, confirm the app identifier exists for your bundle ID.
   - Create or renew the provisioning profile needed for the target export method:
     - `ad-hoc` for staging/internal distribution
     - `app-store` for production uploads
   - Record the provisioning profile UUID for `PROVISIONING_PROFILE_UUID`.
   - Ensure the certificate/private key are installed in your login keychain.
   - Record the exact signing identity common name for `CODE_SIGN_IDENTITY`.

3. **Confirm local Xcode project settings**
   - Make sure the project/scheme configured in `publish.json` builds locally with Xcode.
   - Confirm the target team ID, scheme name, configuration name, archive path, and export path you plan to use.
   - Confirm the machine has `xcodebuild` and `xcrun` available from the active Xcode toolchain.

4. **Export environment variables securely**
   - Set the required variables in your shell profile, CI secret store, or another secure local mechanism:
     - `APP_STORE_CONNECT_API_KEY_ID`
     - `APP_STORE_CONNECT_ISSUER_ID`
     - `APP_STORE_CONNECT_PRIVATE_KEY_PATH`
     - `CODE_SIGN_IDENTITY`
     - `PROVISIONING_PROFILE_UUID`
   - Do not place credential values in tracked files.

## Verification

- Run the adapter env validation script once this story is implemented:
  `bash skills/publish/scripts/validate_ios_env.sh <path-to-publish.json>`
- Confirm it exits successfully when the required variables are present.
- Confirm the referenced private key path exists locally and is readable.
- Confirm Xcode can archive the configured scheme on the same machine.

## Notes

- App Store Connect API keys can only be downloaded once; store the `.p8` file safely.
- The adapter does not create Apple accounts, certificates, bundle identifiers, or provisioning profiles for you.
- Manual App Store Connect actions still remain after upload (for example TestFlight review or App Store submission).

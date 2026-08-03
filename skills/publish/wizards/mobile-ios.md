# mobile-ios setup wizard

Use this template to collect the values required for a `mobile-ios` publish target.
Each section maps directly to a field in `publish.json`.

## Question: bundle_id

Maps to: `targets[].ios.bundle_id`

Enter the iOS bundle identifier for the app you want to publish.
This should match the bundle identifier configured in Xcode and Apple Developer.

## Expected format:

Reverse-DNS identifier such as `com.example.myapp`.

## Question: team_id

Maps to: `targets[].ios.team_id`

Enter the Apple Developer Team ID that owns the signing assets for this app.

## Expected format:

Uppercase alphanumeric team identifier such as `ABCDE12345`.

## Question: scheme

Maps to: `targets[].ios.scheme`

Enter the Xcode scheme that should be built for publish flows.

## Expected format:

A non-empty scheme name such as `MyApp` or `MyAppRelease`.

## Question: configuration

Maps to: `targets[].ios.configuration`

Enter the Xcode build configuration for the publish flow.

## Expected format:

Usually `Release`. Press Enter to accept the default.

## Question: archive_path

Maps to: `targets[].ios.archive_path`

Enter the repo-relative path where the Xcode archive should be written.

## Expected format:

A non-empty path such as `build/ios/staging/MyApp.xcarchive`.

## Question: export_path

Maps to: `targets[].ios.export_path`

Enter the repo-relative path where exported build artifacts should be written.

## Expected format:

A non-empty path such as `build/ios/staging/export`.

## Question: export_method

Maps to: `targets[].ios.export_method`

Choose the export method used for packaging the archive.

## Expected format:

One of: `ad-hoc`, `app-store`.

## Question: app_store_app_id

Maps to: `targets[].ios.app_store_app_id`

Enter the numeric App Store Connect app identifier for this target.

## Expected format:

Digits only such as `1234567890`.

## Question: project_or_workspace_path

Maps to: `targets[].ios.project_path` or `targets[].ios.workspace_path`

Enter the repo-relative Xcode project or workspace path used for builds.

## Expected format:

A path ending in `.xcodeproj` or `.xcworkspace`.

## Question: provider_short_name

Maps to: `targets[].ios.provider_short_name`

Optionally enter the App Store Connect provider short name used by some upload flows.
Leave blank if not needed.

## Expected format:

Optional short string such as `exampleco`.

## Question: api_key_id_env_var

Maps to: `targets[].secrets.app_store_connect_api_key_id`

Enter the environment-variable name that will supply the App Store Connect API key identifier.
See `skills/publish/assets/secrets-guide.md` before answering.

## Expected format:

Uppercase environment-variable name such as `APP_STORE_CONNECT_API_KEY_ID`.

## Question: issuer_id_env_var

Maps to: `targets[].secrets.app_store_connect_issuer_id`

Enter the environment-variable name that will supply the App Store Connect issuer identifier.

## Expected format:

Uppercase environment-variable name such as `APP_STORE_CONNECT_ISSUER_ID`.

## Question: private_key_path_env_var

Maps to: `targets[].secrets.app_store_connect_private_key_path`

Enter the environment-variable name that will supply the filesystem path to the App Store Connect private key.

## Expected format:

Uppercase environment-variable name such as `APP_STORE_CONNECT_PRIVATE_KEY_PATH`.

## Question: code_sign_identity_env_var

Maps to: `targets[].secrets.code_sign_identity`

Enter the environment-variable name that will supply the iOS code-sign identity.

## Expected format:

Uppercase environment-variable name such as `CODE_SIGN_IDENTITY`.

## Question: provisioning_profile_uuid_env_var

Maps to: `targets[].secrets.provisioning_profile_uuid`

Enter the environment-variable name that will supply the provisioning profile UUID reference.

## Expected format:

Uppercase environment-variable name such as `PROVISIONING_PROFILE_UUID`.

# Publish secrets guide

## Never do this

Never commit secrets, tokens, certificates, API keys, or `.env` files into git.
Use gitignored local files or secret stores instead.

```gitignore
.env
.env.*
*.local
```

If a value is sensitive, keep the real value outside the repository and store only its environment-variable name in `publish.json`.

## Local development

For local-only setup, keep secrets in a gitignored `.env` file or shell profile and load them before running `/publish`.
If you already use `direnv`, prefer a gitignored `.envrc` or sourced env file so the variables are loaded automatically when you enter the project.

Example:

```bash
export APP_STORE_CONNECT_API_KEY_ID=ABC123XYZ
export IOS_PROVISIONING_PROFILE_UUID=11111111-2222-3333-4444-555555555555
```

## macOS Keychain

Use the macOS Keychain when you do not want long-lived secret values sitting in plain text files.
Store a secret:

```bash
security add-generic-password -a "$USER" -s publish.app-store-connect.api-key-id -w '<value>'
```

Read it later into an environment variable:

```bash
export APP_STORE_CONNECT_API_KEY_ID="$(security find-generic-password -a "$USER" -s publish.app-store-connect.api-key-id -w)"
```

You can repeat the same pattern for provisioning-profile references or other deploy credentials.

## GitHub Actions / CI secrets

Store shared secrets in repository or organization secrets, then map them to job-level environment variables.
Reference them in workflow files with `${{ secrets.NAME }}`.

Example:

```yaml
env:
  APP_STORE_CONNECT_API_KEY_ID: ${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}
  IOS_PROVISIONING_PROFILE_UUID: ${{ secrets.IOS_PROVISIONING_PROFILE_UUID }}
```

Use repository secrets for project-specific values and organization secrets for centrally managed credentials that multiple repositories share.

## General rule

Secrets in `publish.json` are always environment-variable references such as `APP_STORE_CONNECT_API_KEY_ID`.
Do not put literal secret values in `publish.json`, shell scripts, commit messages, or logs.

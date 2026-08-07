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

## Droplet (GitHub Actions → SSH)

The `droplet` adapter reads all SSH credentials from GitHub Actions secrets at workflow runtime. Your `publish.json` stores only the *names* of the secrets — never the values.

### Required secrets

| Secret name | Value |
|---|---|
| `DROPLET_SSH_HOST` | IP address or FQDN of your target host |
| `DROPLET_SSH_USER` | SSH login username (e.g. `ubuntu`, `deploy`) |
| `DROPLET_SSH_PORT` | SSH port number (usually `22`) |
| `DROPLET_SSH_KEY` | Contents of the private key used to SSH into the host |
| `DROPLET_KNOWN_HOSTS` | Output of `ssh-keyscan -H <host>` |

### How to add secrets

Via the `gh` CLI (recommended):

```bash
gh secret set DROPLET_SSH_HOST --body "1.2.3.4" --repo owner/myrepo
gh secret set DROPLET_SSH_USER --body "deploy" --repo owner/myrepo
gh secret set DROPLET_SSH_PORT --body "22" --repo owner/myrepo
gh secret set DROPLET_SSH_KEY < ~/.ssh/id_deploy --repo owner/myrepo
ssh-keyscan -H 1.2.3.4 | gh secret set DROPLET_KNOWN_HOSTS --repo owner/myrepo
```

Via the GitHub UI: **Repository → Settings → Secrets and variables → Actions → New repository secret**.

### Generating the SSH key pair

If you don't have a dedicated deploy key:

```bash
ssh-keygen -t ed25519 -C "deploy@myrepo" -f ~/.ssh/id_deploy -N ""
# Add the public key to the host's authorized_keys:
ssh-copy-id -i ~/.ssh/id_deploy.pub deploy@1.2.3.4
# Then add the private key to GitHub secrets (see above)
```

Never commit the private key to the repository.

## General rule

Secrets in `publish.json` are always environment-variable references such as `APP_STORE_CONNECT_API_KEY_ID`.
Do not put literal secret values in `publish.json`, shell scripts, commit messages, or logs.

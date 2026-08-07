# `droplet` Adapter

The `droplet` adapter drives the `/publish deploy` flow for SSH-reachable Linux
host targets. Despite the name, nothing in the flow is DigitalOcean-specific — it
works against any Linux host reachable via SSH. The adapter generates a GitHub
Actions workflow that performs all deploy orchestration remotely; the local machine
never SSHes directly into the host.

## Purpose

Deploy a web application or service from a GitHub repository to a Linux host
(DigitalOcean Droplet, VPS, bare-metal server, or any SSH-reachable machine) by:

1. Generating a GitHub Actions workflow that SSHes into the host using
   `appleboy/ssh-action`.
2. Committing the workflow file (`.github/workflows/publish-droplet.yml`) to the
   repository.
3. Triggering the workflow via `gh workflow run`.

The host stays passive — it does not poll; all orchestration originates from
GitHub Actions. The user supplies `build_cmd` and `start_cmd`; the adapter makes
no assumptions about the runtime stack (no PM2 templates, no nginx config, no
systemd unit generation in v1).

## Trust Boundary

`publish.json` holds **only** configuration values and secret name references —
never actual secrets. The five secret values (SSH private key, host, user, port,
known_hosts) live exclusively in GitHub Actions secrets.

```
publish.json                GitHub Actions secrets
──────────────              ──────────────────────────────
ssh_key_secret: "DROPLET_SSH_KEY"   →  ${{ secrets.DROPLET_SSH_KEY }}   ← private key
known_hosts_secret: "DROPLET_KNOWN_HOSTS" → ${{ secrets.DROPLET_KNOWN_HOSTS }}
host: "192.168.1.10"  (baked into workflow — not a secret)
```

`host`, `ssh_user`, `ssh_port`, `deploy_path`, `deploy_branch`, `build_cmd`, and
`start_cmd` are non-sensitive configuration values stored in `publish.json` and
expanded into the generated workflow YAML. If you prefer to keep the host address
private too, supply it via a GitHub Actions secret and reference it in `start_cmd`.

## Invocation Contract

### Inputs from `publish.json`

A `droplet` target must define:

- `name`
- `type: droplet`
- `platform: droplet-ssh`
- `checks.pre[]` / `checks.post[]`
- `secrets.ssh_key_secret` — GitHub Actions secret name for the SSH private key
- `secrets.known_hosts_secret` — GitHub Actions secret name for known_hosts
- `droplet.host` — IP or FQDN of the target host
- `droplet.ssh_user` — SSH username
- `droplet.ssh_port` — SSH port (default: 22)
- `droplet.deploy_path` — absolute path on the remote host
- `droplet.github_repo` — `owner/name` format
- `droplet.deploy_branch` — branch to pull during deploy
- `droplet.start_cmd` — required; command to (re)start the service
- `droplet.build_cmd` — optional; build command to run before starting

### Required environment and tools

The adapter requires the following tools at invocation time:

- `jq` — to read `publish.json` target config
- `git` — to commit the generated workflow file
- `gh` — GitHub CLI, to trigger the workflow via `gh workflow run`

The `gh` CLI must be authenticated (`gh auth login`) before running
`/publish deploy` against a droplet target.

### Pipeline entrypoint

```bash
bash skills/publish/scripts/droplet_pipeline.sh \
  --target <name> \
  --config <path-to-publish.json> \
  [--dry-run]
```

## Execution Phases

Run the adapter phases in this exact order:

1. **`validate`** — call `validate_droplet_env.sh`; abort with exit 4 if any
   required field in the target config is missing or empty.

2. **`generate-workflow`** — produce the GitHub Actions YAML in memory using a
   here-doc. The `appleboy/ssh-action` step is pinned to a specific commit SHA
   (not a floating tag) to prevent supply-chain surprises. In `--dry-run` mode,
   print the YAML to stdout and exit 0 without writing any file.

3. **`commit-workflow`** — write the YAML to
   `.github/workflows/publish-droplet.yml` (creating the directory if needed)
   and commit it with:
   ```
   git add .github/workflows/publish-droplet.yml
   git commit -m "chore(publish): update droplet workflow for target <name>"
   ```
   If the file already exists and the content is unchanged (`git diff --quiet`),
   skip the commit — the operation is idempotent.

4. **`trigger`** — invoke `gh workflow run publish-droplet.yml --repo <github_repo>`
   to start the workflow. After dispatching, retrieve the run URL via
   `gh run list --workflow publish-droplet.yml --limit 1 --json url`.

5. **`triggered`** — print the workflow run URL to stdout. The caller
   (`publish_deploy.sh`) writes the ledger entry with `platform_state: "triggered"`.

## Dry-run Mode

`--dry-run` is supported for safe end-to-end rehearsals without triggering a
real deploy.

Behavior in dry-run mode:

- The `validate` phase runs normally; config errors still surface.
- The `generate-workflow` phase runs normally; the YAML is printed to stdout.
- The `commit-workflow` phase is **skipped** — no file is written, no git commit
  is made.
- The `trigger` phase is **skipped** — `gh workflow run` is not called.
- The adapter exits 0 after printing the YAML.
- The ledger entry written by `publish_deploy.sh` will have
  `platform_state: "dry-run"`.

## Exit Codes

| Code | Meaning                                                           |
|------|-------------------------------------------------------------------|
| `0`  | Pipeline completed successfully, or `--dry-run` finished cleanly  |
| `4`  | Config or env invalid — required field missing or `jq`/`gh` absent|
| `3`  | Workflow trigger failure (`gh workflow run` exited non-zero)       |

## Output Artefacts

A successful non-dry-run produces:

- `.github/workflows/publish-droplet.yml` committed to the repository
- A `gh workflow run` dispatch recorded in GitHub Actions history
- A workflow run URL printed to stdout
- A history entry in `project/logs/publish-history.json` written by
  `publish_deploy.sh` with `platform_state: "triggered"`

## Post-deploy manual steps

After a successful deploy trigger, the deploy flow must print:

Deploy triggered. Next manual steps:
1. Monitor the workflow run at the URL printed above.
2. If the run fails, check the GitHub Actions logs for SSH or script errors.
3. Push a commit to `<deploy_branch>` to auto-trigger future deploys once the
   generated workflow has been merged into the branch.

Print the same block regardless of interactive/non-interactive mode so CI logs
capture it.

## First-run bootstrap caveat

Creating the deploy path and performing the initial `git clone` on the remote
host is **out of scope for v1** and must be done manually before the first
`/publish deploy` invocation.

Minimum bootstrap on the host:

```bash
# SSH into the host
ssh <ssh_user>@<host>

# Clone the repository into deploy_path
git clone https://github.com/<github_repo>.git <deploy_path>
cd <deploy_path>

# Install runtime dependencies (example for Node.js)
npm install

# Verify start_cmd works
# e.g.: pm2 reload ecosystem.config.js
```

Document these steps for your team. The wizard emits a post-setup instructions
file at `project/instructions/E22_S07_INSTRUCTIONS.md` with a bootstrap checklist.

## Runtime agnosticism

The adapter does not generate PM2 configs, nginx virtual-host files, or systemd
unit files. Users embed runtime-specific commands directly in `build_cmd` and
`start_cmd`. Examples:

| Runtime   | start_cmd example                                   |
|-----------|-----------------------------------------------------|
| PM2       | `pm2 reload ecosystem.config.js`                    |
| systemd   | `sudo systemctl restart myapp`                      |
| Docker    | `docker compose up -d --build`                      |
| Custom    | `./scripts/restart.sh`                              |

Opinionated runtime templates are deferred to future adapter versions.

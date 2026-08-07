# Droplet setup wizard

Use this template to collect the values required for a `droplet` publish target.
Each section maps directly to a field in `publish.json`. The adapter is generic —
it works with any SSH-reachable Linux host, not just DigitalOcean droplets.

Before running the prompts, check whether `publish.json` already contains a target
whose `type` is `droplet`. If one exists, ask the user whether to **overwrite**
the existing target or **update** individual fields — do not silently replace it.

After collecting answers, write the target block to `publish.json` (create the
file from the base scaffold if it does not exist), validate the config, and write
`project/instructions/E22_S07_INSTRUCTIONS.md` listing the required GitHub secrets.
See the "Post-collection actions" section at the bottom for the full write sequence.

---

## Question: host

Maps to: `targets[].droplet.host`

Enter the IP address or fully qualified domain name (FQDN) of the target host.
This is the address GitHub Actions will SSH into when deploying.

## Expected format:

A valid IPv4 address or hostname (e.g. `192.168.1.10`, `deploy.example.com`).

---

## Question: ssh_user

Maps to: `targets[].droplet.ssh_user`

Enter the SSH username used to connect to the target host. This user must have
read/write access to the `deploy_path` directory and permission to execute
`build_cmd` and `start_cmd`.

## Expected format:

A valid Unix username (e.g. `deploy`, `ubuntu`, `root`).

---

## Question: ssh_port

Maps to: `targets[].droplet.ssh_port`

Enter the SSH port on the target host. Press Enter to accept the default (22).

## Expected format:

An integer between 1 and 65535. Press Enter to accept the default (`22`).

---

## Question: deploy_path

Maps to: `targets[].droplet.deploy_path`

Enter the absolute path on the remote host where the repository is checked out.
This directory must already exist and contain a valid git working tree before the
first deploy (see First-run bootstrap in post-setup manual steps).

## Expected format:

An absolute Unix path (e.g. `/var/www/myapp`, `/home/deploy/myapp`).

---

## Question: github_repo

Maps to: `targets[].droplet.github_repo`

Enter the GitHub repository that hosts this project, in `owner/name` format.
The adapter uses this value with `gh workflow run` to trigger the generated
workflow.

## Expected format:

`owner/name` (e.g. `acme-corp/my-app`). Must match the pattern
`^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$`.

---

## Question: deploy_branch

Maps to: `targets[].droplet.deploy_branch`

Enter the git branch to pull on the remote host during deploy. The generated
GitHub Actions workflow will run `git pull origin <deploy_branch>` on the host.

## Expected format:

A git branch name (e.g. `main`, `production`). Press Enter to accept the
default (`main`).

---

## Question: build_cmd

Maps to: `targets[].droplet.build_cmd`

Enter the build command to run on the remote host after pulling (e.g.
`npm run build`, `make build`, `pip install -r requirements.txt`). Leave blank
to skip the build step — the `build_cmd` field is optional.

## Expected format:

Any valid shell command string, or press Enter to skip.

---

## Question: start_cmd

Maps to: `targets[].droplet.start_cmd`

Enter the command to (re)start the service on the remote host after deploy.
The adapter makes no assumptions about your runtime — supply whatever command
your deployment uses. This field is required.

## Expected format:

A valid shell command (e.g. `pm2 reload ecosystem.config.js`,
`sudo systemctl restart myapp`, `./scripts/restart.sh`).

---

## Question: ssh_key_secret

Maps to: `targets[].secrets.ssh_key_secret`

Enter the **name** of the GitHub Actions secret that holds the SSH private key
used to authenticate with the target host. Do not enter the key value itself —
only the secret name. The adapter reads this name and injects
`${{ secrets.<ssh_key_secret> }}` into the generated workflow.

## Expected format:

A GitHub Actions secret name (e.g. `DROPLET_SSH_KEY`). Uppercase, underscores
allowed.

---

## Question: known_hosts_secret

Maps to: `targets[].secrets.known_hosts_secret`

Enter the **name** of the GitHub Actions secret that holds the known_hosts
entry for the target host. This prevents MITM attacks during the SSH connection
from GitHub Actions. Generate the value with `ssh-keyscan <host>`.

## Expected format:

A GitHub Actions secret name (e.g. `DROPLET_KNOWN_HOSTS`).

---

## Secrets Guide

The following secrets must be added to the GitHub repository before the first
deploy. Navigate to **Settings → Secrets and variables → Actions → New
repository secret** in the GitHub UI, or use the `gh` CLI as shown below.

| Secret name           | What it holds                                                    |
|-----------------------|------------------------------------------------------------------|
| `DROPLET_SSH_KEY`     | Contents of the SSH private key file (e.g. `~/.ssh/id_deploy`)  |
| `DROPLET_SSH_HOST`    | IP address or FQDN of the target host                            |
| `DROPLET_SSH_USER`    | SSH username on the target host                                  |
| `DROPLET_SSH_PORT`    | SSH port (typically `22`)                                        |
| `DROPLET_KNOWN_HOSTS` | Output of `ssh-keyscan <host>` for the target host               |

### How to add secrets via `gh` CLI

```bash
# Private key — reads from file
gh secret set DROPLET_SSH_KEY < ~/.ssh/id_deploy

# Host and connection details
gh secret set DROPLET_SSH_HOST --body "your.host.ip.or.fqdn"
gh secret set DROPLET_SSH_USER --body "your-ssh-user"
gh secret set DROPLET_SSH_PORT --body "22"

# Known hosts — generate with ssh-keyscan
ssh-keyscan your.host.ip.or.fqdn | gh secret set DROPLET_KNOWN_HOSTS
```

### Via GitHub UI

1. Go to your repository on GitHub.
2. Navigate to **Settings** → **Secrets and variables** → **Actions**.
3. Click **New repository secret** for each of the five secrets listed above.
4. Paste the value and save.

---

## Post-setup manual steps

After the wizard completes, the following steps must be performed manually:

1. **Add the listed secrets to the GitHub repo before the first deploy.**
   The workflow will fail immediately if any of the five secrets above are
   missing. Verify them at Settings → Secrets and variables → Actions.

2. **Bootstrap the deploy path on the host before the first deploy.**
   The adapter assumes the deploy path already contains a git working tree.
   SSH into the host and run:
   ```bash
   git clone <your-repo-url> <deploy_path>
   cd <deploy_path>
   # Install any runtime dependencies (e.g. npm install, pip install)
   ```

3. **Push a commit to the deploy branch to trigger the first deploy.**
   After running `/publish deploy --target <name>`, the generated workflow will
   be committed and can be triggered via `gh workflow run` or by pushing to the
   configured deploy branch.

---

## Post-collection actions

Once all answers have been collected, perform the following steps in order:

1. **Load or scaffold `publish.json`.** If the file does not exist at the
   project root, create it from the base scaffold with `version: 1`,
   populated `defaults`, and an empty `targets` array. If it does exist,
   parse and preserve every unrelated field.

2. **Check for an existing droplet target.** Scan `targets[]` for any entry
   with `"type": "droplet"`. If one exists, ask the user:
   - **overwrite** — replace the entire target block with the wizard output
   - **update** — merge the wizard answers into the existing target
     field-by-field, keeping any user-added fields (e.g. custom `checks`)
   If none exists, append a new target block.

3. **Write the target block.** Emit it in the exact shape below (omit
   `build_cmd` if the user left it blank):

   ```json
   {
     "name": "my-droplet",
     "type": "droplet",
     "platform": "droplet-ssh",
     "checks": { "pre": ["build", "test"], "post": [] },
     "secrets": {
       "ssh_key_secret": "DROPLET_SSH_KEY",
       "known_hosts_secret": "DROPLET_KNOWN_HOSTS"
     },
     "droplet": {
       "host": "<answer>",
       "ssh_user": "<answer>",
       "ssh_port": 22,
       "deploy_path": "<answer>",
       "github_repo": "<answer>",
       "deploy_branch": "<answer>",
       "build_cmd": "<answer or omit if blank>",
       "start_cmd": "<answer>"
     }
   }
   ```

4. **Validate against the schema.** Run
   `bash skills/publish/scripts/validate_config.sh <path-to-publish.json>`
   before saving. If validation fails, report the error and abort — do not
   write a broken `publish.json`.

5. **Write the instructions file.** Create
   `project/instructions/E22_S07_INSTRUCTIONS.md` listing the five required
   GitHub secrets and how to add them. Create the `project/instructions/`
   directory if it does not exist.

6. **Report to the user.** Print a short summary listing (a) the target block
   written, (b) the path to the instructions file, and (c) the five GitHub
   secrets that must be configured before the first deploy.

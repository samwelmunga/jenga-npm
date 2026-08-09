# `npm-ci` Adapter

The `npm-ci` adapter drives the `/publish deploy` flow for npm package targets.
It publishes to npmjs.com via **GitHub Actions OIDC Trusted Publishers** — no
`NPM_TOKEN` is stored anywhere. The adapter generates a GitHub Actions workflow
that runs `npm publish --provenance`, commits it to the repository, and triggers
it via `gh workflow run`. The local machine never publishes directly to npm.

## Purpose

Publish an npm package from a GitHub repository to npmjs.com by:

1. Generating a GitHub Actions workflow that authenticates to npm using a
   short-lived OIDC token issued by GitHub's token service.
2. Committing the workflow file to `<workflow_path>` (default:
   `.github/workflows/npm-publish.yml`) in the repository.
3. Triggering the workflow via `gh workflow run`.

No `NPM_TOKEN` is created, stored, or referenced. All authorisation is handled
through the npmjs.com Trusted Publisher link established between the package and
the repository.

## Trust Boundary

`publish.json` holds **only** configuration values — no secrets of any kind.
The trust chain is OIDC-based:

```
publish.json                GitHub Actions                npmjs.com
──────────────              ──────────────────────────    ─────────────────────────────
github_repo: "owner/name"  ← OIDC token issued per run  ← Trusted Publisher link
npm.package_name: "pkg"       scoped to this package        (package ↔ repo + workflow)
npm.access: "public"
```

GitHub's token service issues a short-lived OIDC token for each workflow run.
The npmjs.com Trusted Publisher configuration — a one-time link between the
package name and the repository + workflow file path — is the sole source of
authorisation. Once that link is in place, any workflow run originating from
the linked repository and workflow path may publish the package without a stored
token.

No secret values are committed to `publish.json` or the repository. Any
`secrets` block present in the target config is ignored by this adapter.

## Invocation Contract

### Inputs from `publish.json`

An `npm-ci` target must define:

- `name`
- `type: npm-ci`
- `npm.package_name` — name of the npm package to publish
- `npm.access` — `"public"` or `"restricted"`
- `npm.registry` — registry URL (default: `https://registry.npmjs.org`)
- `npm.dist_tag` — npm dist-tag (e.g. `latest`, `beta`)
- `github_repo` — **required**; `owner/name` identifying the GitHub repository
- `workflow_path` — **optional**; path to the workflow file to generate and
  trigger; defaults to `.github/workflows/npm-publish.yml`
- `secrets` — **not required**; any `secrets` block present is ignored by this
  adapter

The `npm.*` fields are read through the shared `npmSettings` schema, reused
across all npm-targeting adapters.

### Required environment and tools

The adapter requires the following tools at invocation time:

- `jq` — to read `publish.json` target config
- `git` — to commit the generated workflow file
- `gh` — GitHub CLI, authenticated via `gh auth login`, to trigger the workflow
  via `gh workflow run`

The `gh` CLI must be authenticated before running `/publish deploy` against an
`npm-ci` target.

### Pipeline entrypoint

```bash
bash skills/publish/scripts/npm_ci_pipeline.sh \
  --target <name> \
  --config <path-to-publish.json> \
  [--dry-run]
```

## Execution Phases

Run the adapter phases in this exact order:

1. **`validate`** — verify that `gh` CLI is authenticated (`gh auth status`),
   that `github_repo` resolves to an accessible repository, and that all
   required `npm.*` fields (`package_name`, `access`, `registry`, `dist_tag`)
   are present and non-empty. Abort with exit 4 on any failure.

2. **`generate-workflow`** — render the GitHub Actions workflow YAML in memory.
   The generated workflow sets:
   ```yaml
   permissions:
     id-token: write
     contents: read
   ```
   and runs `npm publish --provenance` to attach a build provenance attestation
   to the published package. In `--dry-run` mode, print the rendered YAML to
   stdout and exit 0 without writing any file.

3. **`commit-workflow`** — write the generated YAML to `<workflow_path>`
   (creating the `.github/workflows/` directory if needed) and commit it with:
   ```
   git add <workflow_path>
   git commit -m "chore(publish): update npm CI workflow for target <name>"
   ```
   If the file already exists and the content is unchanged (`git diff --quiet`),
   skip the commit — the operation is idempotent.

4. **`trigger`** — invoke:
   ```bash
   gh workflow run <workflow_filename> --ref <branch>
   ```
   where `<workflow_filename>` is the basename of `<workflow_path>`. After
   dispatching, retrieve the run URL via
   `gh run list --workflow <workflow_filename> --limit 1 --json url`.

5. **`triggered`** — print the workflow run URL to stdout. The caller
   (`publish_deploy.sh`) writes the ledger entry with
   `platform_state: "triggered"`.

## State Machine

```
start
  │
  ▼
validate ──── exit 4 (config/env invalid)
  │
  ▼
generate-workflow ──── [--dry-run] → print YAML → exit 0
  │
  ▼
commit-workflow
  │
  ▼
trigger ──── exit 3 (gh workflow run failed)
  │
  ▼
triggered → exit 0 (success)
```

Terminal states:

- **success** — all five phases complete; workflow run URL printed; exit 0.
- **dry-run exit** — adapter exits after `generate-workflow` without writing,
  committing, or triggering; exit 0.
- **failure** — adapter exits with a non-zero code at the failing phase (see
  Exit Codes).

## Dry-Run Behaviour

When `--dry-run` is passed:

- The `validate` phase runs normally; config and environment errors still
  surface.
- The `generate-workflow` phase runs normally; the rendered workflow YAML is
  printed to stdout.
- The `commit-workflow` phase is **skipped** — no file is written, no git
  commit is made.
- The `trigger` phase is **skipped** — `gh workflow run` is not called.
- The adapter exits 0 after printing the YAML.
- The ledger entry written by `publish_deploy.sh` will have
  `platform_state: "dry-run"`.

## Exit Codes

| Code | Meaning                                                                     |
|------|-----------------------------------------------------------------------------|
| `0`  | Pipeline completed successfully, or `--dry-run` finished cleanly            |
| `3`  | Workflow trigger failure (`gh workflow run` exited non-zero)                 |
| `4`  | Config or environment invalid (missing required field, `gh` not authed,     |
|      | `github_repo` not found, or required `npm.*` field absent)                  |

## Output Artefacts

A successful non-dry-run produces:

- The workflow file written to `<workflow_path>` in the working tree (default:
  `.github/workflows/npm-publish.yml`) and committed to the repository
- A git commit: `chore(publish): update npm CI workflow for target <name>`
- A workflow run URL printed to stdout
- A history entry in `project/logs/publish-history.json` written by
  `publish_deploy.sh` with `platform_state: "triggered"`

## Post-Deploy Manual Steps

After a successful deploy trigger, the adapter prints the workflow run URL.
The operator should:

1. Open the printed run URL to monitor the publish job in GitHub Actions.
2. Verify the package appears on npmjs.com with the expected version and
   provenance badge (the shield icon confirming `npm publish --provenance`).
3. Confirm the dist-tag (`latest`, `beta`, or other) is correctly applied on
   the npmjs.com package page.

The adapter does not wait for the CI run to complete — monitoring is the
operator's responsibility.

## First-run prerequisite

The npmjs.com Trusted Publisher link between the package and the repository must
be established **before** the first `/publish deploy` invocation against an
`npm-ci` target. This one-time setup step is out of scope for the adapter itself
and is covered by the setup wizard (see S03).

Minimum pre-requisites:

- The package must already exist on npmjs.com (or be publishable under your
  npm account).
- A Trusted Publisher must be configured on npmjs.com linking the package to
  `github_repo` + `workflow_path`.
- The GitHub repository must have Actions enabled.

Once the Trusted Publisher link is in place, the adapter can publish on every
invocation without any stored token.

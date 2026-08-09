# npm-ci setup wizard

Use this template to collect the values required for an `npm-ci` publish target.
Each section maps directly to a field in `publish.json`. Unlike the `npm` target
type, `npm-ci` publishes via GitHub Actions OIDC (Trusted Publishers) — no
`NPM_TOKEN` is stored anywhere. All authorisation is handled through the
npmjs.com Trusted Publisher link between the package and the GitHub repository.

Before running the prompts, load the project's `package.json` (if present) so
`name` can be offered as the default for `package_name`. If `publish.json`
already contains a target whose `type` is `npm-ci`, ask the user whether to
**overwrite** the existing target or **update** individual fields — do not
silently replace it.

After collecting answers, write the target block to `publish.json` (create the
file from the base scaffold if it does not exist). No instructions file is
generated for this target type — there is no secret to configure. See the
"Post-collection actions" section at the bottom for the full write sequence.

## Prerequisites

Before running this wizard, confirm that all of the following are in place:

- **`gh` CLI installed and authenticated**: run `gh auth status` to verify.
  If not authenticated, run `gh auth login` first.
- **GitHub Actions enabled** on the target repository. Actions must be enabled
  under the repository's Settings → Actions → General page.
- **The package must already exist on npmjs.com**, or be publishable under
  your npm account. A brand-new package name is created on the first successful
  publish if your account has permission to publish under that name or scope.

## One-time npmjs.com Trusted Publisher setup

Complete these steps manually in a browser **before** running `/publish deploy`
against this target for the first time. The adapter cannot establish this link
automatically — it is a one-time browser-based setup on the npmjs.com website.

1. Sign in to https://www.npmjs.com with the account that owns (or is a
   maintainer of) the package.
2. Navigate to your package page. If the package does not exist yet, create it
   first (publish a placeholder version locally before configuring Trusted
   Publishers, or ensure your account has permission to publish under the
   chosen name or scope on first push).
3. Go to **Settings** → **Publishing** → **Trusted Publishers**.
4. Click **Add publisher**.
5. Select **GitHub Actions** as the publisher type.
6. Enter the following values:
   - **Owner/repository**: your GitHub `owner/repo`
     (e.g. `acme-org/my-package`)
   - **Workflow file path**: the path to the workflow file that will publish
     (e.g. `.github/workflows/npm-publish.yml`)
7. Click **Save**.

**Important trade-off**: once Trusted Publishers is configured on a package,
npmjs.com will **only** accept publishes originating from the linked workflow.
Local `npm publish` commands authenticated with an `NPM_TOKEN` will be rejected
for that package. If you need to publish locally in an emergency, you must
remove or disable the Trusted Publisher link on npmjs.com before using a token.
Plan accordingly before enabling this feature on a production package.

## Question: package_name

Maps to: `targets[].npm.package_name`

Enter the npm package name as it should appear in the registry.
If a `package.json` exists at the project root, offer its `name` field as the
default. Supports scoped names such as `@scope/name`.

## Expected format:

Lowercase, url-safe name matching `^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$`
(e.g. `jenga-agent`, `@my-org/utils`). Max 214 characters.

## Question: access

Maps to: `targets[].npm.access`

Choose the registry access level for this package.
`public` publishes an openly-installable package. `restricted` publishes a
private package (requires a paid npm plan or a private registry such as
GitHub Packages).

## Expected format:

One of: `public`, `restricted`. Press Enter to accept the default (`public`).

## Question: dist_tag

Maps to: `targets[].npm.dist_tag`

Enter the npm dist-tag applied to this publish. `latest` is the default
install tag; use tags like `next` or `beta` for pre-releases so that
`npm install <pkg>` continues to resolve to the current stable version.

## Expected format:

Lowercase tag matching `^[a-z0-9][a-z0-9._-]*$` (e.g. `latest`, `next`,
`beta`). Press Enter to accept the default (`latest`).

## Question: registry

Maps to: `targets[].npm.registry`

Enter the registry URL to publish to.
For the public npm registry, accept the default. For GitHub Packages, use
`https://npm.pkg.github.com`. For a private/internal registry, use the URL
provided by your registry operator.

## Expected format:

An absolute `https://` URL (e.g. `https://registry.npmjs.org`,
`https://npm.pkg.github.com`). Press Enter to accept the default
(`https://registry.npmjs.org`).

## Question: github_repo

Maps to: `targets[].github_repo`

Enter the GitHub repository that will run the publish workflow. This value is
used by the adapter to generate and trigger the GitHub Actions workflow via
`gh workflow run`. It must match the repository where the Trusted Publisher
link was established on npmjs.com.

## Expected format:

`owner/name` format matching `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`
(e.g. `acme-org/my-package`). This field is required — there is no default.

## Question: workflow_path

Maps to: `targets[].workflow_path`

Enter the path to the GitHub Actions workflow file the adapter will generate
and trigger. This must match the workflow file path entered in the npmjs.com
Trusted Publisher configuration above. If the file already exists in the
repository, the adapter will overwrite it only if its content has changed.

## Expected format:

A relative path starting with `.github/workflows/` and ending in `.yml` or
`.yaml` (e.g. `.github/workflows/npm-publish.yml`). Press Enter to accept the
default (`.github/workflows/npm-publish.yml`).

## publish.json snippet

A complete, valid example target block for the `npm-ci` type. Note that there
is no `secrets` block — this adapter uses OIDC and requires no stored tokens:

```json
{
  "name": "npm-ci-my-package",
  "type": "npm-ci",
  "platform": "npm-registry",
  "github_repo": "acme-org/my-package",
  "workflow_path": ".github/workflows/npm-publish.yml",
  "checks": {
    "pre": ["lint", "type-check"],
    "post": ["smoke-test"]
  },
  "npm": {
    "package_name": "my-package",
    "access": "public",
    "registry": "https://registry.npmjs.org",
    "dist_tag": "latest"
  }
}
```

## Post-collection actions

Once all six answers have been collected, perform the following steps in order:

1. **Load or scaffold `publish.json`.** If the file does not exist at the
   project root, create it from the base scaffold with `version: 1`,
   populated `defaults`, and an empty `targets` array. If it does exist,
   parse and preserve every unrelated field.
2. **Check for an existing `npm-ci` target.** Scan `targets[]` for any entry
   with `"type": "npm-ci"`. If one exists, ask the user:
   - **overwrite** — replace the entire target block with the wizard output
   - **update** — merge the wizard answers into the existing target
     field-by-field, keeping any user-added fields (e.g. custom `checks`
     or `notes`) intact.
   If none exists, append a new target block.
3. **Write the target block.** Emit it in the exact shape shown in the
   "publish.json snippet" section above — no `secrets` block:

   ```json
   {
     "name": "npm-ci-<package-slug>",
     "type": "npm-ci",
     "platform": "npm-registry",
     "github_repo": "<answer>",
     "workflow_path": "<answer>",
     "checks": {
       "pre": ["lint", "type-check"],
       "post": ["smoke-test"]
     },
     "npm": {
       "package_name": "<answer>",
       "access": "<answer>",
       "registry": "<answer>",
       "dist_tag": "<answer>"
     }
   }
   ```

   Notes on shape:
   - `name` is derived from the package name (slugified, lowercased, prefixed
     with `npm-ci-`). If a collision exists, suffix with `-2`, `-3`, etc.
   - `platform` is `npm-registry` for `https://registry.npmjs.org`. If the
     user supplied `https://npm.pkg.github.com`, set `platform` to
     `github-packages` instead.
   - Do not include a `secrets` block — this adapter uses OIDC and no token
     is required.
4. **Validate against the schema.** Run
   `skills/publish/scripts/validate_config.sh` before saving. If validation
   fails, report the error and abort — do not write a broken `publish.json`.
5. **Report to the user.** Print a short summary confirming (a) the target
   block written, (b) the `github_repo` value, and (c) the `workflow_path`
   value. Remind the user to complete the one-time npmjs.com Trusted Publisher
   setup (described above) before running `/publish deploy` for the first time.
6. **No instructions file is needed.** Unlike the `npm` target type, `npm-ci`
   has no secret to configure. The OIDC trust is established entirely through
   the npmjs.com Trusted Publisher link and the GitHub Actions workflow — both
   of which are documented in this wizard.

## Post-setup verification

After completing the wizard and the one-time Trusted Publisher setup:

1. Run `/publish deploy --target <name> --dry-run` to confirm the workflow YAML
   is generated correctly. The adapter will print the rendered workflow YAML to
   stdout without writing any file or triggering a run.
2. Review the printed YAML to ensure it matches the expected `npm-publish.yml`
   structure: verify that `permissions.id-token: write` is present and that the
   publish step runs `npm publish --provenance`.
3. Run `/publish deploy --target <name>` (without `--dry-run`) to trigger the
   first CI publish. The adapter will commit the workflow file to the repository
   and trigger a GitHub Actions run. Open the printed run URL to monitor the
   job in GitHub Actions.

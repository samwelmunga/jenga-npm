# npm setup wizard

Use this template to collect the values required for an `npm` publish target.
Each section maps directly to a field in `publish.json`.

Before running the prompts, load the project's `package.json` (if present) so
`name` can be offered as the default for `package_name`. If `publish.json`
already contains a target whose `type` is `npm`, ask the user whether to
**overwrite** the existing target or **update** individual fields — do not
silently replace it.

After collecting answers, write the target block to `publish.json` (create the
file from the base scaffold if it does not exist) and generate
`project/instructions/E26_S04_T02_INSTRUCTIONS.md` documenting the `NPM_TOKEN`
prerequisite. See the "Post-collection actions" section at the bottom for the
full write sequence.

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

## Question: dry_run

Maps to: `targets[].notes` (captured as a wizard-authored note; there is no
dedicated schema field for dry-run because it is a per-invocation pipeline
concern, not persistent target config).

Ask whether the first deploy against this target should be executed as a
dry-run (`npm publish --dry-run`). A dry-run packs and validates the tarball
and contacts the registry without publishing, letting you confirm the target
config end-to-end before spending a real version bump.

If the user answers **yes**, append a line to the target's `notes` field
along the lines of:

> First deploy should be a dry-run (`npm publish --dry-run`) per wizard
> preference. Remove this note after the dry-run passes.

If the user answers **no**, do not add a dry-run note; the pipeline will
publish for real on the first run.

## Expected format:

Yes/no. Press Enter to accept the default (`yes` — recommended for the first
deploy).

## Prerequisite: NPM_TOKEN

The npm pipeline reads the auth token from the `NPM_TOKEN` environment
variable at publish time (`skills/publish/adapters/npm.md` defines this
contract). The wizard does not collect the token value — that would be
unsafe. Instead, at the end of the wizard, write the following instructions
file so the user knows exactly what to configure:

**File to write:** `project/instructions/E26_S04_T02_INSTRUCTIONS.md`

**Contents (verbatim template):**

```markdown
# npm Publish — Setup Instructions

**Epic**: E26 — NPM-Compatible Distribution
**Required before**: running `/publish deploy` against the npm target

## Overview

The npm publish pipeline authenticates with the target registry using an
automation token stored in the `NPM_TOKEN` environment variable. This file
walks you through obtaining that token and making it available to the
pipeline.

## Steps

1. Sign in to https://www.npmjs.com with the account that owns (or is a
   maintainer of) the package.
2. Open **Account Settings** → **Access Tokens** → **Generate New Token**.
3. Choose **Automation** (this token type bypasses 2FA prompts, which is
   required for CI/scripted publishes).
4. Copy the generated token immediately — npm shows it only once.
5. Store the token in the environment the pipeline runs in:
   - **Local development**: add `export NPM_TOKEN=<token>` to a shell rc
     file that is loaded before running `/publish deploy`, or place it in
     a git-ignored `.env` file and source it in your shell.
   - **CI (GitHub Actions, etc.)**: add `NPM_TOKEN` as an encrypted
     repository secret and expose it to the publish job via
     `env: NPM_TOKEN: ${{ secrets.NPM_TOKEN }}`.
   - **GitHub Packages**: use a GitHub Personal Access Token with
     `write:packages` scope in place of an npm.js token, and export it as
     `NPM_TOKEN` (or `NODE_AUTH_TOKEN` if your `.npmrc` uses that name).
6. Never commit the token value to the repository. `.env` files, shell rc
   files, and CI logs must all be treated as sensitive.

## Verification

Run `npm whoami --registry <your-registry-url>` with `NPM_TOKEN` set. It
should print your npm username. If it prints an anonymous / not-logged-in
error, the token is missing, expired, or scoped to the wrong registry.

## Notes

- Automation tokens do not expire by default but can be revoked at any time
  from the npm Access Tokens page.
- If you rotate the token, update the value everywhere it is stored (local
  env, CI secrets) — the pipeline reads it fresh on every invocation.
- The `secrets.NPM_TOKEN` entry in `publish.json` is a reference like
  `"$NPM_TOKEN"`, not the token value itself. The publish adapter resolves
  the reference against the current environment.
```

Do not skip generating this file, even if the user says the token is already
configured — the instructions file is the durable record of what the
pipeline expects.

## Post-collection actions

Once all five answers have been collected, perform the following steps in
order:

1. **Load or scaffold `publish.json`.** If the file does not exist at the
   project root, create it from the base scaffold with `version: 1`,
   populated `defaults`, and an empty `targets` array. If it does exist,
   parse and preserve every unrelated field.
2. **Check for an existing npm target.** Scan `targets[]` for any entry with
   `"type": "npm"`. If one exists, ask the user:
   - **overwrite** — replace the entire target block with the wizard output
   - **update** — merge the wizard answers into the existing target
     field-by-field, keeping any user-added fields (e.g. custom `checks`
     or `notes`) intact.
   If none exists, append a new target block.
3. **Write the target block.** Emit it in the exact shape below (with
   dry-run note only if the user answered yes):

   ```json
   {
     "name": "npm-<package-slug>",
     "type": "npm",
     "platform": "npm-registry",
     "checks": {
       "pre": ["lint", "type-check"],
       "post": ["smoke-test"]
     },
     "secrets": {
       "NPM_TOKEN": "$NPM_TOKEN"
     },
     "npm": {
       "package_name": "<answer>",
       "access": "<answer>",
       "registry": "<answer>",
       "dist_tag": "<answer>"
     },
     "notes": "<optional dry-run note per user preference>"
   }
   ```

   Notes on shape:
   - `name` is derived from the package name (slugified, lowercased). If a
     collision exists, suffix with `-2`, `-3`, etc.
   - `platform` is `npm-registry` for `https://registry.npmjs.org`. If the
     user supplied `https://npm.pkg.github.com`, set `platform` to
     `github-packages` instead.
   - `secrets` includes `NPM_TOKEN` by default. If the user's registry uses
     `NODE_AUTH_TOKEN` (common with GitHub Packages `.npmrc` setups), swap
     the key accordingly — the schema accepts either.
   - Omit the `notes` field entirely when the user declined the dry-run.
4. **Validate against the schema.** Run `scripts/validate_publish_config.sh`
   (or the equivalent AJV invocation) before saving. If validation fails,
   report the error and abort — do not write a broken `publish.json`.
5. **Write the instructions file.** Create
   `project/instructions/E26_S04_T02_INSTRUCTIONS.md` with the verbatim
   template from the "Prerequisite: NPM_TOKEN" section above. Create the
   `project/instructions/` directory if it does not exist.
6. **Report to the user.** Print a short summary listing (a) the target
   block written, (b) the path to the instructions file, and (c) the exact
   env var they must set before running `/publish deploy`.

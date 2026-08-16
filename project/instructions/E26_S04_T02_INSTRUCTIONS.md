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

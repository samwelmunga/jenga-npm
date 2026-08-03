# `npm` Adapter

The `npm` adapter drives the `/publish deploy` flow for npm registry targets.
It is a prompt/template contract for the agent layer and delegates concrete execution to
`skills/publish/scripts/npm_pipeline.sh`.

## Invocation Contract

### Inputs from `publish.json`

An `npm` target must define:

- `name`
- `type: npm`
- `platform: npm-registry`
- `checks.pre[]` / `checks.post[]`
- `secrets.NPM_TOKEN` (env-var reference; `NODE_AUTH_TOKEN` is also accepted)
- `npm.package_name`
- `npm.access` (`public` or `restricted`)
- `npm.registry` (optional; defaults to `https://registry.npmjs.org`)
- `npm.dist_tag` (optional; defaults to `latest`)

### Required environment variables

The adapter uses env-var references only and never stores secret values in repo files.
The required env vars are:

- `NPM_TOKEN` (or `NODE_AUTH_TOKEN` — either satisfies the auth requirement)

Validate them before execution with:

```bash
bash skills/publish/scripts/validate_npm_env.sh <path-to-publish.json>
```

### Pipeline entrypoint

```bash
bash skills/publish/scripts/npm_pipeline.sh <target> <path-to-publish.json> [--dry-run] [--non-interactive]
```

## Execution Phases

Run the adapter phases in this exact order:

1. `validate`
2. `gates`
3. `pack`
4. `publish`
5. `tag`

Quality gates run inside the `gates` phase and must include `npm test`. If the consumer `package.json` declares a `build` script, `npm run build` also runs as a gate. Once control enters the adapter, external publish-side commands are restricted to direct `npm` and `git` invocations.

## State Machine

The adapter records these transitions in `project/logs/publish-history.json`:

```text
idle → validating → gating → packing → publishing → tagging → published
                                              └───────────────→ failed
```

### State meanings

- `idle` — conceptual pre-start state before a history row is appended
- `validating` — token presence and `publish.json` npm block are being verified
- `gating` — `npm test` (and `npm run build` when present) are running
- `packing` — `npm pack` is generating the tarball for inspection
- `publishing` — `npm publish` is running against the configured `registry` with the resolved `access` and `dist_tag`
- `tagging` — `git tag v<version>` is being created and (optionally) pushed
- `published` — publish and tag both succeeded; package is visible on the registry
- `failed` — any validation/gate/publish/tag failure; `completed_at` must be set

## Dry-run Mode

`--dry-run` is mandatory for safe CI validation without live npm credentials.

Behavior:

- The `publish` phase runs `npm publish --dry-run` instead of a live publish. No package is written to the registry; npm prints the tarball contents and would-be metadata.
- All `git tag` / `git push` commands are printed with a `[DRY RUN]` prefix and are **not** executed.
- State-machine writes still happen so reviewers can inspect the planned flow.
- Token presence is still validated so dry-runs surface auth misconfiguration early.
- The adapter exits `0` after simulating a successful publish.

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Pipeline completed successfully or dry-run finished successfully |
| `2` | Missing `NPM_TOKEN` / `NODE_AUTH_TOKEN`, config validation failure, or quality-gate failure (`npm test` / `npm run build`) |
| `3` | `npm publish` failure, `git tag` failure, or history-update failure |

### Success condition

`npm publish` exits `0` and the package is retrievable from the configured registry at the newly-published `version` and `dist_tag`.

### Failure conditions

- **Missing token** — `NPM_TOKEN` (and `NODE_AUTH_TOKEN`) unset → exit `2`
- **Gate failure** — `npm test` or `npm run build` non-zero → exit `2`
- **Publish error** — `npm publish` non-zero (network, 403, version conflict, etc.) → exit `3`

## Output Artefacts

A successful run produces:

- A published package on the configured npm registry (npmjs.com by default), reachable at `https://www.npmjs.com/package/<package_name>/v/<version>`
- A local (and optionally pushed) git tag `v<version>` matching the published `version`
- A history row appended to `project/logs/publish-history.json`

## Post-deploy manual steps

After a successful publish, the deploy flow must print:

✅ Publish complete. Next manual steps:
1. Verify the package on the registry: https://www.npmjs.com/package/<package_name>/v/<version>
2. Push the git tag if not already pushed: `git push origin v<version>`
3. Draft release notes (GitHub Releases or your changelog of choice)

Print the same block in `--non-interactive` mode so CI logs capture it.

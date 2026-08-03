# How the E26 npm Deploy Procedure Works

## 1. What it is
E26 replaced JengaAgent's old device-local `/distribute` + `.jenga_paths` sync with a real **npm publishing pipeline**. The framework (`jenga-agent`) is now published to **npmjs.com** as a public package, and consumer projects pick it up with `npm install jenga-agent`. Publishing is driven end-to-end by the existing `/publish` skill, which learned a new `type: npm` alongside its original `type: mobile-ios`.

## 2. Why it exists
The old approach required the framework repo path to be hard-coded on each developer's laptop (in `.jenga_paths`). That doesn't survive a fresh machine, a CI runner, or a second contributor. npm gives you:
- A single canonical version source (`package.json` `version` — retired `workflow_version`)
- A public, versioned registry anyone can install from
- Standard tooling for dist-tags (`latest`, `beta`) and dry-runs

## 3. How it works

### Publisher side (JengaAgent repo)
The repo root is a real npm package (`package.json:1`):
```json
{
  "name": "jenga-agent",
  "publishConfig": { "access": "public" },
  "files": ["skills/", "agents/", "hooks/", "scripts/", "templates/", "bin/", "README.md", "LICENSE"],
  "scripts": { "postinstall": "node scripts/postinstall.js" }
}
```
- `files` whitelists exactly what ships — `project/`, `node_modules/`, board files stay out.
- `publishConfig.access: public` allows unscoped public publish.
- A `bin/jenga.js` entry gives consumers a CLI.

### Configuration (`publish.json`)
A `type: npm` target block (validated by `skills/publish/schemas/publish.schema.json`) — example at `skills/publish/assets/publish.example.npm.json`:
```json
{
  "name": "npm-public",
  "type": "npm",
  "platform": "npm-registry",
  "secrets": { "NPM_TOKEN": "$NPM_TOKEN" },
  "npm": {
    "package_name": "jenga-agent",
    "access": "public",
    "registry": "https://registry.npmjs.org",
    "dist_tag": "latest"
  }
}
```
The schema uses `if/then/else` conditionals keyed on `type`, so an npm target does **not** require the `ios` block (and vice-versa).

### Command flow
1. **Setup** — `/publish setup --type npm` runs `scripts/setup_wizard.sh` → dispatches to `wizards/npm.md`. Prompts for package name, access, dist-tag, registry, dry-run pref; writes the target into `publish.json`; drops an `_INSTRUCTIONS.md` explaining how to mint an `NPM_TOKEN` at npmjs.com.
2. **Deploy** — `/publish deploy --target npm-registry` runs `scripts/publish_deploy.sh`. Because `type: npm`, it dispatches to `scripts/npm_pipeline.sh` (not `ios_pipeline.sh`).
3. **Pipeline** (`skills/publish/scripts/npm_pipeline.sh`):
   - Runs `validate_npm_env.sh` — fails fast (exit 4) if neither `NPM_TOKEN` nor `NODE_AUTH_TOKEN` is set.
   - `run_gates.sh` executes `npm test` (and `npm run build` if declared).
   - Reads `dist_tag`, `registry`, `access` from `publish.json`; resolves dist-tag with precedence **flag > env > config > `latest`**.
   - Runs `npm publish --tag <dist_tag> [--access <access>] [--registry <url>]` from the repo root.
   - `--dry-run` swaps in `npm publish --dry-run` so nothing hits the registry.
   - Exit codes: `0` success, `2` pre-publish gate failure, `3` publish failure.

### Consumer side
When a consumer runs `npm install jenga-agent`, the **postinstall hook** (`scripts/postinstall.js`) fires:
- Reads `INIT_CWD` (the consumer's project root, not `node_modules/jenga-agent`).
- Compares package version against `<consumer>/.jenga-version` (a small semver comparator, no `semver` dep).
- On **first install or upgrade**, recursively copies `skills/`, `agents/`, `hooks/`, `scripts/`, `templates/` into the consumer root.
- Writes `.jenga-version` so subsequent installs skip when already up-to-date.
- If the hook runs *inside* the JengaAgent repo itself (`INIT_CWD === packageRoot`), it no-ops — avoids trashing dev work.

## 4. When to use it
- **Use `/publish deploy --target npm-registry`** for any real release of `jenga-agent`.
- **Use `--dry-run`** in CI or when validating a new target — no token or registry write needed.
- **Don't reach for `/distribute` or `.jenga_paths`** — they're deleted (S01). `workflow_version` in `jenga.config.json` is deprecated; the truth is `package.json` `version`.
- **Don't add per-consumer file paths** — the postinstall hook figures it out from `INIT_CWD`.

## 5. Example — publishing v1.0.1

Before (old world):
```bash
# on the one machine where .jenga_paths exists
/distribute            # copies files to hard-coded paths
```

After (E26):
```bash
# one-time
/publish setup --type npm            # writes npm target to publish.json
export NPM_TOKEN=npm_xxxxxxxxxxxx    # from npmjs.com automation token

# every release
/publish deploy --target npm-registry --dry-run    # rehearsal
/publish deploy --target npm-registry              # live publish
# → npm publish --tag latest --access public
# → git tag v1.0.1
# → prints post-deploy checklist (verify URL, push tag, draft notes)
```

Consumer, anywhere:
```bash
mkdir my-project && cd my-project
npm install jenga-agent
# postinstall copies skills/, agents/, hooks/, scripts/, templates/ into ./
# writes .jenga-version = 1.0.1
```

Upgrading is the same command — postinstall's semver check overwrites only when the new version is strictly greater.

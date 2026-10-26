# Credential-access audit (E85_S02_T01)

Evidence for the story question "is it intentional that bundled skill scripts touch `gh auth`, `$AWS_*`, `~/`?" (E85_S02). Read this repository only; nothing here reads, comments on or edits the public `jenga-npm` repository.

- **Scanner:** `scripts/scan-credential-patterns.sh` (enumerates, does not judge). Re-run it any time; its row set must equal the rows below.
- **Machine-readable copy:** `project/data/credential-findings.json` carries exactly the same rows as the two tables.
- **Verdicts** were reached by reading the code around every line, not by pattern. **True read** means a script obtains the *value* of a credential or secret (reads a credential file, prints a token, captures `$AWS_*` into a variable, passes a secret to a command). **Benign mention** means documentation, user-run guidance, an exit-code-only probe, or a guard that never reads a value.
- **Reporting rule:** a line matching several classes has one row per class (so `~/.ssh/id_deploy` is one `dotfile-path` row and one `credential-file` row). Rows are ordered by file, line, then class.

## Data shape: `credential-findings.json`

```json
{"schema_version": 1, "scan_date": "YYYY-MM-DD", "command": "...",
 "summary": {"total": 0, "by_skill": {"<skill>": 0, "scripts/": 0}},
 "findings": [{"skill": "<name>" | null, "file": "...", "line": 0,
                "class": "gh-auth|aws-env|dotfile-path|home-ref|credential-file", "text": "...",
                "scope": "flagged" | "other", "verdict": "true read" | "benign mention",
                "reason": "...", "action": "reword" | "allow-list" | "none"}]}
```

`skill` is `null` for matches in `scripts/`; `scope` is `flagged` for `j-connect`, `j-publish` and `j-uncharted`. `action` is `reword` for a line proposed for rewording or relocation (E85_S02_T02 to T04), `allow-list` for a line that stays (E85_S02_T05), and `none` is reserved for a line that needs nothing (unused in this scan, because E85_S02_T05's mention detector scans all of `skills/` and `scripts/`, so every benign line that stays must be on its allow-list). The scanner's own `--format json` shape is `{"schema_version":1,"root":"...","matches":[{"file","line","class","text"}]}`.

## Summary

- **Scan date:** 2026-10-25
- **Command:** `scripts/scan-credential-patterns.sh` run from the repository root (default paths `skills/` and `scripts/`)
- **Total matches:** 39 (flagged skills: 20, every other skill and `scripts/`: 19). The first scan found 48; the 9-row drop is `E85_S02_T03` (see "E85_S02_T03 outcome (`j-publish`)"): 11 `j-publish` rows reworded away, 2 rows added by the new SKILL.md section and the named `gh_is_signed_in` function.
- **True reads among the 39 pattern rows: 0.** Every row is a benign mention. See the "Outside the five patterns" section for reads of environment values that the five patterns do not match.
- **`aws-env`: 0 matches** anywhere in `skills/` or `scripts/` (and none in the `.claude/skills/` or .agents/skills/ mirrors of this checkout). No script in this repository references an `AWS_` variable; the issue's `$AWS_*` claim is not borne out here.
- **Row-count check:** scanner output = 39 rows; Table A (flagged) 20 + Table B (other) 19 = 39 rows; `credential-findings.json` `findings` length = 39. All three agree, with the same file and line set.

Matches per pattern class: `gh-auth` 10, `aws-env` 0, `dotfile-path` 6, `home-ref` 5, `credential-file` 18.

Matches per skill:

| skill | matches | scope |
|---|---|---|
| `j-connect` | 3 | flagged |
| `j-do` | 1 | other |
| `j-gitignore` | 1 | other |
| `j-init` | 2 | other |
| `j-mirror-public` | 1 | other |
| `j-publish` | 15 | flagged |
| `j-skillify` | 3 | other |
| `j-tools` | 3 | other |
| `j-uncharted` | 2 | flagged |
| `jenga-config` | 3 | other |
| `scripts/` | 5 | other |

## Preliminary readings from the story Context

Line numbers in items 2 and 3 are those of the first scan (`E85_S02_T01`); `E85_S02_T03` rewrote or moved several of those lines (see its outcome section).

1. **`skills/j-connect/descriptors/github.json:19` only tells the user to run `gh auth login` themselves. Confirmed.** The line is the `auth.instructions` string. The only `gh auth` commands the skill *runs* are the `auth.check` and `verify` argv arrays at `github.json:21` and `github.json:28`; they are executed by `skills/j-connect/scripts/run-descriptor.sh:138-144` (`run_check`), which discards stdout and stderr (`>/dev/null 2>&1 </dev/null`) and judges by exit status only. Those two lines are not matches, because the scanner patterns need `gh auth` in one run of text and an argv array splits it into separate strings (see "Outside the five patterns").
2. **`skills/j-publish/adapters/*.md` and `validate_npm_ci_env.sh` run `gh auth status` (exit code only, output to `/dev/null`). Partly confirmed, partly corrected.** Confirmed for the script: `skills/j-publish/scripts/validate_npm_ci_env.sh:20` is `gh auth status >/dev/null 2>&1 || fail ...`. Corrected for the adapters: `skills/j-publish/adapters/droplet.md:73`, `npm-ci.md:73` and `npm-ci.md:92` are prose; they run nothing, and `npm-ci.md:92` merely describes the probe in the script. There is no second script that runs `gh auth` in `j-publish`.
3. **`skills/j-publish/wizards/droplet.md` documents `gh secret set DROPLET_SSH_KEY < ~/.ssh/id_deploy` as guidance the user runs. Confirmed, and wider than stated.** `wizards/droplet.md:177` (with the descriptive table row at `:167`) is user-run guidance in a fenced block. The same command also appears at `skills/j-publish/assets/secrets-guide.md:82`, together with `ssh-keygen ... -f ~/.ssh/id_deploy` (`:93`) and `ssh-copy-id -i ~/.ssh/id_deploy.pub` (`:95`). Nothing in a script opens, reads or forwards that key; the key path occurs in no `.sh` file of the skill.
4. **`skills/j-uncharted/scripts/import-source.sh:362` references `"$HOME"` only in a guard that refuses to delete the system root. Confirmed, with one refinement.** Line 362 is one alternative in a `case` pattern list inside `cleanup_on_failure`; the guard compares `$STAGING_ROOT` against `/`, `/tmp`, `/var`, `/usr`, `/etc` and `$HOME` and only then skips `rm -rf`. It reads no file. Refinement: it protects the home directory as well as system roots. The only other `j-uncharted` match is `scripts/detect-dependencies.sh:345`, a Python string literal `"~/"` used to classify a JavaScript import specifier as a project alias; it never expands a home directory.

## Table A: the three flagged skills (`j-connect`, `j-publish`, `j-uncharted`)

20 rows, one per match.

| file | line | pattern class | what the line does | verdict | reason |
|---|---|---|---|---|---|
| `skills/j-connect/descriptors/github.json` | 19 | `gh-auth` | JSON descriptor string that tells the user to run `gh auth login` in their own terminal (docs_url, instructions). | benign mention | User-run guidance rendered as text: the skill runs no login command; the only gh auth command the descriptor runs is the exit-code `check` at lines 21 and 28, which the pattern does not match because it is an argv array. |
| `skills/j-connect/scripts/ensure-secret-safe.sh` | 6 | `credential-file` | Header comment explaining that the guardrail protects a file such as `.env` that could hold a secret. | benign mention | Comment only; the script runs `git check-ignore` and edits .gitignore, and never opens the file it protects. |
| `skills/j-connect/scripts/register-mcp.sh` | 37 | `credential-file` | Header comment stating that `.env` is the kind of file the .gitignore guardrail is applied to. | benign mention | Comment only; the same comment states the script never reads an environment variable's value. |
| `skills/j-publish/SKILL.md` | 162 | `gh-auth` | Section "What this skill touches" (added by E85_S02_T03): prose naming the exit-status-only `gh auth status` probe and stating that the skill never runs the login, token or secret-setting commands. | benign mention | Documentation prose added by E85_S02_T03; nothing runs or reads a value. It names the probe in order to say that its output is discarded. |
| `skills/j-publish/adapters/droplet.md` | 75 | `gh-auth` | Adapter prose, reworded by E85_S02_T03: the user signs in to `gh` themselves (`gh auth login`) before `/publish deploy` against a droplet; the skill never runs it. | benign mention | User prerequisite stated as something the user runs; the command text is kept because the instruction needs it. Nothing is run or read. |
| `skills/j-publish/adapters/npm-ci.md` | 77 | `gh-auth` | Adapter prose, reworded by E85_S02_T03: lists `gh` as signed in by the user, who runs `gh auth login` themselves. | benign mention | User prerequisite stated as something the user runs; the command text is kept because the instruction needs it. Nothing is run or read. |
| `skills/j-publish/assets/secrets-guide.md` | 5 | `credential-file` | Secrets guide: never commit secrets or `.env` files. | benign mention | Protective guidance to the user; nothing is read. |
| `skills/j-publish/assets/secrets-guide.md` | 9 | `credential-file` | Secrets guide: the `.env` line of a .gitignore snippet the user copies. | benign mention | Ignore rule shown as guidance; not a read. |
| `skills/j-publish/assets/secrets-guide.md` | 10 | `credential-file` | Secrets guide: the `.env.*` line of a .gitignore snippet the user copies. | benign mention | Ignore rule shown as guidance; not a read. |
| `skills/j-publish/assets/secrets-guide.md` | 18 | `credential-file` | Secrets guide: advises keeping local-only secrets in a gitignored `.env` file. | benign mention | Guidance to the user about their own shell setup; the skill does not read the file. |
| `skills/j-publish/scripts/validate_npm_ci_env.sh` | 19 | `gh-auth` | Body of the named function `gh_is_signed_in` (E85_S02_T03): `gh auth status >/dev/null 2>&1`, the sign-in probe. | benign mention | Exit-status-only probe: output discarded, only the status decides whether validation continues; no value is captured. The literal `gh auth status` survives any rewrite of this probe, so the line stays on the allow-list. Moving it into a function changed no behaviour (before/after matrix in the T03 summary). |
| `skills/j-publish/scripts/validate_npm_ci_env.sh` | 26 | `gh-auth` | Call site `gh_is_signed_in \|\| fail ...`; the failure message tells the user to run `gh auth login` and re-run. | benign mention | Message text only: it names the command the user should run; the script never runs it. |
| `skills/j-publish/wizards/npm-ci.md` | 25 | `gh-auth` | Wizard prerequisite, reworded by E85_S02_T03: the user runs `gh auth status` themselves to check that they are signed in. | benign mention | Instruction to the user in prose; the wizard text runs nothing and reads nothing. |
| `skills/j-publish/wizards/npm-ci.md` | 26 | `gh-auth` | Wizard prerequisite, reworded by E85_S02_T03: if not signed in, the user runs `gh auth login` themselves; the wizard runs neither command. | benign mention | User-run guidance in prose; the wizard does not run it. |
| `skills/j-publish/wizards/npm.md` | 133 | `credential-file` | Wizard advice to keep the npm token in a git-ignored `.env` file and source it in the shell. | benign mention | Guidance to the user; the skill never reads that file. |
| `skills/j-publish/wizards/npm.md` | 139 | `credential-file` | Wizard prose naming `NODE_AUTH_TOKEN` as an alternative if the user's `.npmrc` uses that name. | benign mention | Names a variable and a file; reads neither. |
| `skills/j-publish/wizards/npm.md` | 140 | `credential-file` | Wizard warning not to commit the token, listing `.env` files and shell rc files. | benign mention | Protective guidance; nothing is read. |
| `skills/j-publish/wizards/npm.md` | 212 | `credential-file` | Wizard note about `NODE_AUTH_TOKEN` in GitHub Packages `.npmrc` setups. | benign mention | Documentation prose; nothing is read. |
| `skills/j-uncharted/scripts/detect-dependencies.sh` | 345 | `home-ref` | Python in the JS import scanner: `spec.startswith((".", "/", "~/", "@/", "#"))` classifies an import specifier as a project-internal alias. | benign mention | String literal used for classifying import specifiers in analysed source; it expands no home directory and reads no file. |
| `skills/j-uncharted/scripts/import-source.sh` | 362 | `home-ref` | `case` pattern list in the failure cleanup trap: `/\|/tmp\|/var\|/usr\|/etc\|"$HOME"` refuses to rm -rf a protected root (preliminary reading confirmed). | benign mention | Pure comparison inside a deletion guard; HOME is compared to the path and the guard never opens a file. E85_S02_T04 retained the line unchanged because no rewrite keeps identical protection (see the note under the allow-list); its behaviour is pinned by `tests/uncharted-import-source-guard.bats`. |

## Table B: every other skill and `scripts/`

19 rows, one per match, classified the same way.

| file | line | pattern class | what the line does | verdict | reason |
|---|---|---|---|---|---|
| `scripts/pages-cutover.sh` | 38 | `gh-auth` | Runs `gh auth status` with stdout and stderr discarded inside an `if !` test. | benign mention | Exit-code-only probe: the output is sent to /dev/null, so no token or account detail is ever captured, printed or passed on. |
| `scripts/pages-cutover.sh` | 39 | `gh-auth` | Error message telling the user to run `gh auth login` themselves. | benign mention | Text inside a printf to stderr; the script runs nothing and the user performs the login. |
| `scripts/resolve-tools.sh` | 21 | `dotfile-path` | Comment documenting the default user-layer registry path `$HOME/.jenga/tools.json`. | benign mention | Comment only; the path is Jenga's own preferred-tools registry, not a credential file. |
| `scripts/resolve-tools.sh` | 113 | `home-ref` | Guards `[ -n "${HOME:-}" ]` before deriving the user-layer registry path. | benign mention | Tests whether HOME is set; reads no file and no secret. |
| `scripts/resolve-tools.sh` | 114 | `dotfile-path` | Sets `USER_FILE="$HOME/.jenga/tools.json"`, the optional user-layer tools registry. | benign mention | Resolves a path to Jenga's own preferred-tools registry, which holds tool names and install hints and never credentials. |
| `skills/j-do/assets/intent-vs-diff-prompt.md` | 38 | `credential-file` | Prompt rule telling a reviewer not to flag `.env.example` and other config files. | benign mention | Prompt prose for a diff reviewer; no file is read and no secret is involved. |
| `skills/j-gitignore/SKILL.md` | 142 | `credential-file` | Skill prose warning that a committed `.env` or credential must be treated as compromised. | benign mention | Documentation of a limitation; the skill never reads those files, it only untracks paths from git. |
| `skills/j-init/assets/.gitignore_template` | 7 | `credential-file` | `.gitignore` template line `.env`. | benign mention | Ignore rule that keeps secrets out of git; a template file, not a read. |
| `skills/j-init/assets/.gitignore_template` | 8 | `credential-file` | `.gitignore` template line `.env.*`. | benign mention | Ignore rule that keeps secrets out of git; a template file, not a read. |
| `skills/j-mirror-public/SKILL.md` | 174 | `credential-file` | Skill prose listing `.env` among the paths the publicignore blocklist excludes from the mirror. | benign mention | Documents what is withheld from the public mirror; nothing is read. |
| `skills/j-skillify/assets/init-new/assets/.gitignore_template` | 7 | `credential-file` | `.gitignore` template line `.env` inside a skillify asset copy of the init template. | benign mention | Template data, not a read. |
| `skills/j-skillify/assets/init-new/assets/.gitignore_template` | 8 | `credential-file` | `.gitignore` template line `.env.*` inside a skillify asset copy of the init template. | benign mention | Template data, not a read. |
| `skills/j-skillify/assets/init-old/SKILL.md` | 18 | `credential-file` | Skill prose listing environment files (`.env`, `.env.*`, `*.local`) in an archived init-old reference copy. | benign mention | Reference documentation of what init ignores; nothing is read. |
| `skills/j-tools/scripts/tools-entry.sh` | 44 | `dotfile-path` | Comment documenting the default user-layer registry path `$HOME/.jenga/tools.json`. | benign mention | Comment only; Jenga's own preferred-tools registry, not a credential file. |
| `skills/j-tools/scripts/tools-entry.sh` | 268 | `home-ref` | Guards `[ -n "${HOME:-}" ]` before deriving the user-layer registry path. | benign mention | Tests whether HOME is set; reads no file and no secret. |
| `skills/j-tools/scripts/tools-entry.sh` | 269 | `dotfile-path` | Sets `f="$HOME/.jenga/tools.json"`, the optional user-layer tools registry. | benign mention | Path to Jenga's own preferred-tools registry (tool names and install hints), not a credential file. |
| `skills/jenga-config/scripts/run-config.sh` | 23 | `dotfile-path` | Comment documenting the cache override default `${XDG_CACHE_HOME:-$HOME/.cache}/jenga-cli`. | benign mention | Comment only; the directory holds Jenga CLI cache data, not credentials. |
| `skills/jenga-config/scripts/run-config.sh` | 35 | `home-ref` | Guards `[ -n "${HOME:-}" ]` before choosing the cache directory. | benign mention | Tests whether HOME is set; reads no file and no secret. |
| `skills/jenga-config/scripts/run-config.sh` | 36 | `dotfile-path` | Sets `CACHE="$HOME/.cache/jenga-cli"`, the Jenga CLI cache directory. | benign mention | Path to a Jenga-owned cache directory, not a credential file. |

## Lines proposed for rewording or relocation (E85_S02_T02 to T04)

These are benign mentions that read as if the skill ran a command, and can be rephrased as an instruction to the user (or use a placeholder instead of a literal key path) with no behaviour change. Each carries `action: reword`.

**E85_S02_T02 (`j-connect`)**

- `skills/j-connect/descriptors/github.json:19` (`gh-auth`)

**E85_S02_T03 (`j-publish`)**: done, see "E85_S02_T03 outcome (`j-publish`)" below. The first scan listed 15 `j-publish` rows here: 11 no longer exist (reworded away) and the other 4 changed text and line and are now allow-list rows; the old line numbers are not repeated.

**E85_S02_T04 (`j-uncharted`)**

- none reworded. `skills/j-uncharted/scripts/import-source.sh:362` was examined for a rewrite and **retained** (allow-list entry, `action: allow-list`); `detect-dependencies.sh:345` needs no change either. Reasoning and tests are in "E85_S02_T04 outcome" below.

Lines in `j-publish` scripts that look rewordable but cannot be (see below) are on the allow-list instead.

## Lines that must stay and go on the allow-list (E85_S02_T05)

These stay exactly as they are. Each carries `action: allow-list`; the reason is in the table row.

**Flagged skills**

- `skills/j-connect/scripts/ensure-secret-safe.sh:6` (`credential-file`)
- `skills/j-connect/scripts/register-mcp.sh:37` (`credential-file`)
- `skills/j-publish/SKILL.md:162` (`gh-auth`)
- `skills/j-publish/adapters/droplet.md:75` (`gh-auth`)
- `skills/j-publish/adapters/npm-ci.md:77` (`gh-auth`)
- `skills/j-publish/assets/secrets-guide.md:5` (`credential-file`)
- `skills/j-publish/assets/secrets-guide.md:9` (`credential-file`)
- `skills/j-publish/assets/secrets-guide.md:10` (`credential-file`)
- `skills/j-publish/assets/secrets-guide.md:18` (`credential-file`)
- `skills/j-publish/scripts/validate_npm_ci_env.sh:19` (`gh-auth`)
- `skills/j-publish/scripts/validate_npm_ci_env.sh:26` (`gh-auth`)
- `skills/j-publish/wizards/npm-ci.md:25` (`gh-auth`)
- `skills/j-publish/wizards/npm-ci.md:26` (`gh-auth`)
- `skills/j-publish/wizards/npm.md:133` (`credential-file`)
- `skills/j-publish/wizards/npm.md:139` (`credential-file`)
- `skills/j-publish/wizards/npm.md:140` (`credential-file`)
- `skills/j-publish/wizards/npm.md:212` (`credential-file`)
- `skills/j-uncharted/scripts/detect-dependencies.sh:345` (`home-ref`)
- `skills/j-uncharted/scripts/import-source.sh:362` (`home-ref`)

**Other skills and `scripts/`**

- `scripts/pages-cutover.sh:38` (`gh-auth`)
- `scripts/pages-cutover.sh:39` (`gh-auth`)
- `scripts/resolve-tools.sh:21` (`dotfile-path`)
- `scripts/resolve-tools.sh:113` (`home-ref`)
- `scripts/resolve-tools.sh:114` (`dotfile-path`)
- `skills/j-do/assets/intent-vs-diff-prompt.md:38` (`credential-file`)
- `skills/j-gitignore/SKILL.md:142` (`credential-file`)
- `skills/j-init/assets/.gitignore_template:7` (`credential-file`)
- `skills/j-init/assets/.gitignore_template:8` (`credential-file`)
- `skills/j-mirror-public/SKILL.md:174` (`credential-file`)
- `skills/j-skillify/assets/init-new/assets/.gitignore_template:7` (`credential-file`)
- `skills/j-skillify/assets/init-new/assets/.gitignore_template:8` (`credential-file`)
- `skills/j-skillify/assets/init-old/SKILL.md:18` (`credential-file`)
- `skills/j-tools/scripts/tools-entry.sh:44` (`dotfile-path`)
- `skills/j-tools/scripts/tools-entry.sh:268` (`home-ref`)
- `skills/j-tools/scripts/tools-entry.sh:269` (`dotfile-path`)
- `skills/jenga-config/scripts/run-config.sh:23` (`dotfile-path`)
- `skills/jenga-config/scripts/run-config.sh:35` (`home-ref`)
- `skills/jenga-config/scripts/run-config.sh:36` (`dotfile-path`)

Two allow-list entries deserve a note because E85_S02_T03 and T04 may try to reword them:

- `skills/j-publish/scripts/validate_npm_ci_env.sh:19` and `:26`: `E85_S02_T03` did move the probe into a named function with a comment saying it uses the exit status only (`gh_is_signed_in`), which was shown to be behaviour-identical (see the T03 outcome). As predicted, that does not remove the `gh auth status` text from the file, so the scanner still matches the probe (`:19`) and the failure message that names `gh auth login` (`:26`). Both stay on the allow-list.
- `skills/j-uncharted/scripts/import-source.sh:362`: the guard needs the home directory in its protected set. Rewriting it through a variable would still contain a `HOME` reference, and rewriting it through `~` or `cd ~ && pwd` changes behaviour when `HOME` is unset or relative. It stays unless T04 can prove identical protection; any surviving `HOME` token stays on this list.

### E85_S02_T04 outcome (`j-uncharted`)

- **`import-source.sh:362` is retained, unchanged, on the allow-list.** The line is one alternative of the `case "$STAGING_ROOT"` pattern list in `cleanup_on_failure`, the script's exit trap. The scanner's home-ref pattern (`PAT_HOME` in `scripts/scan-credential-patterns.sh`) matches `$HOME`, `${HOME}` and `${HOME:-...}`, so resolving the protected path through a named variable still leaves a `$HOME` token somewhere in the file. The only token-free spelling is a bare `~` in the pattern list, and it is not identical: with `HOME` unset, `"$HOME"` aborts the trap under the script's `set -u` ("unbound variable", nothing is removed), while `~` silently resolves to the passwd-database home and the trap carries on to delete other paths. Spelling the home directory through `printenv HOME` or a similar capture would dodge the scanner, would itself look like a credential-environment read to the E85_S02_T05 detector, and would hide a harmless comparison. None of these is provably identical, so the code was left alone rather than weakened or obscured.
- **The guard is pinned by `tests/uncharted-import-source-guard.bats`**, which passes against the unmodified script. It runs the real `cleanup_on_failure` (extracted from the script) with a stubbed `rm` and asserts: `/`, `/tmp`, `/var`, `/usr`, `/etc`, and a temp directory standing in for `HOME` are never passed to `rm -rf`; an empty, absent or exit-0 case deletes nothing; an ordinary directory and a subdirectory of `HOME` are removed (positive controls). Two end-to-end cases run the real script against temp directories only: `--staging-dir` set to the stand-in `HOME` survives a failed import, and an ordinary staging directory is cleaned up. Removing the `HOME` alternative or the `/` alternative makes the matching tests fail.
- **`detect-dependencies.sh:345`** is a Python string literal that classifies a JavaScript import specifier; it never expands a home directory. Unchanged, allow-list.
- **`skills/j-uncharted/SKILL.md` now has a "What this skill touches" section** (reads, what it does not do on its own, what it does not exclude, writes, the `import` temp directory). It is worded to add no scanner row: `scripts/scan-credential-patterns.sh skills/j-uncharted` still reports exactly the two rows above.
- **Finding raised:** `directory-triage.sh` and the other scripts skip directory names only, never secret-looking file names, so a credential file inside an analysed or imported target is not excluded. This was raised as a `security_concern` (recommends a follow-up for a human decision; behaviour unchanged here).
- **Update, 2026-10-26: the gap above is closed.** `j-uncharted` now skips secret-looking files by name (environment files, auth files, private keys and PEM/key files, `id_rsa`-style names) using one shared list, `skills/j-uncharted/scripts/secret-files.sh`. `enumerate-target.sh`, `detect-dependencies.sh`, `detect-tests.sh`, `inspect-provenance.sh` and `import-source.sh` (local directory mode; a single secret-named local file is refused) apply it. A matching file is never opened, counted or copied, and each skip is reported as "N secret-looking files skipped (names listed, contents never read)". Template names such as `.env.example` stay visible. Documented limits: the match is on names only (an oddly named secret file is not caught), a source's own `.git` is still copied into staging and removed afterwards, a `git` clone is not filtered by name, and kubeconfig-style names are not on the list; `skills/j-uncharted/SKILL.md` ("What this skill touches") states them. Tests: `tests/uncharted-secret-files.bats` (the list and its notice), `tests/uncharted-enumerate-secret-skip.bats`, `tests/uncharted-detectors-secret-skip.bats` and `tests/uncharted-import-secret-skip.bats` (each script, including byte-identical output when no file is skipped).
- **Effect on the scanner rows.** Tables A and B above are the snapshot of the first scan. The new skip list and the prose describing it name credential files in order to skip them, so `scripts/scan-credential-patterns.sh skills/j-uncharted` now also reports `credential-file` rows in `secret-files.sh` (lines tagged `[policy]`) and in `SKILL.md`. They are benign mentions (nothing opens a file) and are excused by narrow entries in `tests/fixtures/credential-access-allowlist.txt`; `tests/credential-access-guard.bats` and `tests/scan-credential-patterns.bats` pass.

### E85_S02_T03 outcome (`j-publish`)

- **Presence-only validators (behaviour proven identical).** `validate_npm_env.sh` and `validate_ios_env.sh` no longer assign a credential environment value to a variable or contain any `printenv`; both use one small `env_var_has_value` function that is a bash-only test (identifier check first, then an exported-name check against `compgen -e`, then non-emptiness tests that do not capture the value). A before/after run of the pre-change and changed scripts on the same stubbed environment (29 cases, bash 3.2 and bash 5) gave identical exit codes, stdout and stderr in every case, including set-but-empty, only-newlines, invalid identifier names and names of the script's own non-exported variables. The before/after matrix was recorded in the maintainers' task summary and is not published.
- **`ios_pipeline.sh` is unchanged** (accepted by-design use). The exact description of what it reads and where it goes is in the "Outside the five patterns" row for it, and in `skills/j-publish/SKILL.md`.
- **`SKILL.md` has a "What this skill touches" section** (external commands, who sets credentials, the presence-only validators, the precise `ios_pipeline.sh` flow, the local paths written). It adds one scanner row (`SKILL.md:162`), classified above.
- **Reworded away (rows removed, 11):** the `adapters/npm-ci.md` description of the `gh auth status` probe (now "an exit-status-only probe whose output is discarded", 1 row); the deploy-key path in `wizards/droplet.md` (`:167` and `:177`, two classes each, 4 rows); and the deploy-key path in `assets/secrets-guide.md` (`:82`, `:93`, `:95`, two classes each, 6 rows). The paths are now `<path-to-your-deploy-key>` placeholders. The droplet wizard and the secrets guide still tell the user how to store the deploy key as a repository secret.
- **Reworded but still matching (kept, allow-list):** `adapters/droplet.md:75`, `adapters/npm-ci.md:77`, `wizards/npm-ci.md:25` and `:26` now say the user runs the sign-in command themselves; they must keep the command text because the instruction needs it.
- **Left as it was, allow-list:** `assets/secrets-guide.md:5, 9, 10, 18` and `wizards/npm.md:133, 139, 140, 212` (protective `.env` and token-name guidance, nothing read).
- **`validate_npm_ci_env.sh`:** the probe moved into a named function with a comment, behaviour identical for the authenticated and unauthenticated stub (exit `0` and non-zero), see the allow-list note above.

## Outside the five patterns (not rows, but relevant to the story)

The five patterns are the scanner's, as named in the issue. While reading the code I also searched for constructs that obtain a credential value without matching them (`printenv`, `os.environ`, `process.env`, `getenv`, `*_TOKEN`/`*_SECRET`/`*_KEY` variables, `gh api|token|secret`, keychain readers). Most hits are unrelated (parsing tokens, `process.env.INIT_CWD`). Four need to be on record, because they are the code a scanner would read as "reads credentials or secrets", and because E85_S02_T03's wording and E85_S02_T05's read detector must not contradict them:

| file | line | what it does | verdict | reason |
|---|---|---|---|---|
| `skills/j-publish/scripts/validate_npm_env.sh` | 15, 16 | `NPM_TOKEN_VALUE="$(printenv NPM_TOKEN ...)"` and the same for `NODE_AUTH_TOKEN`: captures the token value into a shell variable, then only tests `-z`. | fixed (presence-only check), see `E85_S02_T03` | Was a presence check written as a value capture (never printed, logged, written or passed on). Now `env_var_has_value NPM_TOKEN` / `NODE_AUTH_TOKEN`: a bash-only test that does not assign the value to a variable, with the same exit code (`4`), messages and set-but-empty handling (before/after matrix in the T03 summary). |
| `skills/j-publish/scripts/validate_ios_env.sh` | 57 | `value="$(printenv "$var_name" ...)"` for each env var the iOS target references (App Store Connect key id, issuer id, key path, signing identity); tests `-z`. | fixed (presence-only check), see `E85_S02_T03` | Was the same shape (value captured only to test emptiness, then discarded). Now the same `env_var_has_value` presence test, with an identifier check before any indirect expansion so a non-identifier name counts as missing instead of aborting; set-but-empty still counts as missing; the missing names (not values) are reported, exit code `4` unchanged (before/after matrix in the T03 summary). |
| `skills/j-publish/scripts/ios_pipeline.sh` | 154-158, 300-304, 409-411 | `resolve_env_value_from_ref` reads the value of each referenced env var into `API_KEY_ID`, `ISSUER_ID`, `PRIVATE_KEY_PATH` and signing variables, then passes them as arguments to `xcrun notarytool` / `altool`. | accepted by-design use (user decision 2026-10-25) | The iOS upload step must hand credential-related values to Apple's tools, so the script reads them from the user's own environment (variable names from the `secrets` block of `publish.json`, which holds references). Exactly where they go, verified against the code: the App Store Connect key id, issuer id and private-key file **path** become arguments of `xcrun notarytool submit` (or `xcrun altool`); the command line is rendered with `printf %q` for display, so those three values are echoed to the terminal in `--dry-run` output (`[DRY RUN] ...`) and in the failure block of a failed upload (`Command:`) (the key path is also named in the "does not exist" validation error, `:472`), and are not written to the publish history or any file by the script. The signing identity and provisioning-profile UUID are substituted by `sed` (so they are on that `sed` command line for an instant) into `ExportOptions.plist` under the scratch directory `.claude/publish-tmp/<run-id>/` (`:311-321`, `:441-442`), which is the only file they are written to and is removed by an `EXIT` trap; `xcodebuild -exportArchive` receives only the plist path. The private key file's contents are never read by the script (it tests that the path exists, `:471`); Apple's tool opens the file. This is the row `E85_S02_T05`'s allow-list entry for `ios_pipeline.sh` is derived from. |
| `skills/j-connect/scripts/run-descriptor.sh` | 138-144 | `run_check` executes the descriptor's argv (`gh auth status`, `gh --version`, ...) with all output discarded. | benign mention | Exit-code-only probe; no value is captured. Invisible to the scanner because `github.json:21,28` are argv arrays. |

These are not rows of Tables A and B, because the five pattern classes do not match them, so the "one row per match" and `credential-findings.json` row sets stay equal to the scanner's output. Because the three `printenv`/`xcrun` sites were reads of credential values under this audit's own definition, a `security_concern` rapport was written (kept in the maintainers' private problem log). The user decided on 2026-10-25 ("Presence tests + document the iOS use"), and `E85_S02_T03` carried it out. Consequences for the rest of the story:

- `skills/j-publish/SKILL.md`'s "What this skill touches" section does **not** claim that `j-publish` never reads the value of a token, key or secret. It states that the three validators perform presence checks only, and states exactly what `ios_pipeline.sh` reads and where it goes.
- `E85_S02_T05`'s read detector ("`printenv` of ... `*_TOKEN` or `*_KEY` variable, or assigning such a variable's value to another variable") no longer fires on `validate_npm_env.sh` or `validate_ios_env.sh`. It still fires on `ios_pipeline.sh:154-158` (`resolve_env_value_from_ref`), the accepted by-design use, which is the one allow-list entry T05 needs for it.

## Scanner coverage notes

- The scanner skips its own source (`scripts/scan-credential-patterns.sh`), `.git/`, `node_modules/` and binary files.
- The `.claude/skills/` and `.agents/skills/` trees are generated mirrors; the audit is of the canonical `skills/` and `scripts/`. E85_S02_T07 re-runs the scanner against `.claude/skills/` after `j.self-sync`.
- `.env` is matched only as a whole path component start (not `process.env`), and `id_rsa` / `id_deploy` only when not the tail of a longer word (an earlier draft matched `valid_deployment`; fixed before this scan).

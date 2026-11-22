# E100_S01_T02 findings: how Claude Code merges `env` across settings scopes

Tested on **Claude Code 2.1.236**, macOS (Darwin), 2026-11-19. Question: when `env` is defined in more than one settings
layer, is it merged per key, or does the higher layer's object replace the lower one? This decides whether `E100_S03`
may write `env` additively.

## Method (reproducible from this file alone)

Script: `project/documentation/e100-env-merge-repro.sh` (needs `claude`, `jq`, `shasum`). Run it from anywhere:

```bash
bash project/documentation/e100-env-merge-repro.sh [extra settings files to checksum...]
```

Isolation (faithful, no real settings read or written):

- **User scope**: a temporary directory used as `CLAUDE_CONFIG_DIR`, holding its own `settings.json`. The real `~/.claude` is never read.
- **Project scope**: a temporary working directory with `.claude/settings.json` and `.claude/settings.local.json`.
- Not isolated or not tested: managed (enterprise) settings, the `--settings` flag layer, and CLI/session env. Only user < project < project-local was tested.

Observation: the user-scope fixture registers a `SessionStart` hook, `env | grep -E '^(ONLY_|BOTH_)' | sort > "$OUT"`.
A hook subprocess inherits the session environment built from the merged settings `env`, so its dump is the effective
value. The hook fires before authentication, so `claude -p "hi"` is enough; it then prints `Not logged in`, which is
expected and ignored. No login and no model call are involved.

Probe variables: `ONLY_USER`, `ONLY_PROJ`, `ONLY_LOCAL` (one layer each), `BOTH_DIFF` (several layers, different values),
`BOTH_SAME` (several layers, equal value).

Fixtures:

| Case | user `settings.json` env | project `settings.json` env | project `settings.local.json` env |
|---|---|---|---|
| A | `ONLY_USER=u BOTH_DIFF=user BOTH_SAME=same` | `ONLY_PROJ=p BOTH_DIFF=proj BOTH_SAME=same` | `ONLY_LOCAL=l BOTH_DIFF=local` |
| B | as A | as A | file absent |
| C | as A | file absent | file absent |
| D | as A | file exists, no `env` key (`{"permissions":{"allow":[]}}`) | file absent |
| E | as A | `{}` (empty object) | file absent |

## Observed results (output of the one real run, from the script)

| Case | Effective env seen by the hook | Reading |
|---|---|---|
| A | `BOTH_DIFF=local BOTH_SAME=same ONLY_LOCAL=l ONLY_PROJ=p ONLY_USER=u` | all three layers contribute; most specific wins |
| B | `BOTH_DIFF=proj BOTH_SAME=same ONLY_PROJ=p ONLY_USER=u` | project beats user |
| C | `BOTH_DIFF=user BOTH_SAME=same ONLY_USER=u` | lower layer alone is used |
| D | `BOTH_DIFF=user BOTH_SAME=same ONLY_USER=u` | higher file without `env`: lower `env` survives |
| E | `BOTH_DIFF=user BOTH_SAME=same ONLY_USER=u` | higher empty `env` object: lower `env` survives |

Per required case:

| Required case | Result |
|---|---|
| Only in lower layer (`ONLY_USER`) | present (A, B, C, D, E) |
| Only in higher layer (`ONLY_PROJ`, `ONLY_LOCAL`) | present (A, B) |
| Both layers, different values | higher layer wins: local over project over user (`BOTH_DIFF`) |
| Both layers, equal values | present with that value (`BOTH_SAME`) |
| `env` absent in the higher layer | lower `env` survives, object not replaced (C, D; E for an empty object) |

## Verdict

**Per-key merge, higher scope wins** (user < project < project-local). The `env` object is not replaced wholesale, and an
absent or empty higher `env` does not erase lower keys.

**Safe for Jenga writing `env` additively**, with these implied rules:

1. Writing a key into a scope only adds or overrides that key; it cannot remove keys defined in other scopes.
2. A key Jenga writes at user or project scope can be silently overridden by a more specific scope (`settings.local.json`), so Jenga must not assume its value is the effective one.
3. Jenga cannot unset a lower-layer key by writing a higher layer; removal means editing the layer that defines it.

Limits of this evidence: managed settings precedence and the `--settings` flag were not tested; one Claude Code version.

## Consequence for E100_S03

`env` **stays in scope** for `E100_S03`, provided it writes per key (never replacing the whole `env` object in a file that
already has one) and treats the effective value as possibly overridden by a more specific scope. Re-run the script after a
Claude Code upgrade.

## Proof the real settings were untouched

The script checksums the files below before and after the run and printed `UNCHANGED`:

```
20f2988114849720b2093b2c579957207cd83e0f0eb641477fed27d0ed9a6f2a  ~/.claude/settings.json
absent                                                           ~/.claude/settings.local.json
99262a137a1911b6f9928dff754848c97563449be181f0181d8e338bb97dea95  <repo>/.claude/settings.json
b514790b4cbffa27c77198a2c7b350170d5a387da59743fa5c04c328e423403f  <repo>/.claude/settings.local.json
99262a137a1911b6f9928dff754848c97563449be181f0181d8e338bb97dea95  <repo>/settings.json
```

No client project's settings were involved; the test never touched any path outside the temporary directory.

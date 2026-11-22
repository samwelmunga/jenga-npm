# E100_S03 general settings merge: design note

Task `E100_S03_T01`. Fixes the decisions that tasks `E100_S03_T03` to `E100_S03_T06` share, before any code. "The contract" is
[`client-settings-requirements.md`](client-settings-requirements.md) ("section N" is a section of it); the fragment format is the
"Settings fragments" section of [`skill-authoring.md`](skill-authoring.md). The script this replaces is
`scripts/merge-consumer-hooks.sh` (`E89_S06_T20`), called from `lib/sync.js` step 6.

## 1. Name and CLI

```
scripts/merge-settings.sh --consumer-root <dir> [--package-root <dir>] [--dry-run] [--interactive]
```

- Written for a **consumer layout**: when `--package-root` is absent the package root comes from
  `skills/index/scripts/package-root.sh` (`jenga_package_root`), not from `$(dirname "$0")/..`, which is wrong in a consumer.
- `--consumer-root` must be an existing directory; `--package-root` defaults as above; `--dry-run` writes nothing.
- **Allow opt-in flag: `--interactive`.** It lets the script ask, on a terminal, whether to write the `permissions.allow`
  rules, after printing the exact diff (section 4 rule 1). Its default is off, and the answer to the prompt defaults to **no**
  (silence, an unrecognised answer and a closed input are no, section 4 rule 3). Without `--interactive`, or without a
  terminal on stdin, no allow rule is written and each pending rule is reported inactive (rule 4).
- **No `--yes-allow` flag exists.** Section 4 rule 2 says a yes is never "taken from a config flag or environment variable",
  and a flag that answers the prompt in advance is exactly that. The opt-in is a flag that permits asking, never one that answers.
- Unknown argument or missing/invalid `--consumer-root`: exit 2.

## 2. Exit codes

| Code | Meaning | Old code? |
|---|---|---|
| 0 | ok, nothing to do, or skipped (consumer root is the package root) | same |
| 2 | usage error | same |
| 3 | source unusable: `jq` missing, no readable fragment, or a fragment that fails validation | same meaning (was "source unreadable") |
| 4 | an existing settings file is not a JSON object; left untouched | same |
| 5 | write failed (settings file or manifest) | same |
| **6** | **completed, with conflicts or inactive allow rules**: everything that could be added was added | **new** |

6 differs from every old code (0, 2, 3, 4, 5). When both a failure and conflicts occur, the failure code wins (a caller must
never read "applied but not everything" when the run failed). Code 6 is used for any of: a scalar-style conflict (`env` key
with another value, section 3), an allow rule left inactive (no yes, no terminal, declined), or a worktree-event collision
(section 4 below).

## 3. Behaviour map of `merge-consumer-hooks.sh`

| Old behaviour | Kept by `merge-settings.sh` |
|---|---|
| additive only | yes; never changes, reorders or removes an entry it did not write (section 3) |
| user hooks, other keys and key order untouched | yes; entries are appended to the existing arrays, and `jq` rewrites only the touched paths |
| second run byte-identical, prints `unchanged` | yes; a file is rewritten only when at least one entry was added, and the manifest likewise |
| `--dry-run` prints `would add <Event>`, writes nothing | yes, for hooks; adds `would add env <KEY>` and `would add allow <rule>`; no settings file or manifest is written |
| missing `.claude/` created | yes; `.agents/` is created the same way |
| invalid JSON exit 4, file untouched | yes, checked per settings file before any write |
| skips when consumer root is the package root | yes; `skipped: consumer root is the package itself`, exit 0 |
| stdout `added <Event>`, `would add <Event>`, `unchanged`, `skipped: <reason>` | yes, unchanged for hook events, because `lib/sync.js` parses them with `^(?:would add\|added) (\S+)$` |
| source is `<package-root>/settings.json` or `level-2-guarded.json` | **replaced**: the source is every shipped fragment (`skills/j-*/settings-fragment.json`, `hooks/*.fragment.json`) |
| `.claude/settings.json` only | **extended**: also `.agents/settings.json` (section 1) |
| hooks only | **extended**: `permissions.allow` (opt-in) and `env` (per key) |

New stdout lines for the new key classes use shapes the `lib/sync.js` regex does not match, so existing parsing keeps working:
`added env <KEY>`, `added allow <rule>`, `would add env <KEY>`, `would add allow <rule>`, `conflict <path>`,
`inactive allow <rule>`. Conflict text with both values goes to stderr, one per line (section 3 item 1).

## 4. The one deliberate difference: how "already registered" is decided

Old: per event, a command **substring** (`on_recording_step.sh`, `on_preflight_check.sh`, `on_session_end.sh`), "any entry at all"
for `WorktreeCreate` and `WorktreeRemove`, and "all commands already present" for other events.
New: **JSON-normalised equality** of the entry with a declared fragment entry (section 2). Nothing else counts.

Consequence for a consumer who has an **older or edited** Jenga entry (for example the same script at another path, or an added
`timeout`): it no longer matches, so it is the client's. Jenga **adds its own entry next to it**; both run, identical handlers run
once (section 2, [F1]). The old substring rule would have left such a consumer unchanged. Accepted because it is what the contract
requires and because it removes the old rule's blind spot (a stale entry blocking the current one forever).

**Worktree events need a rule.** `WorktreeCreate` and `WorktreeRemove` hooks *replace* Claude's default worktree handling, so
a consumer's own one plus Jenga's would create a worktree twice. Decision: keep the old protection as the only per-event
exception. If either event holds **any** entry not equal to the declared one, Jenga does **not** add its entry; it reports
`conflict hooks.<Event>` (stderr names the file and event) and the run exits 6. The exception is hard-coded in the script (the
fragment format has no key for it and must not gain one). Its effect differs from the old script in one respect: the skip is now
loud instead of silent, since the requirement is genuinely inactive. The contract (section 2, "add next to") should get a note
naming this exception; that is a documentation follow-up for `E100_S03`.

## 5. Files written and the sync summary

| File | Written |
|---|---|
| `.claude/settings.json` | yes, only when something is added |
| `.agents/settings.json` | yes, same rules |
| `.claude/jenga-settings-manifest.json` | one manifest beside each settings file (section 6), only after the settings write succeeded and was re-read |
| `.agents/jenga-settings-manifest.json` | same |

Never `.claude/settings.local.json`, and never user or managed settings (section 1).

Sync-summary line for `lib/sync.js` (section 3 item 3): `settings: <n> conflict(s), <m> allow rule(s) inactive` printed when
either is non-zero, in place of an ok mark; with both zero the line stays the existing ok form. A zero-conflict run prints no extra line.

## 6. `env` and untested layers

`env` **is in scope** (section 5; `E100_S01` verified per-key merge by test on Claude Code 2.1.236, macOS). The script writes per
key and never replaces an `env` object. A different value already in the file is a conflict (client wins, exit 6). A value in
`settings.local.json` is not read, so the result is "written", not "effective".

**Untested layers:** managed settings, the `--settings` flag and CLI/session `env`; and only one Claude Code version. Also
unverified: that any non-Claude tool reads `.agents/settings.json` at all. The script and its output must not claim effectiveness
against those, and `e100-env-merge-repro.sh` is to be re-run after a Claude Code upgrade.

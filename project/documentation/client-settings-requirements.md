# Client settings requirements: contract

Epic `E100`. The contract that governs how Jenga writes into a client project's Claude Code settings. Part one (sections
1 to 5) is `E100_S01_T04`; part two (sections 6 to 9: manifest, removal, plugin delivery, criteria map) is `E100_S01_T05`.

Evidence labels: **[F1]** to **[F6]** are the six rows of [`e100-findings-docs.md`](e100-findings-docs.md);
**[ENV]** is [`e100-findings-env-merge.md`](e100-findings-env-merge.md); **[PLUG]** is
[`e100-spike-plugin-delivery.md`](e100-spike-plugin-delivery.md). Every factual claim carries one. Anything marked
*policy* is a decision made by this contract, not a fact about Claude Code.

Verdict caveats carried over, not softened:

- [F2] is confirmed only for the `--settings` flag. That Claude Code has no `include`/`extends` key is a **negative claim
  that is still not disproven**. The design below does not depend on it: it writes the settings files directly.
- [F4] (docs) said per-variable `env` merge was undocumented. [ENV] settled it **by test** on Claude Code 2.1.236, but only
  for the layers user < project < project-local. Managed settings, the `--settings` flag layer and CLI/session `env` were
  **not tested**.
- [F3] is "confirmed as undocumented in the pages read"; 358580 characters of the settings reference were not read.

## 1. Ownership boundary

### Keys Jenga may write

| Key | Condition | Basis |
|---|---|---|
| `hooks` | always, additive | arrays of hook entries merge across scopes and all matching hooks run [F1] |
| `permissions.allow` | **only after the opt-in rule in section 4** | list keys merge across scopes [F1] |
| `env` | per key only (section 5) | per-key merge, higher scope wins [ENV] |

### Keys Jenga never writes

`defaultMode` and every other scalar, `permissions.deny`, `permissions.ask`, and model choice (`model`, `fallbackModel`,
`modelPicker`, `availableModels`, `modelSettings`). *Policy:* these are client or permission-level policy. `deny` and
`ask` take effect immediately [F1], so writing them would change a client's safety posture without being asked.

Keys Jenga does not name here (for example `enabledPlugins`) are also not written by this contract. [PLUG] shows an
`enabledPlugins` write is technically possible through the CLI, and recommends it stay a later, non-main track.

### Files Jenga writes

| File | Written | Reason |
|---|---|---|
| `.claude/settings.json` | yes | the project scope Claude Code reads |
| `.agents/settings.json` | yes | the project's non-Claude mirror (*policy*, same keys, same rules) |
| `.claude/settings.local.json` | **never** | personal, git-excluded and not read by cloud sessions [F6]; it is the highest project scope, so it would silently override the client's own choices [ENV]. The findings give no reason to write it, so the default stands. |
| user (`~/.claude/`) and managed settings | **never** | outside the project; not tested in [ENV] |

## 2. Identifying a Jenga-owned entry

*Policy.* An entry is Jenga's own **only if it is byte-for-byte equal, after JSON normalisation, to an entry declared in a
Jenga settings fragment shipped with the installed package**. The check needs the entry and the declared fragments only,
no knowledge of what was previously written, so a script can run it from the entry alone.

| Key | Normalised form compared | Match means |
|---|---|---|
| `hooks.<Event>[]` | the entry object (`matcher` plus its `hooks` array, keys sorted, whitespace ignored) | equal to a declared entry under the same `<Event>` |
| `permissions.allow[]` | the rule string | equal to a declared rule string |
| `env.<KEY>` | the key and its string value | key and value both equal a declared pair |

Everything else is the client's, and Jenga never touches it. This explicitly includes:

- an entry that **looks similar** (same script name at a different path, a rule that differs by one character, an `env`
  key Jenga also declares but with another value). It is treated as the client's own, is never edited, never removed, and is
  not replaced by Jenga's version. For `env` and `allow` that is a conflict (section 3); for `hooks` Jenga adds its own
  entry next to the client's, which is permitted because all matching hooks run [F1] and identical handlers run once [F1].
- an entry that **was once Jenga's but the client has since edited**. It no longer matches, so it is the client's.

The recorded list of what Jenga actually wrote (the manifest) is what lets an update remove an entry whose declaration has
changed or been dropped; its format belongs to `E100_S01_T05`. Identification in this section does not replace it: removal
requires *both* that the entry is in the manifest *and* that it still matches the declaration or its recorded form
(*policy*), so a client edit protects an entry from removal.

## 3. Conflict rule

The merge is **additive and never overwrites**. Jenga adds an entry that is absent; it never changes, reorders or removes
an entry it did not write. On a scalar conflict the **client wins** (*policy*) and the conflict is reported loudly.

"Loudly" means all three, together:

1. **stderr text** naming the file, the key path, the client's value and the value Jenga declared, one conflict per line.
2. **A distinct non-zero exit code** for "completed, with conflicts" (not the code used for failure), so a caller can tell
   "applied, but not everything" from both "all applied" and "failed". The number is fixed in `E100_S03`; it must differ
   from every existing exit code of the script it replaces.
3. **A line in the sync summary** stating the count and that the requirement is inactive (not "ok").

A conflict never aborts the other keys: everything that can be added still is.

### Worked examples, one per key class

**`hooks`.** The client's `UserPromptSubmit` already holds its own hook. Jenga's declared recorder hook is absent, so it is
added as a second entry; the client's entry is untouched and both run [F1]. No conflict. If the client already holds an
entry equal to Jenga's, nothing is added (identical handlers run once [F1]).

**`allow`.** Jenga declares `Bash(jq:*)`. The client's `permissions.allow` already contains `Bash(jq:*)`: no write, no
conflict, but the requirement counts as active. The client's `allow` lacks it: it is **not written** until the opt-in rule
(section 4) is satisfied; until then it is reported as inactive. A client `deny` that matches the same command still wins in
Claude Code, and Jenga does not look at or edit `deny`.

**`env`.** Jenga declares `JENGA_X=1`. (a) The client's `.claude/settings.json` has no `JENGA_X`: Jenga adds that one key
and leaves the rest of the `env` object alone. (b) The client's `.claude/settings.json` has `JENGA_X=2`: **conflict, client
wins**, Jenga writes nothing and reports it. (c) The client's `.claude/settings.local.json` has `JENGA_X=2`: Jenga does not
read or write that file, and the local value silently overrides the project value [ENV]. Jenga therefore treats its written
value as *possibly overridden* and can only say the requirement is "written", not "effective".

## 4. Opt-in rule for `permissions.allow`

Widening a client's permissions is a security matter, so `permissions.allow` is the only key class that needs a yes. Rules
(all *policy*):

1. **Diff first.** Before any write, Jenga shows the exact entries it would add, as a diff against the file named in
   section 1, one rule per line. Nothing is summarised or abbreviated.
2. **Explicit yes required.** A write happens only after the user answers yes to that diff in the same run. A yes is the
   user's own reply to this prompt; it is never assumed, inferred, remembered from an earlier run, taken from a config flag
   or environment variable, or carried over to entries that were not in the diff shown.
3. **No yes, no write.** Silence, "no", an unrecognised answer and a closed input all mean no.
4. **Non-interactive runs** (`postinstall` without a terminal, CI, any run that cannot ask) **write nothing** and report each
   pending rule as **inactive**, in the sync summary, naming the command that asks interactively.
5. **Removal is the same.** Removing an allow rule Jenga added earlier (because it left the declaration, or on uninstall)
   also shows the exact entries and needs an explicit yes; non-interactively nothing is removed and the rules are reported
   as still present. Only a rule that passes the identification check (section 2) can be offered for removal.
6. A declined diff is not repeated within the same run, and a decline never blocks the `hooks` and `env` writes, which have
   no opt-in.

## 5. Decision for `E100_S03`: `env`

**`env` stays in scope for `E100_S03`**, decided from [ENV] (Claude Code 2.1.236, macOS, 2026-11-19):

- `env` **merges per key** across user < project < project-local; the most specific layer wins for a key defined in several.
  A higher layer with no `env`, or an empty `env`, does not erase lower keys.
- Therefore `E100_S03` **writes per key and never replaces a whole `env` object** in a file that already has one.
- Writing a key only adds or overrides that key in that file; it cannot unset a key defined in another layer. Removal means
  editing the layer that defines the key, and Jenga only does so for a key it wrote (section 2).
- A key written at project scope can be overridden by `settings.local.json` [ENV], which Jenga does not write
  (section 1). The result is "written", not guaranteed "effective" (section 3, example `env` (c)).

**Untested layers, stated plainly:** managed settings, the `--settings` flag and CLI/session `env` were not tested, and only
one Claude Code version was. `E100_S03` must not claim effectiveness against those layers, and the check in [ENV]
(`project/documentation/e100-env-merge-repro.sh`) is to be re-run after a Claude Code upgrade.

## 6. Manifest

*Policy.* The manifest is the record of what Jenga actually wrote, so an update can also remove entries (including ones whose
declaration has since changed or been dropped).

- **Name and location:** `jenga-settings-manifest.json`, **next to each settings file Jenga writes**: `.claude/jenga-settings-manifest.json`
  for `.claude/settings.json` and `.agents/jenga-settings-manifest.json` for `.agents/settings.json` (section 1). One manifest
  per settings file, because the two files can drift. It is committed with the settings file, so a teammate's update sees the same record.
- **Fields per entry:** `keyClass` (`hooks`, `allow` or `env`); `path` (`hooks.<Event>`, `permissions.allow` or `env.<KEY>`);
  `entry` (the exact normalised entry as written: the hook object, the rule string, or the `{key, value}` pair; its sha256 is
  recorded as `id` so the entry has a stable id); `fragment` (id of the fragment that declared it); `jengaVersion` (the
  installed package version that wrote it).
- **When written:** only **after** the settings file write succeeded and was re-read and parsed. A failed or partial settings
  write leaves the manifest as it was. An entry that was reported as a conflict, declined (`allow` without a yes) or skipped is
  **not** recorded, because Jenga did not write it.

```json
{
  "manifestVersion": 1,
  "file": ".claude/settings.json",
  "entries": [
    {"keyClass": "hooks", "path": "hooks.UserPromptSubmit", "id": "sha256:3f1c...a9",
     "fragment": "workflow-recorder", "jengaVersion": "1.42.0",
     "entry": {"hooks": [{"command": "bash .claude/hooks/on_prompt.sh", "type": "command"}], "matcher": ""}},
    {"keyClass": "allow", "path": "permissions.allow", "id": "sha256:77d0...2e",
     "fragment": "jq-tools", "jengaVersion": "1.42.0", "entry": "Bash(jq:*)"},
    {"keyClass": "env", "path": "env.JENGA_X", "id": "sha256:b5aa...10",
     "fragment": "jenga-core", "jengaVersion": "1.42.0", "entry": {"key": "JENGA_X", "value": "1"}}
  ]
}
```

(`id` values and the version are illustrative.) The manifest contains no secrets; an `env` value is recorded because it is
what Jenga wrote, so `env` fragments must not declare secrets (this is for `E100_S02` to enforce).

## 7. Removal semantics

An update (a newer package) or an uninstall computes `to-remove` as the manifest entries that are no longer declared. For each:

1. **Remove it only if both hold:** it is in the manifest, **and** the entry currently in the settings file is equal, after
   JSON normalisation, to the `entry` recorded in the manifest. At write time the recorded entry was equal to a declared
   fragment entry (section 2), so this is the same identification rule applied to the recorded form; it is what part one
   section 2 calls "its recorded form".
2. **A client edit protects it.** If the client edited the entry (it no longer equals the recorded form) or deleted it by hand,
   Jenga **leaves it alone** and reports it: edited as "kept, client-modified", deleted as "already absent". Either way the
   manifest record is dropped, as it no longer describes anything Jenga owns.
3. **`allow` removal still needs an explicit yes** with the exact diff (section 4, rule 5); non-interactively it is not removed
   and is reported as still present.
4. **Missing manifest:** nothing is removed; Jenga reports "no manifest, nothing removed". It may still add (section 3).
   **Corrupt manifest** (unparseable, wrong `manifestVersion`, or `file` not matching its settings file): same, nothing removed,
   reported, and the manifest is **not overwritten** until the user has seen the report, so evidence is kept (the file is
   renamed `.corrupt` only on an explicit yes).
5. A declared entry that is already present in the settings file but was never in the manifest (client had it first) is not
   recorded and therefore never removed.

### Round trip

Declared fragment v1 holds `Bash(jq:*)` (allow, yes given) and hook H1. The client's file also has its own hook C1.

- **Add:** Jenga writes H1 and `Bash(jq:*)`; manifest records both. C1 is untouched and unrecorded.
- **Update:** fragment v2 replaces H1 with H2 (a changed path) and keeps the rule. H1 is in the manifest and still equals its
  recorded form, so it is removed and H2 added and recorded. C1 is not in the manifest, so it stays. Had the client edited H1
  meanwhile, H1 would stay, be reported, and H2 would still be added.
- **Remove:** v3 drops the rule. It is in the manifest and still equals its recorded form, so after the section 4 diff and a
  yes it is removed and its record dropped. Without a yes (or non-interactively) it stays and is reported.

## 8. Plugin delivery: summary and recommendation

From [PLUG] (spike `E100_S01_T03`, 2 hour time box, about 25 minutes used, Claude Code 2.1.236):

- An `enabledPlugins` entry **can be added and removed additively through the CLI** (confirmed by test): install added one entry
  beside the client's, disable set it `false`, uninstall removed exactly that entry. The CLI re-serialises the file, so it is not
  byte-stable; a marketplace must be declared first.
- A plugin-carried hook can be **disabled silently**: a `false` entry or a managed `allowManagedHooksOnly` removes it with no
  error. `allowManagedHooksOnly` was not run (needs a managed file); a disabled plugin's hooks stopping in a live session is
  docs-inferred only.
- **Copilot and Codex:** no documented effect of a Claude `enabledPlugins` entry; each needs its own plugin install, so the
  route adds a third surface rather than removing work.
- Not verified: hand-edited `enabledPlugins` without install, a scriptable `/hooks` equivalent, Copilot reading `enabledPlugins`.

**Recommendation:** continue as a **later, non-main track**; no separate epic now, not dropped. **Do not let a plugin carry the
preflight backstop** (`hooks/on_preflight_check.sh`, `E89_S06`); it stays in the settings files, where the six-file invariant
holds. If revisited, scope it to non-enforcement hooks behind a doctor check on `claude plugin list --json`. This does not alter
`E100_S02` to `E100_S06`.

## 9. Where each `E100_S01` acceptance criterion is met

| # | Story criterion | Satisfied by | Status |
|---|---|---|---|
| AC1 | Writable and never-written keys; own-entry identification; conflict rule; manifest format | sections 1, 2, 3 and 6 to 7 | Met, except the **exit-code number** for "completed with conflicts", which section 3 requires to be distinct but leaves to `E100_S03`. Partly met on that detail by design. |
| AC2 | Opt-in rule for `permissions.allow` (diff, explicit yes, nothing assumed) | section 4 | Met |
| AC3 | `env` merge determined by an actual test, method and result recorded; `env` out of `E100_S03` if unsafe | [ENV] (method, results, verdict) and section 5 | Met for user, project and project-local on one Claude Code version; managed, `--settings` and CLI/session layers untested (stated in section 5) |
| AC4 | Epic's documentation findings each confirmed, refuted or unknown, with evidence | [F1] to [F6], `e100-findings-docs.md` | Met; [F2] (no include key) and [F3] (settings-reference not fully read) stay partly unknown and are labelled so |
| AC5 | Time-boxed plugin spike, three questions, recommendation | [PLUG], section 8 | Met; sub-points not verified are listed in section 8 and in [PLUG] |
| DoD1 | Document under `project/documentation/` linked from `E100` | this file; link in the `E100` epic `docs:` frontmatter | Met |
| DoD2 | A tester can check each criterion from the document | this table | Met |
| DoD3 | `env` test reproducible from the recorded method | [ENV] Method and `e100-env-merge-repro.sh` | Met |
| DoD4 | No settings file written, except throw-away fixtures | [ENV] "Proof the real settings were untouched", [PLUG] "Test method and safety" | Met for the repository settings files; checksums of `~/.claude/settings.json` and `~/.claude.json` were not taken in the spike ([PLUG]) |

## Not in this document

The fragment format is `E100_S02`; the merge script, its exit codes (including the value for "completed with conflicts") and
the manifest writer are `E100_S03`.

# Path-reference triage for the public mirror (E28_S21_T02)

A spike. It inventories every **path-form** reference to a `.publicignore`-blocked skill in the computed ship set,
classifies each file, restates the counts against the 2026-10-22 baseline, and says what `E28_S21_T03`, `T04` and
`T05` should do about it. Nothing here changes source code.

**Written so it adds nothing to the number it reports.** This file ships, so it names blocked skills by their
`j-<name>` form only and never writes a skill directory path. Re-running the scan in "Reproducing the numbers" below
reports **zero path hits** for this file (the total stays 225). It does add 38 *name* hits, as every maintainer
document in `project/documentation/` that discusses these skills does; name hits are out of this story's scope.

- Scanned: commit `9621ddc05ffbd41f7b819e46b3d1458276c5e5fa` (tip of `E28_S21_T01-block-comment-continuation-lines`,
  so `E28_S21_T01`'s corrected comment rule is in force). Committed state, not the dirty main checkout.
- Date: 2026-10-22.

## 1. Result in one screen

| Question | Answer |
|---|---|
| Path hits now (T01 in) | **225** skill-path hits in **44** files, **28** once the generated `.claude/`/`.agents/` mirror copies are folded onto their root file |
| Against the baseline (239 / 54 / ~227) | Not contradicted. Committed state before T01 is 237 / 53; T01 removes exactly 12 hits and 9 file instances; the remaining gap to the baseline is 2 hits of drift in `project/` (section 3) |
| Defects | **5 lines in 2 files**, not "up to 54 files": one template that is rendered into consumers' repositories (1 line), and a permission-levels README (4 lines). They account for 15 of 225 hits (7 percent) once the three trees are counted |
| Legitimate-by-purpose | **26 of 28 files**, 210 of 225 hits (93 percent). Five of those are genuinely ambiguous (section 5) |
| Reaches an npm consumer | **8 files** (49 hits). The other 20 root files (`project/` and `tests/`) and all 16 mirror copies never leave the repository |
| Exemption granularity | **Per-file**, keyed on the root path with the mirror prefixes folded, each entry carrying a reason; an optional literal-substring narrowing for the three single-hit files. Not per-skill (the classes cut across skills). Per-line is not needed by the data |
| The premise that needs correcting | `scripts/check-public-references.sh` is **not** a whole-ship-set view as committed. It carries its own scope filter and sees 262 of 1671 public files (section 2) |
| T03 / T04 / T05 | T03 proceeds, resized. T04 proceeds, resized from "up to 54 files" to about 2. T05 proceeds, but its "whole ship set" scope needs a user decision first (section 8) |

## 2. How the scan was run, and what the audit script actually covers

The task asked for `scripts/check-public-references.sh` rather than "a disabled scope filter". The script is the
right instrument (it calls the shared rule in `scripts/never-public-refs.sh` with `strict=1`), but it is not
full-coverage as committed. Line 66 declares its own filter:

```
SCOPE_RE='^(skills/[^/]+/SKILL\.md|skills/[^/]+/scripts/|scripts/|hooks/)'
```

Run unmodified at `9621ddc0` it reports `FAIL -- 40 critical, 50 minor across 262 public file(s)`. It sees 14 of the 225
path hits (the root `scripts/` files); `lib/`, `project/`, `templates/`, `tests/` and every mirror copy are
invisible to it. (`E28_S19_T06` moved the *rule*
onto the shared library; it did not widen the *scope*.)

The inventory therefore uses the same script with exactly one change: that one assignment replaced by `SCOPE_RE="."`,
in a scratch copy outside the repository. Nothing else differs, so severity, regexes, the blocked-skill set and the
`.publicignore` handling are the script's own. Run that way it reports `607 critical, 207 minor across 1670 public
file(s)` (1671 public files; the script skips `.publicignore` itself). Of the 607, **256 are path hits** and 351 are
name hits; name hits are out of this story's scope. The 256 split into **225 skill-path hits** (the subject of this
spike) and **31 hits on the router MCP server directory**, which the script audits through a separate
private-tooling pattern and which the mirror guard's path regex does not match (section 6).

The count of 225 uses the filter `critical`, kind `path`, subject not the router directory. Mirror copies are folded
by stripping a leading `.claude/` or `.agents/`.

## 3. Counts restated against the baseline

| | Story baseline (2026-10-22, main checkout) | Pre-T01 rule, committed `fb722671` | Pre-T01 rule, main checkout (read-only re-scan) | **Post-T01, committed `9621ddc0`** |
|---|---|---|---|---|
| Path hits | 239 | 237 | 238 | **225** |
| Distinct files (mirrors counted separately) | 54 | 53 | 54 | **44** |
| Distinct files (mirrors folded) | not stated | 31 | not measured | **28** |
| `lib/` | 96 | 96 | 96 | 84 |
| `project/` | 61 | 59 | 60 | 59 |
| `scripts/` | 42 | 42 | 42 | 42 |
| `templates/` | 21 | 21 | 21 | 21 |
| `tests/` | 19 | 19 | 19 | 19 |

Explanations, none of which replaces the baseline silently:

1. **T01 accounts for exactly 12 hits and 9 file instances.** Pre-T01 to post-T01 is 237 to 225, and every one of
   the 12 removed hits is a `j-self-sync` line in a block-comment continuation: `lib/generate-copilot-hooks.js:33`,
   `lib/generate-skill-allow-list.js:41` and `:153`, `lib/mirror.js:8`, each in root, `.claude/` and `.agents/`. That is
   T01's own census (4 distinct lines, tripled). The 9 files that drop out are `generate-copilot-hooks.js`,
   `generate-skill-allow-list.js` and `mirror.js` in the three trees.
2. **The story's "~227" was 239 minus 12.** The measured post-T01 figure is 225. The 2-hit difference is not T01; it
   is the `project/` drift in item 3.
3. **`project/` differs by 1 to 2 hits between measurements** (61 on the baseline, 60 in the main checkout today, 59
   committed). The main checkout is dirty (about 180 modified or untracked files) and `project/` documents are edited
   continuously. Nothing in `lib/`, `scripts/`, `templates/` or `tests/` moved. The main checkout cannot be re-measured
   post-T01, because T01 is not in main; the expectation there is 238 minus 12 = 226.
4. **T01's "only 2 hits moved from critical to minor" is a different scope.** That measurement ran the three
   consumers over their own narrow scopes. The two lines it moved (`scripts/postinstall.js:26`, a name hit, and
   `skills/jenga/scripts/load-nl-catalog.js:85`, a hit on the router MCP directory) are in neither the 239 nor in the
   225: one is a name hit and the other is private tooling rather than a skill path. The 12 `lib/` lines are outside
   all three narrow scopes, so T01 moved 0 of them there and moves them only under the broad scan. Both statements
   are true; they describe different scopes. T01 also moved 15 router-directory hits under the broad scan (5
   distinct lines in three trees: `lib/generate-skill-allow-list.js:64` and `:111`, `mcp/help/scan.js:8` and `:9`,
   `skills/jenga/scripts/load-nl-catalog.js:85`).
5. **The baseline's 349 criticals mix two things.** 239 skill-path hits plus about 110 name hits in non-markdown
   files. Measured now: 225 path hits plus 99 non-markdown name hits. `T05` widens path scanning only, so the
   red it would introduce today is 225 path hits, not 349.

By blocked skill, the 225 are: `j-mirror-public` 76, `j-dev-done` 50, `j-train` 36, `j-convert` 29, `j-self-sync` 28,
`j-strategy` 6. 52 of the 127 root-form hit lines use the bare form (for example the retired `self-sync` or
`dev-done` directory names), which is dead twice over: the bare directories were deleted by `E50_S15` and the skill
behind them is private anyway.

## 4. What reaches a consumer

The story's test is "a consumer install never receives a file pointing at a directory it does not have". A consumer
install is the npm package. `package.json` `files` is a whitelist (`skills/`, `agents/`, `hooks/`, `scripts/`,
`templates/`, `bin/`, `lib/`, selected `mcp/` and `project/app/` paths, `README.md`, `LICENSE`) and `.npmignore`
excludes `project/`, `.claude/` and `.agents/`. `npm pack --dry-run --json` at `9621ddc0` lists 483 files. Intersecting
that list with the 44 hit files:

- **Reaches npm (8 files, 49 hits):** `lib/legacy-shipped-paths.json`, three files in `scripts/`, and four in
  `templates/`.
- **Does not reach npm (36 file instances, 176 hits):** 15 files under `project/`, 5 files under `tests/`, and the 16
  `.claude/`/`.agents/` mirror copies of the 8 files above.

`skills/`, `agents/` and `hooks/` carry **zero** skill-path hits in any file kind. Everything the instruction-scoped
guard already covers is clean for path hits; the exposure sits in `lib/`, `scripts/` and `templates/`.

`tests/` additionally already has a stronger, behavioural gate: `check_test_subject_invariant` runs the shipping
suite in a mirror-shaped tree (`public-mirror-content-parity.md`, "Now machine-enforced"). That document records why
static scanning of tests was tried and rejected (3 false positives in 4 files). The five test files below are exactly
the shapes it described: sandbox fixtures and guarded skips.

## 5. Inventory and classification

Classification test: **legitimate-by-purpose** when naming the path is the file's purpose, or the reference is a
fixture, a guarded skip, or maintainer documentation whose subject is the private mechanism; **defect** when a
consumer, or a reader following an instruction, is sent to a path that resolves to nothing and the path is not the
file's subject.

Line numbers are for the root file. Mirror copies carry identical line numbers (every one of the 49 hits in
`lib/`, `scripts/` and `templates/` appears exactly three times, in root, `.claude/` and `.agents/`). "Trees" is the
number of copies. A mirror copy takes its root file's classification; `T04` edits root only and `j.self-sync`
regenerates the rest.

### 5.1 `lib/` (1 file, 28 hits x 3 trees = 84)

| File | Trees | Hits | Lines by blocked skill | Class | Reason |
|---|---|---|---|---|---|
| `lib/legacy-shipped-paths.json` | 3 | 28 | j-convert 25-32; j-dev-done 34-35, 91-92; j-mirror-public 230-232; j-self-sync 288-289; j-strategy 302; j-train 308-317 | legitimate-by-purpose | A static registry of paths that shipped in real prior npm versions, consumed by postinstall to seed delete reconciliation (`generate-legacy-shipped-paths.js`, `postinstall.js`). The path strings are the data, as in `.publicignore` itself. Editing it to stop naming them would break the registry. Generated, so only a file-level key survives regeneration. |

Not a hit any more: `lib/generate-skill-allow-list.js`, `lib/generate-copilot-hooks.js` and `lib/mirror.js`. Their
path references were all block-comment continuation lines (section 3, item 1). The story and `T04` describe the first
two as "shipped executable logic composing paths into skill directories"; at the literal level that is not borne
out, because after T01 none of the three has a non-comment path hit. (A path built from fragments at run time is
invisible to this scan; see section 10.)

### 5.2 `scripts/` (3 files, 14 hits x 3 trees = 42)

| File | Trees | Hits | Lines by blocked skill | Class | Reason |
|---|---|---|---|---|---|
| `scripts/compute-deploy-reconcile.sh` | 3 | 1 | j-mirror-public 146 | legitimate-by-purpose (**ambiguous**) | The line reads the mirror skill's config, a deliberately maintainer-only input; the script discovers deploy tags for the private repository. Ambiguous because the parity document says the path is "skipped" in a consumer install, whereas the code dies with "config not found" on the next line, and its callers (`mark-deployed.sh`, then `j.status`/`j.self-sync`) treat that as a non-fatal warning. The reference is intentional; the consumer-visible failure message is a separate, small quality issue (a guard that exits quietly), not something an exemption or a reword would fix. |
| `scripts/repoint-dead-bare-path-prose.py` | 3 | 3 | j-mirror-public 17, 35, 40 | legitimate-by-purpose (**ambiguous**) | A spent one-shot migration tool (`E50_S22_T03`): the paths are the targets it rewrites. No live caller; only project documents mention it. Ambiguous between "exempt it" and "retire it". |
| `scripts/rewrite-stale-skill-preambles.py` | 3 | 10 | j-dev-done 14, 16, 86-87, 94, 100, 105, 151, 163, 170 | legitimate-by-purpose (**ambiguous**) | Same class: a spent `E50_S22_T02` migration tool whose paths are the files it edits and the text it writes. Lines 14 and 16 sit in the module docstring and count as non-comment because the comment rule is lexical and a docstring line does not start with a comment marker. |

Retiring the two migration scripts would clear 13 root hits (39 with mirrors) without any exemption, but deleting
shipped files is outside this story and is the user's call; the exemption is the lower-risk reading.

### 5.3 `templates/` (4 files, 7 hits x 3 trees = 21)

| File | Trees | Hits | Lines by blocked skill | Class | Reason |
|---|---|---|---|---|---|
| `templates/copilot-instructions.md.tpl` | 3 | 1 | j-self-sync 111 | **defect** | Rendered by `lib/generate-copilot-instructions.js` into the *consumer's* Copilot instructions. Line 111 tells the consumer's agent that agent personas are mirrored by a self-sync skill and cites its bare script path, which exists in no consumer install and no longer exists even in this repository. The clearest case in the set of a reference a consumer's tooling would actually read. |
| `templates/permission-levels/README.md` | 3 | 4 | j-self-sync 3; j-mirror-public 28-29, 33 | **defect** | All four lines are stale dead-path references. Line 3 (a "Distribution note" naming the self-sync script path and `/distribute`) and line 33 (security prose naming the mirror script) use the retired bare form. Lines 28-29 are table rows that look like quotes of the level 4 and 5 allow rules but are not: they carry the retired bare form of the mirror script path, whereas `level-4-elevated.json:9` and `level-5-unrestricted.json:9` carry the `j-` form. So the rows document a rule that no template actually contains. (Corrected after the Tester's review; an earlier draft classed lines 28-29 as legitimate.) |
| `templates/permission-levels/level-4-elevated.json` | 3 | 1 | j-mirror-public 9 | legitimate-by-purpose (**ambiguous**) | A `permissions.allow` entry for the mirror script. Functional for the maintainer (it is why levels 4 and 5 exist for them) and inert in a consumer install, since it allows a command that does not exist. Ambiguous because it ships to consumers and a reader could find it odd; removing it would break the maintainer's level 4 and 5 behaviour. |
| `templates/permission-levels/level-5-unrestricted.json` | 3 | 1 | j-mirror-public 9 | legitimate-by-purpose (**ambiguous**) | As level 4. |

### 5.4 `tests/` (5 files, 19 hits, root only)

| File | Hits | Lines by blocked skill | Class | Reason |
|---|---|---|---|---|
| `tests/check-public-playbook-steps.bats` | 3 | j-self-sync 111, 117; j-mirror-public 233 | legitimate-by-purpose | Writes a blocklist line into a sandbox `.publicignore` and asserts on the resulting message: a fixture string. |
| `tests/commit-test-gate-mirror.bats` | 2 | j-dev-done 54-55 | legitimate-by-purpose | Line 55 is the guard itself: skips visibly when the private directory is absent (sanctioned resolution 2). |
| `tests/commit-test-gate-skill.bats` | 3 | j-dev-done 26-27, 33 | legitimate-by-purpose | Lines 26-27 define variables; line 33 skips when the file is absent. |
| `tests/smoke-test-skills.bats` | 8 | j-convert 772, 798, 887, 898-899; j-mirror-public 52, 680, 809 | legitimate-by-purpose | Fixture text written into sandboxes and arguments to the rule under test; line 680 is a guarded known-defect branch for a mirror without the private skill. |
| `tests/strategy-path-resolver.bats` | 3 | j-strategy 144-145, 147 | legitimate-by-purpose | Guarded by a file-existence check that skips with an explicit "SKIPPED (no coverage)" message. |

None of the five reaches npm, and the behavioural test-subject gate already covers them.

### 5.5 `project/` (15 files, 59 hits, root only)

All 15 are legitimate-by-purpose and none reaches npm. They are maintainer documentation, board digests or generated
graph data whose subject is the private mirror and self-sync machinery, so the path is what is being described.

| File | Hits | Lines by blocked skill | Reason |
|---|---|---|---|
| `project/PROJECT_SUMMARY.md` | 11 | j-mirror-public 56, 137, 712; j-self-sync 43, 402, 582, 720; j-train 340-341, 349, 887 | Board digest recording facts about those skills. |
| `project/documentation/commit-consumer-audit.md` | 7 | j-dev-done 333; j-mirror-public 74, 102-103, 334; j-self-sync 73; j-train 321 | Audit table of `git log` call sites, one row per script. |
| `project/documentation/commit-traceability-contract.md` | 1 | j-self-sync 80 | Contract table naming the script that owns an operation. |
| `project/documentation/distribution.md` | 12 | j-mirror-public 602, 608, 611-616, 618, 631, 642; j-self-sync 8 | Lines 602-642 are quoted audit transcripts (`grep` over the mirror script). Line 8 is a "see ..." pointer using the dead bare path: stale, but internal and not shipped. Recorded, not classified as a defect, because the file never reaches a consumer. |
| `project/documentation/event-log-merge-strategy.md` | 1 | j-mirror-public 99 | Table of event writers. |
| `project/documentation/examples/migrating-from-distribute-to-npm-structure-e26.md` | 4 | j-self-sync 36, 75, 100-101 | Maintainer how-to for the in-repo mirror. Uses the dead bare form; stale rather than leaking. |
| `project/documentation/hook-parity.md` | 1 | j-self-sync 75 | States what is *not* involved; the path is the subject. |
| `project/documentation/mirror-release-branch.md` | 2 | j-mirror-public 5-6 | Design note about the mirror skill. |
| `project/documentation/mirror-test-subject-invariant-diagnosis.md` | 7 | j-mirror-public 17, 82, 98-99, 101, 104, 507 | Failure diagnosis quoting error messages that contain the path. |
| `project/documentation/preflight-checklists.md` | 1 | j-mirror-public 1417 | Example of a command the gate does not stop. |
| `project/documentation/public-mirror-content-parity.md` | 5 | j-mirror-public 86, 179, 258, 328, 333 | The rule's own specification. |
| `project/documentation/skill-authoring.md` | 2 | j-mirror-public 315; j-self-sync 871 | Historical prose describing a function and a skill; the bare form is stale. |
| `project/documentation/task-merge-back-today.md` | 1 | j-mirror-public 27 | Cites a line of the mirror script. |
| `project/documentation/test-runner.md` | 2 | j-dev-done 703, 715 | Names the classifier script that `j.dev-done` uses. |
| `project/knowledge-graph/graph.json` | 2 | j-self-sync 2030; j-train 749 | Generated graph node descriptions. |

Sensitivity: if the maintainers decide that *readers of the public GitHub repository* count as consumers, these 15
files are public too, and the answer becomes a directory-level exemption (`project/`), not remediation: the
references are not instructions anyone is meant to follow, and rewriting 59 lines of historical documentation to
avoid naming the thing being documented would destroy its meaning. Repointing the stale bare forms to the `j-` form
would not clear the hit either, because the `j-` form is a hit as well.

### 5.6 The two classes in one file

**No file holds both classes.** An earlier draft named `templates/permission-levels/README.md` as the one mixed file,
reading its lines 28-29 as exact quotes of the level 4 and 5 allow rules. The Tester checked and they are not: the
README writes the retired bare form of the mirror script path, the JSON files write the `j-` form. All four README
lines are defects:

| Line | Blocked skill | Class | What to do |
|---|---|---|---|
| 3 | j-self-sync | defect | Reword: drop the script path, name the mechanism in words. |
| 28 | j-mirror-public | defect | Reword the table row (say "the mirror script"), or correct it to the real `j-` rule text; correcting it would leave a hit, so reword. |
| 29 | j-mirror-public | defect | As line 28. |
| 33 | j-mirror-public | defect | Reword: say "the mirror script" without the path. |

Nothing in the data forces a per-line mechanism.

## 6. Supplementary: the router MCP directory (outside the 225)

`scripts/check-public-references.sh` audits the router MCP server directory as private tooling by a separate
pattern; it is not a skill, the mirror guard's path regex does not match it, and the story's 239 does not count it. 31
hits in the broad scan (27 root-form lines in 11 files, plus the mirror copies of two scripts). All are
legitimate-by-purpose: `.gitignore` and `.npmignore` (ignore rules for runtime files), `package.json` (the `files`
whitelist), `scripts/check-public-references.sh` (it defines the pattern), `tests/attach-preserves-worktree-hook.bats`
(a fixture) and six `project/` documents or data files. **Recommendation: leave it out of `T05`** unless the user wants
the guard to audit private tooling as well; if it is added, it needs exemptions for the first four of those.

## 7. Spike questions, answered

1. **Per-file counts after T01, and against 239 / ~227?** 225 hits in 44 files (28 folded); table in section 3 and
   per-file in section 5. The difference from 239 is T01 (12) plus `project/` drift (2). The difference from ~227 is
   the same drift only.
2. **Is naming the path the file's purpose, or a reference a consumer would follow?** Of 28 files: 26 are purposeful
   (registry 1, spent migration tools 2, permission-template rules 2, one maintainer-only config reader 1, tests 5,
   maintainer documentation 15) and 2 contain references a consumer would follow
   (`templates/copilot-instructions.md.tpl`, `templates/permission-levels/README.md`). Five of the 26 are flagged
   ambiguous.
3. **Is the legitimate class stable enough to list, or does it need a pattern?** It is stable enough to list *for the
   files a consumer receives*: 6 entries (section 9). It needs a pattern only if `project/` and `tests/` are inside the
   scan, because they grow continuously. That is the real design choice, not a property of the data.
4. **Per-file, per-line or per-skill?** Per-file (section 9). Per-skill is wrong on the evidence: `j-self-sync`
   appears both in a legitimate registry and in a defect template, and `j-mirror-public` both in rules that must
   stay and a README line that should not. A per-skill exemption would hide the defects.
5. **Does any file contain both classes?** No. The one candidate, `templates/permission-levels/README.md`, was first
   read as mixed (lines 28-29 as exact quotes of the level 4 and 5 rules); checked against the JSON files, all four of
   its lines are stale bare-form references, so it is single-class and nothing forces per-line granularity.
   `distribution.md` has a stale pointer beside its legitimate transcripts, but as a file that never
   reaches a consumer it is not a defect.
6. **`settings.json`, and other generated or overwritten files?** Confirmed: the three `settings.json` files (root,
   `.claude/`, `.agents/`) carry **0** path hits, at the committed state and in the main checkout (session level 2).
   The special case is latent: the level 4 and level 5 *templates* each carry the mirror allow rule (section 5.3),
   and `scripts/jenga-permission-level-switch.sh` whole-file-overwrites both `settings.json` files from them, so a
   switch to level 4 or 5 writes a path hit into both generated files. It is harmless to the guard because
   `check_permission_level_invariant` (`mirror.sh`) forces the level 2 baseline before any real push. Other
   generated files that matter to an exemption design: `lib/legacy-shipped-paths.json` (regenerated by
   `scripts/generate-legacy-shipped-paths.js`, so line numbers are unstable and per-line keys would break),
   `project/knowledge-graph/graph.json`, and the `.claude/`/`.agents/` mirrors (key on the root path). The generated
   `lib/skill-allow-list.json` has no hits.
7. **Does option (b) stay green, or does the exemption list become the gate?** Depends on scope. Over the whole ship
   set, the legitimate class is 93 percent of hits, so the exemption list (with directory entries for `project/` and
   `tests/`) *is* the gate and the scan only meaningfully tests 7 percent. Over the files a consumer receives, 49
   hits remain, 6 exemption entries cover 44 of them, and the 5 defect lines are the only live signal, which is a
   proportionate gate. Either way it goes green after T04; only the second keeps the exemption list small and
   reviewable.

## 8. Recommendations

### 8.1 Exemption granularity

**Per-file, keyed on the root path with `.claude/` and `.agents/` folded, one reason per entry, path hits only.**
For the three single-hit files, add an optional literal-substring narrowing so a future second reference to a blocked
skill is not silently inherited. Files to exempt, for the files a consumer receives:

1. `lib/legacy-shipped-paths.json` (registry; whole file)
2. `scripts/compute-deploy-reconcile.sh` (narrow to the config-path line)
3. `scripts/repoint-dead-bare-path-prose.py` (spent tool; or retire)
4. `scripts/rewrite-stale-skill-preambles.py` (spent tool; or retire)
5. `templates/permission-levels/level-4-elevated.json` (narrow to the allow rule)
6. `templates/permission-levels/level-5-unrestricted.json` (narrow to the allow rule)

No entry for `templates/permission-levels/README.md`: all four of its lines are defects to reword in T04. If instead the scan
keeps the whole ship set, add two directory-level entries: `project/` (15 files) and `tests/` (5 files, already
covered by the behavioural gate). Do not enumerate those 20 files; every new design note that names the mirror
skill would otherwise break the gate.

### 8.2 T03, exemption mechanism: proceed, resized

The legitimate class exists, so the task is not dropped. Build the declared file at per-file granularity as above
(about 6 to 8 entries, not a pattern language), with a mandatory reason per entry, honoured identically by check 6,
the mirror guard and `scripts/check-public-references.sh`, and resolving mirror prefixes. Drop from its description
the premise that `templates/` holds fixtures (it holds a rendered template, a README and two permission files) and
the need for per-line granularity. It stays task scope.

### 8.3 T04, remediation: proceed, much smaller

Defects are **5 lines in 2 files**: `templates/copilot-instructions.md.tpl:111`, and
`templates/permission-levels/README.md:3`, `:28`, `:29` and `:33`. T04 must not treat `:28-29` as legitimate. The "shipped executable logic" in `lib/` named in the task is not a defect at the literal level. Its
`scope_rationale` (54 files, 96 `lib/` hits, `story_max_files` exceeded) is stale and should be rewritten. Remediate by
**rewording, not repointing**: pointing a stale bare path at the `j-` form still leaves a hit. Also decide, as a
separate small item, whether `scripts/compute-deploy-reconcile.sh` should exit quietly when the mirror config is
absent (consumer-visible, and not something T03/T04 exemptions fix).

### 8.4 T05, broadened scan: proceed, with a decision first

Its premise ("whole ship set") collides with the data. Two coherent options; this spike recommends the first and
leaves the choice to the story owner:

- **N, scope by reach (recommended).** Scan path hits across the files an npm consumer receives (derive it from
  `package.json` `files`; a second hardcoded list would drift). 49 hits, 6 exemptions, 5 defect lines to fix.
  No directory exemptions. The existing instruction scope for name hits is unchanged.
- **W, whole ship set.** Needs `project/` and `tests/` directory entries in the exemption file, so 93 percent of
  hits are exempt and the file becomes the gate.

T05's own text quotes "349 criticals"; the path-only red it would introduce today is 225 (section 3, item 5).
Its dependency order stands: T03 and T04 first.

## 9. Reproducing the numbers

All scratch files go outside the repository. Run from the repository (or a worktree of it) at the scanned commit.

*Update (`E28_S21_T05`).* The recipe below describes the audit script as it was at the scanned base. Since `T05` the
script takes its path-hit scan set from the npm-reach list and has a `--scope all` flag, so the `sed` of steps 1 and 2
is no longer needed: `bash scripts/check-public-references.sh --scope all` re-derives the whole-tree inventory (name
and path hits over every public tracked file) without editing the script. Step 0 now reports the npm-reach path
scope instead of the old narrow one.

```bash
# 0. As committed: the audit script's own narrow scope
bash scripts/check-public-references.sh > /tmp/asis.out 2> /tmp/asis.err; tail -1 /tmp/asis.err
# -> FAIL -- 40 critical, 50 minor across 262 public file(s)

# 1. Whole ship set: only the SCOPE_RE assignment changes
sed 's#^SCOPE_RE=.*#SCOPE_RE="."#' scripts/check-public-references.sh > /tmp/cpr-wide.sh
bash /tmp/cpr-wide.sh > /tmp/wide.out 2> /tmp/wide.err; tail -1 /tmp/wide.err
# -> FAIL -- 607 critical, 207 minor across 1670 public file(s)

# 2. Same, with the pre-T01 comment rule
git show fb722671:scripts/never-public-refs.sh > /tmp/npr.old.sh
sed -e 's#^SCOPE_RE=.*#SCOPE_RE="."#' -e 's#^LIB=.*#LIB=/tmp/npr.old.sh#' \
    scripts/check-public-references.sh > /tmp/cpr-wide-old.sh
bash /tmp/cpr-wide-old.sh > /tmp/wide-old.out 2> /tmp/wide-old.err; tail -1 /tmp/wide-old.err
# -> FAIL -- 643 critical, 171 minor across 1670 public file(s)

# 3. The 225 (skill-path, critical) and the 237 (same, pre-T01 rule)
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/' /tmp/wide.out     | wc -l   # 225
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/' /tmp/wide-old.out | wc -l   # 237

# 4. Files: unfolded (44) and mirror-folded (28)
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/ {split($2,a,":"); print a[1]}' /tmp/wide.out | sort -u | wc -l
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/ {split($2,a,":"); p=a[1]; sub(/^\.(claude|agents)\//,"",p); print p}' /tmp/wide.out | sort -u | wc -l

# 5. Area split, mirrors folded (lib 84, project 59, scripts 42, templates 21, tests 19)
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/ {split($2,a,":"); p=a[1]; sub(/^\.(claude|agents)\//,"",p); split(p,b,"/"); print b[1]}' /tmp/wide.out | sort | uniq -c

# 6. Reach: files npm would ship, and the hit files among them (8 files, 49 hits)
npm pack --dry-run --json --ignore-scripts | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j[0].files.map(f=>f.path).join("\n"))' > /tmp/pack-files.txt
awk -F'\t' '$1=="critical" && $3 ~ /\(path\)/ && $3 !~ /^mcp/ {split($2,a,":"); print a[1]}' /tmp/wide.out | sort -u | grep -Fxf /tmp/pack-files.txt
```

The read-only cross-check against the main checkout (238 hits, 54 files, `project/` 60) is step 3 with
`/tmp/cpr-wide-old.sh` run from the main checkout, which reads working-tree content and writes nothing.

## 10. Limits of this scan

- **Literal only.** The regexes match a written `skills/<name>/` or `skills/j-<name>/`. A path assembled from fragments
  at run time (a joined segment list, a template literal with an interpolated name) is invisible to it, as is a
  path split across lines. The conclusion that the `lib/` JavaScript has no live path reference is a statement about
  literals.
- **The comment rule is lexical** (`never-public-refs.sh` header). A line of code that begins with `*`, and a
  Python docstring line, are read as comment and as non-comment respectively regardless of what they are.
- **Committed state.** The numbers are for `9621ddc0`; uncommitted work in the main checkout is not reflected except
  where stated.
- **Reach is read from `package.json` `files`** as the private repository carries it. The published package is built
  from the mirror, which strips blocked files, so for the router directory the whitelist over-states what ships.
  This does not change any conclusion about the 8 files above.
- **Classification of the five ambiguous files** (`compute-deploy-reconcile.sh`, the two migration scripts, the two
  level JSON files) is a judgement; each was recorded rather than forced, and any of them can be moved to "defect"
  without changing the granularity recommendation, only the T04 list.

## 11. Remediation record (E28_S21_T04)

The 5 defect lines of sections 5.3 and 5.6 were **reworded, not repointed**: each now names the mechanism in words and
writes no skill directory path. Like the rest of this document, this section names blocked skills by their `j-<name>`
form only. No exemption was added for any of them. The "was" column describes the old text rather than quoting it, so
this section adds no path hit.

| File and line | Blocked skill | Was | Now |
|---|---|---|---|
| `templates/copilot-instructions.md.tpl:111` | j-self-sync | "mirrored into both of those paths by" the self-sync slash form, followed by that skill's bare script path in parentheses | "mirrored into both of those paths by the self-sync skill;". The rest of the sentence (the `.github/agents/` guidance) is unchanged |
| `templates/permission-levels/README.md:3` | j-self-sync | "Distribution note" citing the self-sync slash form with its bare script path and `COPY_SET`, and the retired distribute slash form with its config keys | "The self-sync skill (its script's `COPY_SET`) and the distribute flow (`distribute.config.json`, `distribute.include`) both ...". The config keys are not skill paths and stay |
| `templates/permission-levels/README.md:28` | j-mirror-public | Level 4 `autoMode.allow` row quoting `Bash(bash <bare mirror script path>*)`, a rule no template contains | `$defaults` plus "one entry that auto-approves running the mirror script (the entry is in the level's JSON file)" |
| `templates/permission-levels/README.md:29` | j-mirror-public | Level 5 row, same quote | `$defaults` plus "the same one entry that auto-approves running the mirror script" |
| `templates/permission-levels/README.md:33` | j-mirror-public | Security prose opening with the mirror script's bare path in code formatting | "The mirror script (`mirror.sh`) internally runs ...". The surrounding security explanation is unchanged |

Rows 28-29 describe the rule in words rather than correcting the quoted string, because the corrected string would
itself be a path hit. The `.claude/` and `.agents/` copies of both files were resynced from the root files, changed
files only.

### Scan after the fix

Method as in section 9 (whole-ship-set scope, committed state of the T04 branch, T01 comment rule and T03 exemption
file in force):

| Measure | Before T04 | After T04 |
|---|---|---|
| Path hits in the two files, three trees (root, `.claude/`, `.agents/`) | 15 | **0** |
| Skill-path hits reported (critical, not the router directory) | 93 | **78** |
| Skill-path hits with the exemption file disabled | 225 | **210** (225 minus 15) |
| Path-hit lines in files `npm pack --dry-run --ignore-scripts` lists (484 files) | 5 reported, plus 44 exempt | **0 reported; 44 exempt** |

The 44 exempt npm-reachable hits are the root hits T03 declared: `lib/legacy-shipped-paths.json` (28),
`scripts/compute-deploy-reconcile.sh` (1), the two migration scripts (3 and 10) and the two level JSON files (1 each).
They are the only survivors among the npm-reachable files, and none was added by this task. The 78 hits still reported
by the whole-ship-set scan are 59 in `project/` and 19 in `tests/`, matching sections 5.4 and 5.5; none reaches npm.

Render check: `lib/generate-copilot-instructions.js` was run against a throwaway consumer tree whose skills directory
holds only j-init (no j-self-sync directory). It writes `.github/copilot-instructions.md`, line 111 reads "paths by the
self-sync skill; cite `.github/agents/` as the", and the rendered file holds no path to a skill directory.

# SOLUTION ASSESSMENT

**Subject:** Resolving the structural weaknesses in the Board Index Substrate proposal (shell-callable query library over `project/*`, with `/status` as acceptance test and `/commit`-time validation).
**Input type:** Scrutiny assessment output

---

## 1. PROBLEM INVENTORY

All distinct problems, issues, and scrutinized weaknesses derived from §1 Core Assumptions, §2 Key Questions, §3 Risk Register, and §5 Blind Spots of the scrutiny.

| # | Problem | Source | Severity |
|---|---------|--------|----------|
| 1 | Latency budget of 50–200ms per call is unmeasured; a live-walk substrate wired into `/status` (and downstream `/dooo`, `/reconcile`) may add user-perceptible latency to commands whose value is instant feedback. | Scrutiny §1 A1, §2 Q1, §3 Risk 4 | Med |
| 2 | `/status` is a tree render, not a graph query — using it as the sole forcing function shapes the S02 query API against the wrong surface, locking in a schema that later graph-shaped consumers must fight. | Scrutiny §1 A2, §2 Q3, §3 Risks 1 & 2, §6 required condition | High |
| 3 | Commit-time validation is bundled into the substrate skill, conflating "read the board" with "police the board" — Open Decision #2 unresolved. | Scrutiny §1 A3, §5 blind spot on `/commit` as shared resource, §6 required condition | High |
| 4 | Distinctness from E20 relies on naming, not architecture — the two graph substrates will collide the moment E20 wants to link functions to tasks. | Scrutiny §1 A4, §3 Risk 5 | Med |
| 5 | Anemic-graph trap: `mentions_skill`, `depends_on`, `parent_doc` are optional and largely unpopulated, so the substrate's differentiating queries return empty until an unspecified backfill happens. | Scrutiny §1 A5, §3 Risk 6, §5 blind spot on backfill cost | High |
| 6 | Shell-library packaging with JSON stdout + predicate strings on stdin pushes quoting/escaping/injection surface into every caller — Open Decision #1 unresolved. | Scrutiny §1 A6, §3 Risk 7 | Med |
| 7 | Predicate syntax is described as "intentionally simple" but not specified — no grammar for escaping, list-valued fields (`mentions_skills`), negation, `OR`, or values containing spaces (e.g. `status="In Progress"`). | Scrutiny §2 Q4, §5 blind spot on API versioning | High |
| 8 | Commit-time validation has no designed bypass — the first legitimate in-progress commit that fails will train users to disable the hook. | Scrutiny §2 Q2, §3 Risk 3, §6 required condition | High |
| 9 | `TodoEntry` identity is unspecified — line hash breaks on edit, position breaks on reorder, content breaks on both. `queued_as` is load-bearing for `/do`, `/reconcile`, `/dooo`. Open Decision #5 unresolved. | Scrutiny §2 Q5, §3 Risk 8 | High |
| 10 | Behaviour during partial repo states — mid-rebase, mid-bisect, dirty worktree with unstaged renames — is undefined. Live-walk turns filesystem transients into graph transients. | Scrutiny §2 Q6 | Med |
| 11 | Worktree topology is a blind spot: this project actively uses `.claude/worktrees/`, and it is unspecified whether the substrate reads the primary tree only, aggregates worktrees, or ignores them. | Scrutiny §2 Q7, §5 first blind spot | Med |
| 12 | Single-consumer capture: if no second consumer materialises within one epic of shipping, the substrate is dead weight; the "within one epic" gate is soft with no enforcement. | Scrutiny §3 Risk 1, §5 blind spot on `/reconcile` overlap, §6 required condition | High |
| 13 | Provisional story order (§11) puts the query API (S02) before the consumer refactor (S03), so the API is designed in the dark against a single non-graph consumer. | Scrutiny §3 Risk 2 | High |
| 14 | `Skill` and `Agent` nodes with `id, path` only make `mentions_skill=X` queries useless for human-facing output — every consumer must re-read the skill file, defeating the substrate's raison d'être. Open Decision #4 unresolved. | Scrutiny §5 fourth blind spot | Med |
| 15 | No query API versioning story — if S07 adds `OR` or negation, existing consumers may break silently. | Scrutiny §5 fifth blind spot | Low-Med |
| 16 | `/commit` is a shared resource — hook ordering, composability, and interaction with `/lgtm` (which chains through `/commit`) are undiscussed. | Scrutiny §5 sixth blind spot | Med |
| 17 | PROJECT_SUMMARY.md is currently empty — the "semantic root" node is a stub, so any consumer traversing toward "project context" hits nothing useful in v1. | Scrutiny §5 seventh blind spot, §1 self-assessment | Low |
| 18 | Validation and extraction share code paths, so a bug in one breaks both. | Scrutiny §3 Risk 9 | Low |

---

## 2. SOLUTION PATHS

### Problem 1: Unmeasured latency budget

#### Solution A: Prototype-and-measure spike before S02 opens

**Description:** Spend one focused half-day writing a throwaway bash+jq extractor that walks the current `project/*` tree, parses frontmatter for every node, materialises all edges, and emits JSON. Run it 20 times cold (drop caches) and 20 times warm. Record p50/p95. Publish numbers in §7 of the brainstorm doc, replacing the "50–200ms" guess. If p95 cold is above 150ms, either (a) accept a documented budget of the measured number, or (b) reopen §9 to add an optional on-demand cache.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Throwaway prototype, no API design |
| Time (rough order of magnitude) | 4–8 hours | Half a day |
| Skill requirements | bash, jq, frontmatter parsing, `hyperfine` or equivalent | |
| Dependencies | None — current board is enough to measure | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Prototype latency is misleading because throwaway code is naive | Low | Med | Use realistic data-shaping (parse frontmatter properly, not `grep`) |
| Board grows 10× and invalidates the measurement | Low | Med | Also measure a synthetic 10× board (copy `project/board/**` ten times into a scratch dir) |

**Viability verdict:** RECOMMENDED
**Rationale:** Directly answers scrutiny §8 recommendation #4. Small, cheap, and produces a number that either confirms or reshapes §7 and §9.

#### Solution B: Accept live-walk unconditionally, defer measurement to first complaint

**Description:** Keep the "50–200ms — good enough" position, ship S01–S03, and address latency when a consumer complains.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | None | Doing nothing |
| Time | 0 | |
| Skill requirements | None | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| `/status` becomes visibly slower than today, users regret the refactor | Med | Med | Ship anyway, revert if complaints arrive |
| `/dooo` calls `/status`-derived data in a loop, latency compounds | Med | Med-High | None — must measure to know |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** The measurement is cheap and the risk of shipping without it is asymmetric. Deferring "until a consumer complains" (§9) is fine for optimisation, but not for the initial budget.

---

### Problem 2: `/status` is the wrong forcing function

#### Solution A: Name a second, graph-shaped consumer before S01 opens

**Description:** Commit in writing to a second acceptance-test consumer that exercises `mentions_skill`, `depends_on`, `orphan=true`, or `neighbors --depth=2`. Add it to §4 of the brainstorm doc as co-equal with `/status`. Candidate: `/reconcile` optimisation (already walks the board ad-hoc; scrutiny §5 flags it as the natural stress test). Alternative: a new `/impact <node_id>` skill that returns nodes reachable via `depends_on`/`blocks`/`mentions_*` from a given epic/story/task. Reorder story decomposition so S03 becomes "port both consumers concurrently."

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Requires committing to a second skill design at brainstorm time |
| Time | 4–8 hours to decide + design sketch; adds 3–5 days to the epic total for the second port | |
| Skill requirements | Product/architecture judgement to pick the right second consumer | |
| Dependencies | Problem 5 (anemic edges) if the chosen consumer relies on `mentions_skill` | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Chosen second consumer also fails to exercise graph queries deeply enough | Med | Low-Med | Prefer `/impact` — it is definitionally a traversal query |
| Adding a second consumer to S03 balloons the epic scope | Med | Med | Timebox: if second port drags past 5 days, accept as follow-on but keep API co-designed |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §8 recommendation #1 and #2 both hinge on this. Without it, the API is designed against a tree render.

#### Solution B: Ship `/status`-only, gate the epic close on a second consumer within one epic

**Description:** Proceed as proposed, but add a hard gate: the epic cannot be marked Done until a second consumer is ported. If none materialises within one epic of shipping, mark the substrate deprecated and revert `/status`.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Just a scope-close policy |
| Time | Adds nothing upfront; risks weeks of wasted work if revert triggers | |
| Skill requirements | Discipline to actually revert | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Sunk-cost fallacy prevents the revert from ever happening | High | High | None reliable — projects rarely revert shipped substrates |
| API is already locked by the time the second consumer arrives | High | Med-High | None — this is the exact problem being deferred |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** This is the current proposal's implicit stance. Scrutiny §3 Risk 1 says "acknowledges but does not mitigate."

---

### Problem 3: Validation bundled into substrate

#### Solution A: Split validation into its own skill (`/validate-board`), invoked by `/commit`

**Description:** Create a separate skill at `.claude/skills/validate-board/` that depends on the substrate's `graph::nodes` and `graph::edges` outputs. The substrate exports read-only queries; the validator composes them and produces a rapport. `/commit` invokes `/validate-board` (not `graph::validate`). Substrate has no policy code; validator has no traversal code. Resolves Open Decision #2 as "yes, split."

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Just a boundary change; no new logic |
| Time | 1 day extra during S04 to structure as a separate skill | |
| Skill requirements | Skill authoring, understanding of `/commit` hook wiring | |
| Dependencies | S01 substrate library must expose primitive queries first | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Two skills to maintain instead of one | Low | Certain | Accept — the separation is the point |
| Hook wiring becomes more complex (`/commit` → `/validate-board` → substrate) | Low | Med | Document call chain in skill README |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §6 lists this as a required condition; §8 recommendation #3 explicitly names it. Decouples two failure modes (Problem 18) at negligible cost.

#### Solution B: Keep validation inside the substrate, mark `graph::validate` as a "boundary" API

**Description:** Leave the coupling; document that `graph::validate` is the only write-side entry point and everything else is pure read.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | None | Status quo |
| Time | 0 | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Bugs in validation break extraction and vice versa | Low-Med | Med | None — coupling remains |
| Future consumers wanting different validation policies must fork the substrate | Med | Med | None |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** No real benefit over Solution A; loses the decoupling that scrutiny explicitly calls out as required.

---

### Problem 4: E20 collision on second contact

#### Solution A: Define a machine-checkable ownership boundary (path prefixes)

**Description:** Codify in both this epic's and E20's charters: this substrate reads only `project/*` and `.claude/{skills,agents}/*/SKILL.md`-level metadata. E20 reads only `app/`, `configs/`, and source-code trees. Cross-references are one-directional: E20 may consume this substrate's node IDs; this substrate MUST NOT consume any E20 output. Add a lint (part of `/validate-board`) that fails if this substrate's extractor code references any path outside its allowed set. Also add a naming rule: node types owned by this substrate are `Epic|Story|Task|Plan|Summary|Doc|TodoEntry|Skill|Agent`; E20 owns `Service|Function|Module|DataFlow`. Reserved-word collisions fail lint.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Requires coordination with E20's owner and a lint |
| Time | 1–2 days (design + lint + charter amendments to both epics) | |
| Skill requirements | Architectural boundary design | |
| Dependencies | E20 exists and has an owner willing to co-sign | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| E20 not far enough along to commit to symmetric boundaries | Med | Med | Publish this side unilaterally; E20 accepts asymmetrically when it ships |
| Future fusion pressure still wins (both graphs merged in year 2) | Low | Med | Accept as a v1 posture, not a permanent commitment |

**Viability verdict:** RECOMMENDED
**Rationale:** Turns the "naming rule" from §3 of the proposal into an enforceable rule. Scrutiny's challenge is that "naming, not architecture" is insufficient — this makes it architectural.

#### Solution B: Accept future fusion, plan for it explicitly

**Description:** Design this substrate's node schema deliberately compatible with E20's (shared `id` namespace, shared JSON shape) so a future merge is straightforward. No enforcement; explicit acceptance that in year 2 there will be one graph.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med-High | Requires design coordination with a not-yet-implemented E20 |
| Time | 2–4 days | |
| Skill requirements | Schema design, knowledge of E20's direction | |
| Dependencies | E20 has enough shape to design against | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| E20 changes direction and this substrate's schema is now shaped by a ghost | High | Med | None reliable |
| Undermines this proposal's core "distinct from E20" pitch | Med | High | Requires rewriting §2, §3 of the brainstorm |

**Viability verdict:** CONDITIONAL
**Rationale:** Only viable if E20 has stabilised its own schema, which it has not. Otherwise this couples v1 to a moving target.

---

### Problem 5: Anemic-graph trap

#### Solution A: Add S06 "Seed & backfill" story to the epic

**Description:** New story: sweep every existing epic/story/task/doc, propose `mentions_skills`, `mentions_agents`, `depends_on`, and `parent_doc` values based on heuristics (grep for skill/agent names, cross-reference existing text), and add them via one bulk commit. Author reviews before commit. Adds a documented "backfill script" to the substrate skill that any future contributor can rerun on a new tranche of files.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Grep-based heuristics + human review |
| Time | 2–4 days for the backfill sweep; script is ~half a day of that | |
| Skill requirements | grep, familiarity with the board's existing text conventions | |
| Dependencies | S05 (frontmatter templates) must land first so keys are defined | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Heuristic backfill produces false-positive edges | Med | High | Human review before commit; script emits a diff, not a direct write |
| Backfill happens once, then decays as new files skip the keys | High | High | Combine with Solution B (soft nudge in `/commit`) |

**Viability verdict:** RECOMMENDED
**Rationale:** Directly addresses scrutiny §5 blind spot ("no cost estimate for backfilling frontmatter"). Without it, the differentiating queries are empty.

#### Solution B: Add a non-blocking "hint" to `/commit` when frontmatter is missing

**Description:** In `/validate-board` (Problem 3 Solution A), add a *warning* (not error) tier: "This task's story mentions no skills. Consider `mentions_skills: [...]`?" Never blocks the commit. Provides a forcing function without a hard gate.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Warning tier is trivial once validator exists |
| Time | 4 hours during S04 | |
| Skill requirements | Same as S04 | |
| Dependencies | Problem 3 Solution A must be in place | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Warnings get ignored, no improvement in edge density | Med | High | Combine with Solution A for initial seed |
| Nag fatigue leads users to disable warnings | Low | Med | Only warn on newly-created files, not edits |

**Viability verdict:** VIABLE (as complement to Solution A, not replacement)
**Rationale:** Sustains what Solution A seeds. Neither alone suffices.

#### Solution C: Descope the anemic edges entirely from v1

**Description:** Remove `mentions_skill`, `mentions_agent`, `depends_on`, and `parent_doc` from the v1 schema. Ship only `contains`, `plans`, `summarizes`, and `queued_as` — all of which are derivable from filename/frontmatter that already exists. Defer the optional edges to a v2 when a consumer specifically needs them.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Removes surface area |
| Time | Saves ~2 days across S01/S05 | |
| Skill requirements | None | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Second consumer (Problem 2 Solution A) needs these edges | High | High | Coordinate: pick second consumer that uses only kept edges (e.g. `/impact` on `contains`+`queued_as` only), or accept descope also removes second-consumer candidates |
| Substrate becomes indistinguishable from a `find | grep` wrapper | Med | Med | Accept — the graph API surface is still the value |

**Viability verdict:** CONDITIONAL
**Rationale:** Cleanest fix but forecloses the second-consumer options that most justify the epic. Only viable if Problem 2's second consumer is scoped to work on required edges only.

---

### Problem 6: Shell packaging pushes quoting/escaping to callers

#### Solution A: Provide typed helper functions (bash source-able API)

**Description:** In addition to the CLI (`graph::query "..."`), ship a bash library file (`graph.sh`) with typed helpers: `graph_query_by_type Story Passed`, `graph_neighbors E17_S05 2`, `graph_orphans`. Callers `source` it. Predicate strings become an implementation detail; injection surface narrows to inputs the caller already controls. CLI remains for one-off shell use.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low-Med | Bash functions wrapping the CLI |
| Time | 1 day during S02 | |
| Skill requirements | Bash function-writing, awareness of quoting rules | |
| Dependencies | S02 predicate syntax must be defined | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Callers ignore helpers and hand-roll predicates anyway | Low | Med | Document as the preferred path in the skill README |
| Helper function surface grows large | Low | Med | Cap at ~10 helpers; anything else uses the CLI |

**Viability verdict:** RECOMMENDED
**Rationale:** Cheap way to address Open Decision #1 without changing the substrate's shell-native character.

#### Solution B: Move to JSON-on-stdin for predicates

**Description:** Instead of `graph::query "type=Story AND status=Passed"`, take a JSON predicate on stdin: `echo '{"type":"Story","status":"Passed"}' | graph::query`. Eliminates shell-string parsing entirely.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Replace parser with `jq` |
| Time | 1 day during S02 | |
| Skill requirements | jq | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Loses the ergonomic one-liner appeal of the current design | Med | Med | Keep the string form as sugar over the JSON form |
| Callers still need to construct JSON in bash (its own quoting hell) | Med | Med | Combine with Solution A |

**Viability verdict:** VIABLE
**Rationale:** Cleaner semantically than Solution A but ergonomically worse. Prefer A unless Problem 7's grammar becomes unwieldy.

---

### Problem 7: Predicate syntax underspecified

#### Solution A: Write a half-page predicate grammar appendix before S02

**Description:** Formal EBNF (or table-form) grammar covering: identifier rules, value quoting (double quotes for values with spaces or special chars), `AND` only in v1 (no `OR`, no negation — explicit non-goals), list-valued fields via `IN` operator (`mentions_skills IN [reconcile]`), case sensitivity policy (values case-sensitive, keys lowercase), `orphan=true` and `type=X` as reserved forms. Document in an appendix to §8. Include 10 worked examples covering every corner case (values with spaces, list membership, mixed with `AND`).

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Grammar design + coverage of edge cases |
| Time | 1 day | |
| Skill requirements | Familiarity with simple grammar design; not a full parser generator |  |
| Dependencies | Problem 6 Solution A/B may affect the surface | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| v1 grammar boxes out a v2 need (`OR`, negation) | Med | Med | Reserve `|`, `NOT` tokens as syntax errors in v1 so v2 can add them non-breakingly |
| Callers hit an unspecified corner not covered in examples | Low-Med | Med | Add "unspecified → error, not silent-pass" as a stance |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §8 recommendation #5 directly. Without it, S02 designs the parser and the grammar simultaneously — always a bug source.

---

### Problem 8: No commit-time validation bypass

#### Solution A: `--no-validate` flag + `SKIP_VALIDATE=1` env var, both documented in S04 acceptance criteria

**Description:** Two escape hatches: `git commit --no-validate` (custom flag intercepted by our hook) and `SKIP_VALIDATE=1 git commit` for scripted contexts. Both emit a rapport line so the escape is auditable. `/lgtm` learns to pass through the flag if the parent invocation used it. Documented in S04 story acceptance criteria before the hook is enabled.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Standard hook design |
| Time | 4 hours during S04 | |
| Skill requirements | Git hook authoring | |
| Dependencies | Problem 3 Solution A (validator is separable) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Users default to always-bypass, validation becomes vestigial | Med | Med | Emit audit line in rapport; review bypass rate periodically |
| Bypass flag inconsistent with other project hooks | Low | Low | Follow whatever convention `/commit` skill already uses |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §8 recommendation #7. Trivial to build; catastrophic to skip.

#### Solution B: Grace period — warnings-only for first two weeks post-ship

**Description:** For a defined window, validation failures print but do not block. After the window, switch to hard block. Announced in the epic close rapport.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Two modes with a date-gated switch |
| Time | 4 hours | |
| Skill requirements | None special | |
| Dependencies | Same as A | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Two-week window passes with no fixes, then hard block breaks everything | High | Med | Combine with Solution A so bypass exists at hard-block time |

**Viability verdict:** VIABLE (as complement to A, not replacement)
**Rationale:** Reasonable rollout tactic; not a substitute for a real bypass.

---

### Problem 9: `TodoEntry` identity unspecified

#### Solution A: Composite identity — `(board_ref, normalized_text_hash)` with fallback to `line_hash`

**Description:** If a todo line has a resolvable `board_ref` (E##_S## or E##_S##_T##), the entry identity is `(board_ref, hash(normalize(text)))` where `normalize` collapses whitespace, strips leading bullets, and lowercases. This survives reorder and minor rewording as long as the board ref stays. For lines with no board ref, fall back to `line_hash` (and accept churn). Document the tradeoff explicitly. Consumers of `queued_as` receive edges keyed by `(TodoEntry.id, Story/Task.id)`; if the entry disappears but the board target still has an open incoming `queued_as` from a differently-hashed entry with the same board ref, resolve as the same logical queueing.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Requires normalisation rules and fallback logic |
| Time | 1–2 days during S01 (extraction) | |
| Skill requirements | Careful thinking about identity semantics | |
| Dependencies | None; must land in S01 because `queued_as` extraction depends on it | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Composite ID collides across two todo lines referencing the same story with the same text template | Low | Low | Include line position as tiebreaker only when the hash collides |
| Normalisation rules don't cover all real edits | Med | Med | Publish the rules and iterate |

**Viability verdict:** RECOMMENDED
**Rationale:** Best-available compromise for a semi-structured file. Scrutiny §2 Q5 rightly says all three naive options are broken; this hybrid addresses the load-bearing case (`board_ref` present) and accepts churn where identity is genuinely undefined.

#### Solution B: Redefine `todo.md` as structured YAML/JSON, migrate content

**Description:** Turn `todo.md` into `todo.yaml` or `todo.json` with explicit IDs per entry. Migrate existing content. Update `/todo`, `/do`, `/reconcile`, `/dooo` to read the new format.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | Touches every skill that reads `todo.md` |
| Time | 1–2 weeks | |
| Skill requirements | Coordinated skill rewrites | |
| Dependencies | Buy-in from every downstream skill; scope creep beyond this epic | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Scope explosion — this epic becomes "rewrite the todo system" | High | High | Reject; wrong epic |
| Users lose ability to hand-edit `todo.md` casually | Med | High | None if strictly structured |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** Correct solution to the wrong problem. Belongs to a separate epic if ever done at all.

---

### Problem 10: Partial repo states (rebase/bisect/dirty worktree)

#### Solution A: Detect and refuse when repo is in a transient state

**Description:** At the top of every substrate call, check `git rev-parse --git-path rebase-merge` and `rebase-apply`, `BISECT_LOG`, and `MERGE_HEAD`. If any exists, emit a documented rapport (`GRAPH_TRANSIENT_STATE`) on stderr and exit non-zero. Consumers can choose to degrade (e.g. `/status` shows "board unavailable during rebase") or ignore. Documented in §9.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Standard git-state checks |
| Time | 4 hours | |
| Skill requirements | git internals awareness | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Legitimate use during rebase is now blocked | Low | Low | Env var `GRAPH_ALLOW_TRANSIENT=1` for callers who accept the risk |
| Users don't know what a "transient state" means | Low | Med | Rapport explains it |

**Viability verdict:** RECOMMENDED
**Rationale:** Cheap, honest, and turns a silent-bug class into an audible failure.

#### Solution B: Read whatever's on disk, document that results may be inconsistent

**Description:** Do nothing special. Users learn to distrust output mid-rebase.

**Viability verdict:** NOT RECOMMENDED
**Rationale:** Status-quo silent-corruption path; scrutiny raised it precisely to prevent this.

---

### Problem 11: Worktree topology unaddressed

#### Solution A: Primary-tree-only, explicitly documented

**Description:** The substrate reads only the tree it is invoked from (typically the primary worktree). It does not aggregate across worktrees. Consumers running inside a `.claude/worktrees/*` worktree see that worktree's state, not the merged view. Document as one sentence in §5 of the brainstorm. Accepts that `/status` inside a worktree shows the worktree's local view — which matches how developers already reason about worktrees.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | None | Explicit non-behaviour |
| Time | 30 minutes to document | |
| Skill requirements | None | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| `/reconcile` (if it becomes a consumer) genuinely needs cross-worktree view | Med | Med | Add `--include-worktrees` flag as a v2 feature when needed |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §8 recommendation #6. Simplest resolvable answer that matches existing developer mental model.

#### Solution B: Aggregate all worktrees by default

**Description:** Walk `git worktree list` and merge results across all worktrees.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med-High | Merge semantics, conflict resolution across worktrees |
| Time | 3–5 days | |
| Skill requirements | git worktree internals | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Merge semantics ambiguous when two worktrees have divergent versions of the same story | High | High | No good answer |
| Latency compounds by N worktrees | Med | High | None free |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** Buys a use case nobody has asked for at high complexity cost.

---

### Problem 12: Single-consumer capture

**Solution:** Addressed by Problem 2 Solution A. Naming a second consumer *before* S01 opens is the only real mitigation.

---

### Problem 13: Story order — API before consumer

#### Solution A: Reorder to interleave query API design with consumer port

**Description:** New story sequence:
- **S01 — Library skeleton & extraction** (unchanged)
- **S02 — Predicate grammar spec + minimal query API stub** (grammar written; API implements only what `/status` and the second consumer need in S03)
- **S03 — Concurrent port of `/status` and second consumer** (both feed back into S02's API surface)
- **S04 — Validation split into `/validate-board`, wired into `/commit` with bypass**
- **S05 — Frontmatter templates**
- **S06 — Backfill seed pass** (new — per Problem 5 Solution A)

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Reordering, no new invention |
| Time | 0 (redistribution of existing work) + S06 adds 2–4 days | |
| Skill requirements | Product sequencing judgement | |
| Dependencies | Problem 2 Solution A (second consumer named); Problem 7 (grammar) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| S03 becomes too large by porting two consumers | Med | Med | Split into S03a and S03b if it grows past 5 days |
| S02 stubs don't cover what S03 needs, forcing rework | Low | Med | Grammar spec forces the shape before code |

**Viability verdict:** RECOMMENDED
**Rationale:** Scrutiny §8 recommendation #2. Trivial to adopt; large structural benefit.

---

### Problem 14: Skill/Agent nodes as `id, path` only

#### Solution A: Add `title` and `description` to Skill/Agent nodes

**Description:** Extract the `description:` field from each skill/agent's frontmatter (they all have one — visible in the skill list). Node fields become `(id, path, title, description)`. Consumers that want to render human-readable output can do so without re-reading the skill file. Resolves Open Decision #4.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Two more frontmatter fields to extract |
| Time | 2 hours during S01 | |
| Skill requirements | Same as S01 | |
| Dependencies | None | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Description strings vary in length; JSON output grows | Low | Med | Accept — still small relative to board size |
| Some skills lack a description | Low | Low | Fall back to empty string; graph::query still works |

**Viability verdict:** RECOMMENDED
**Rationale:** Two hours to fix a documented usability hole. No reason to defer.

---

### Problem 15: No API versioning story

#### Solution A: Version the CLI + emit `_meta` in every response

**Description:** Every JSON response carries `"_meta": {"api_version": "1.0"}`. CLI accepts `--api=1` to lock the version. New API versions bump the version and may add/remove fields. v1.x is additive-only; v2 may break. Documented policy in the substrate skill README.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | JSON metadata + policy statement |
| Time | 2 hours during S02 | |
| Skill requirements | None | |
| Dependencies | Problem 7 (grammar) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Version noise pollutes every JSON output | Low | Certain | Accept |
| No consumer ever pins a version | Low | High | Fine — pinning is optional |

**Viability verdict:** RECOMMENDED
**Rationale:** Cheap insurance against silent breakage in year 2.

---

### Problem 16: `/commit` hook composability

#### Solution A: Publish a documented hook-ordering contract for `/commit`

**Description:** Define in `/commit`'s skill README: hooks run in alphabetical order of hook name; each hook may `exit 0` (pass), `exit 1` (block), or `exit 2` (skip remaining hooks). `/validate-board` registers itself. `/lgtm` propagates the same environment (including bypass env vars) when it invokes `/commit`. Test explicitly that `/lgtm` + `/validate-board` interact correctly.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Modifies `/commit` skill, not just this epic |
| Time | 1 day during S04 | |
| Skill requirements | Familiarity with `/commit` and `/lgtm` implementations | |
| Dependencies | Problem 3 Solution A | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Changes to `/commit` skill scope creep | Med | Med | Timebox to what this epic needs |
| Future hooks conflict on ordering | Low | Low | Alphabetical is deterministic if boring |

**Viability verdict:** VIABLE
**Rationale:** Addresses the blind spot without overreaching. Could also be deferred to a separate skill-lifecycle epic if it grows.

---

### Problem 17: PROJECT_SUMMARY.md is empty

#### Solution A: Accept as v1 non-consideration, document explicitly

**Description:** In §5 of the brainstorm, add one line: "PROJECT_SUMMARY.md is included structurally as a node but not consumed for semantic content in v1. Consumers wanting project context should treat this node as a stub." No code change.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | None | Documentation |
| Time | 15 minutes | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| A consumer expects semantic content and silently gets nothing | Low | Low | Explicit non-goal in doc |

**Viability verdict:** RECOMMENDED
**Rationale:** Right-sized response. Filling PROJECT_SUMMARY.md is a separate project concern.

---

### Problem 18: Validation and extraction share code paths

**Solution:** Addressed by Problem 3 Solution A. Splitting the skills separates the code paths.

---

## 3. COMPARATIVE SUMMARY

| Problem | Best solution | Effort | Risk level | Confidence |
|---------|--------------|--------|------------|------------|
| 1. Unmeasured latency | A: Prototype-and-measure spike | 4–8 hours | Low | High |
| 2. `/status` wrong forcing function | A: Name second consumer | 4–8h decide + 3–5d added port | Med | High |
| 3. Validation bundled | A: Split into `/validate-board` | 1 day | Low | High |
| 4. E20 collision | A: Path-prefix boundary + lint | 1–2 days | Med | Med |
| 5. Anemic graph | A + B: Backfill sweep + `/commit` hints | 2–4 days + 4h | Med | Med |
| 6. Shell packaging | A: Typed helper functions | 1 day | Low | High |
| 7. Predicate syntax | A: Half-page grammar appendix | 1 day | Low | High |
| 8. Validation bypass | A: `--no-validate` + env var | 4 hours | Low | High |
| 9. `TodoEntry` identity | A: Composite `(board_ref, hash)` + fallback | 1–2 days | Med | Med |
| 10. Partial repo states | A: Detect and refuse | 4 hours | Low | High |
| 11. Worktree topology | A: Primary-tree-only, documented | 30 min | Low | High |
| 12. Single-consumer capture | (via Problem 2A) | (included) | Med | High |
| 13. Story order | A: Reorder + add S06 | 0 + 2–4d for S06 | Low | High |
| 14. Skill/Agent metadata | A: Add title, description | 2 hours | Low | High |
| 15. No API versioning | A: `_meta.api_version` | 2 hours | Low | High |
| 16. `/commit` composability | A: Hook-ordering contract | 1 day | Med | Med |
| 17. Empty PROJECT_SUMMARY | A: Document non-consumption | 15 min | Low | High |
| 18. Validation/extraction coupled | (via Problem 3A) | (included) | Low | High |

---

## 4. OVERALL EFFORT ASSESSMENT

**Total effort to resolve all problems** (assuming recommended solutions across the whole epic):

| Scenario | Effort estimate | Assumptions |
|----------|----------------|-------------|
| Optimistic | 3 weeks | Second consumer is `/impact` and lands in ~3 days; backfill sweep produces clean edges on first pass; no `/commit` skill rewrites beyond hook wiring |
| Realistic  | 5–6 weeks | Second consumer needs iteration; backfill needs a second pass after human review; `/commit` hook-ordering contract requires a small skill refactor; measurement reveals latency needs a soft cache |
| Pessimistic | 8–10 weeks | Second consumer forces an API redesign mid-S03; backfill accuracy is poor so edges need manual sweep; commit-hook bypass rollout hits `/lgtm` interaction bugs; worktree "primary-tree-only" answer proves inadequate and a follow-up needed |

**Biggest effort drivers:**
- Second-consumer port (Problem 2 Solution A): 3–5 days for a co-designed port of `/impact` or `/reconcile` optimisation.
- Backfill seed pass (Problem 5 Solution A): 2–4 days of grep-heuristics + human review.
- Concurrent port in S03: multiplies the acceptance-test surface.

**Biggest risk drivers:**
- Second-consumer choice: the wrong pick reproduces the `/status`-only failure mode with more code.
- Backfill accuracy: false-positive edges are worse than no edges (they silently mislead queries).
- `/commit` hook rewiring: touches a shared resource used by every skill that commits.
- `TodoEntry` identity: any weakness here bleeds into `/do`, `/dooo`, `/reconcile` — high-blast-radius bug class.

---

## 5. UNRESOLVED PROBLEMS

| Problem | Reason unresolved | Recommended action |
|---------|------------------|--------------------|
| 4. E20 collision | Truly resolvable only when E20 has enough shape to co-sign boundaries; Solution A works unilaterally but symmetry depends on E20. | Investigate further — publish the boundary from this side, revisit when E20 opens implementation stories. |
| 17. Empty PROJECT_SUMMARY | Not a substrate problem; a project-context problem. | Accept — document as a non-consideration for v1. |

All other problems have a viable solution path in Section 2.

---

## 6. RECOMMENDED RESOLUTION SEQUENCE

Order accounts for dependencies, cheapest-first risk reduction, and the fact that several answers must land in the brainstorm doc *before* S01 opens.

**Before S01 opens (design-time fixes to the brainstorm doc):**
1. **Problem 1** — Prototype-and-measure spike. Cheap, empirical, resets §7. Also validates the extractor sketch that S01 will inherit.
2. **Problem 2** — Name and commit second consumer (recommend `/impact`). Every downstream story depends on this choice.
3. **Problem 7** — Write predicate grammar appendix. Feeds S02.
4. **Problem 11** — Document worktree semantics (30 min).
5. **Problem 17** — Document PROJECT_SUMMARY non-consumption (15 min).
6. **Problem 13** — Reorder stories (S01, S02 spec, S03 concurrent port, S04 validation-split, S05 templates, S06 backfill).
7. **Problem 4** — Publish path-prefix boundary and reserved-word list. Can happen in parallel with the above.

**During S01 (extraction library):**
8. **Problem 9** — Implement composite `TodoEntry` identity (load-bearing for S03 consumers).
9. **Problem 14** — Extract skill/agent title + description into node payload.
10. **Problem 10** — Add transient-state detection at every entry point.

**During S02 (query API):**
11. **Problem 6** — Ship `graph.sh` typed helpers alongside the CLI.
12. **Problem 15** — Add `_meta.api_version` to every JSON response.

**During S03 (concurrent port of `/status` and second consumer):**
- No new problems — this story validates the API against both consumers.

**During S04 (validation split):**
13. **Problem 3** — Create `/validate-board` skill; wire `/commit` to invoke it.
14. **Problem 8** — Ship `--no-validate` and `SKIP_VALIDATE=1` before enabling the hook.
15. **Problem 16** — Publish hook-ordering contract; verify `/lgtm` compatibility.
16. **Problem 18** — Falls out of Problem 3.

**During S05 & S06:**
17. **Problem 5** — S05 documents optional keys; S06 does the backfill sweep + adds soft `/commit` warnings.
18. **Problem 12** — Falls out of Problem 2 having been resolved at the top.

---

## 7. VERDICT

**Resolvability:** TRACTABLE

> All 18 problems have viable solution paths; 16 are RECOMMENDED at concrete effort of a few hours to a few days each, and the two that remain partly unresolved (E20 boundary symmetry, empty PROJECT_SUMMARY) can be honestly deferred without blocking v1. The realistic aggregate is 5–6 weeks — modestly more than the original proposal implies, but the addition (second consumer, backfill sweep, grammar spec, validation split, bypass, worktree/transient-state semantics) is exactly the design work whose absence made the proposal CAUTIOUS in scrutiny. Proceed on the condition that Problems 1, 2, 7, 11, 13, and 17 are resolved *in the brainstorm doc before S01 opens* — otherwise the epic ships with the same structural weaknesses scrutiny flagged.

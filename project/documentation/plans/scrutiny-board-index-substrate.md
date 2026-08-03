# SCRUTINY ASSESSMENT

**Proposal:** Build a shell-callable query library over `project/*` board and documentation artifacts, delivered as a substrate with no user-facing command in v1, validated on every `/commit`, and proven by refactoring `/status` to consume it.

---

## 1. CORE ASSUMPTIONS

| # | Assumption | Challenge |
|---|------------|-----------|
| 1 | A live filesystem walk on every call is "fast enough" at ~50–200ms (§7, §9). | This budget is stated without measurement. `/status` today is a single read; if it now spawns a shell library that walks epics/stories/tasks/plans/summaries/examples/todo/skills/agents and parses frontmatter in bash-invoked JSON, 50ms is optimistic and 200ms is user-perceptible latency added to a command whose whole point is instant feedback. The number is a guess dressed as a spec. |
| 2 | `/status` is a sufficient forcing function to prove the substrate (§4, §12). | `/status` is a *tree render* — the least graph-shaped query imaginable. It exercises `contains` edges and node metadata; it does not exercise `mentions_skill`, `depends_on`, `orphan=true`, `neighbors --depth=2`, or predicate composition. Passing the `/status` acceptance test proves the extractor works, not that the *query API* (§8) is well-designed. The "acceptance test" is under-fit to the surface it claims to validate. |
| 3 | Commit-time validation is a "meaningful role" for the substrate even without persistence (§7). | Validation is a separable concern that happens to reuse the extractor. Bundling it into the substrate skill conflates *reading* the board with *policing* it, which is exactly the conflation §10 warns against ("structural integrity" vs "completeness"). Open decision #2 (§13) already flags this — the answer is probably "yes, split" and the proposal has not committed. |
| 4 | Distinctness from E20 holds because one graphs code and the other graphs the board (§3). | The disclaimer is naming, not architecture. Both produce a queryable graph of project artifacts, both will grow a predicate language, both will want neighbor traversal. When E20 lands Kuzu and someone asks "give me all stories that touch function F," the pressure to fuse will be immediate. The "naming rule" (§3) reserves a term but does not prevent structural collision six months in. |
| 5 | Tolerant frontmatter + optional edges will produce a useful graph (§6, §10). | §12 already concedes "the graph is anemic until authors backfill" with "no forcing function." The proposal simultaneously claims the substrate is valuable *and* that its most differentiating edges (`mentions_skill`, `depends_on`, `parent_doc`) will be sparsely populated. Consumers built on sparse edges either degrade silently or push authors to fill fields — which is enforcement by another name. |
| 6 | A shell library with JSON stdout is the right packaging (§8). | Every consumer will re-parse JSON in bash. Predicate strings (`"type=Story AND status=Passed"`) are constructed as shell strings — quoting, escaping, and injection surface all live in the caller. Open decision #1 (§13) flags this and is not answered. |

---

## 2. KEY QUESTIONS

1. **What query does `/status` actually issue that could not be a 20-line `find | xargs grep` today?** If the answer is "the same walk, just wrapped," the substrate is a refactor with a marketing name. Show the concrete `/status` call and the concrete equivalent without the substrate, side by side, and defend the delta.
2. **When commit-time validation fails on a legitimately in-progress commit (e.g. a story renamed mid-flight, a task added without yet updating its parent's `tasks:` list), what is the escape hatch?** §12 mentions "grace period or feature flag" as an afterthought. Without a designed bypass, the first week of rollout will train users to hate the substrate.
3. **What is the second consumer, named and committed, before S01 starts?** The proposal says "success looks like at least one new skill built on the substrate within one epic of shipping" (§12) but does not name it. Without a named second consumer, the S03 acceptance test locks in an API shaped only by tree-rendering.
4. **How is `graph::query "type=Story AND status=Passed"` parsed, and what happens with `status="In Progress"` (a value containing a space and a status this project uses)?** The predicate syntax is described as "intentionally simple" (§8) but not specified. Escaping, case sensitivity, list-valued fields (`mentions_skills` is an array), and negation are all undefined.
5. **What is the `TodoEntry` identity story, concretely?** Open decision #5 (§13) surfaces it but does not resolve it. Line hash breaks on any edit; position breaks on reorder; content breaks on both. The `queued_as` edge is one of the most operationally important edges on the whole graph — `/do`, `/reconcile`, `/dooo` all depend on it — and its stability is unspecified.
6. **How does the substrate handle a partial repo state during `git rebase`, `git bisect`, or a dirty worktree with unstaged renames?** Live-walk means every filesystem transient becomes a graph transient. What does `/status` show mid-rebase?
7. **Where does `.claude/worktrees/*` fit?** The current `git status` in this session shows worktrees exist and are ignored — but stories and tasks are actively edited inside them. Does the substrate read the primary tree only, or does it aggregate across worktrees? Silence on this is a blind spot given how heavily the workflow uses worktrees.

---

## 3. RISK REGISTER

| Risk | Severity | Likelihood | Notes |
|------|----------|------------|-------|
| Single-consumer capture: `/status` ships, no second consumer materializes, substrate becomes overhead. | High | Med | §12 acknowledges but does not mitigate. "Within one epic" is a soft deadline with no gate. |
| API shaped by wrong consumer: `/status` (tree render) is not graph-shaped, so S01–S03 lock in a schema that later consumers must fight. | High | Med-High | The provisional decomposition (§11) puts the query API (S02) *before* the acceptance-test consumer (S03), so the API is designed in the dark. |
| Commit-time validation friction: legitimate in-progress commits blocked, users disable the hook or bypass it, trust erodes. | High | High | Every project that has tried commit-blocking structural validators has hit this. "Rollout needs a grace period" (§12) is a plan-to-have-a-plan. |
| Latency compounding: `/status` at 200ms is tolerable; `/status` called from `/dooo` in a loop, or `graph::neighbors --depth=2` on a 300-task board, is not. | Med | Med | §9 defers "until a consumer complains" — but the natural consumers (`/dooo`, `/reconcile`) *are* the ones that will complain first. |
| E20 collision on second contact: when E20 wants to link functions to tasks (§3 concedes this direction), two overlapping graph substrates coexist with unclear ownership. | Med | Med | The unidirectional-consumption claim ("reverse is not planned") is aspirational, not enforced. |
| Anemic-graph trap: `mentions_skills`, `depends_on`, `parent_doc` are optional and rarely filled, so the differentiating queries return near-empty results, making the substrate look useless. | Med | High | §12 concedes this directly. There is no plan to seed the graph on existing artifacts. |
| Predicate injection / quoting bugs in shell callers. | Low-Med | Med | JSON output on stdout is safe; predicate strings on stdin are not. |
| `todo.md` line-hash identity churns whenever anyone rewrites a line, silently detaching `queued_as` edges. | Med | High | Open decision #5, unresolved. |
| Validation and extraction share code paths, so a bug in one breaks both. | Low | Med | Coupling is a consequence of bundling per §7. |

---

## 4. GENUINE STRENGTHS

- **Sharp non-goals (§2, §3).** Explicitly disclaiming code topology, persistence, embeddings, and `/reconcile` replacement is disciplined and unusually clear for a v1 proposal. This is genuinely good scoping hygiene.
- **Idempotent live-walk (§9).** Choosing no persistence eliminates a whole class of cache-invalidation bugs that would otherwise dominate the epic. The tradeoff is honest and consciously made.
- **Committed acceptance-test consumer at all (§4).** Most substrate proposals ship the substrate and hope. Naming `/status` up front — even if it is the wrong consumer (see risks) — is better than not naming one.
- **Tolerant frontmatter posture (§6, §10).** Refusing to enforce optional keys avoids the classic "linter epic" death spiral. The tradeoff is anemia, which the author flags.
- **Author self-assessment (§12) is unusually candid.** It surfaces the single-consumer risk, the anemic-graph problem, and the validation-friction problem without hedging. This is rare and load-bearing for trusting the rest of the doc.

---

## 5. BLIND SPOTS

- **Worktree topology.** The current repo actively uses `.claude/worktrees/` (visible in `git status`). Stories and tasks are edited across worktrees before merging. The substrate is silent on whether it reads the primary tree, aggregates worktrees, or ignores them — but `/status` from inside a worktree is a real use case *right now*.
- **The `/reconcile` overlap is deeper than §2 admits.** `/reconcile` already walks the board, cross-checks against git, and rewrites todo.md. It is effectively an ad-hoc, unindexed version of this substrate. §2 says the substrate "may *power* future `/reconcile` optimizations" — but the honest framing is that `/reconcile` is the *first* consumer that would actually stress-test the graph API, and it is not on the S03 slate.
- **No cost estimate for backfilling frontmatter.** If `depends_on` and `mentions_skills` are the differentiating edges, someone has to add them to hundreds of existing files, or they stay anemic forever. There is no S06 "backfill" story and no mention of who pays that cost.
- **`Skill` and `Agent` nodes as "id, path only" (§5).** Open decision #4 flags this. A `mentions_skill=reconcile` query that returns `{"id":"reconcile","path":"..."}` is not useful to a human-facing consumer. Either the nodes carry description/metadata, or every consumer re-reads the skill file — which is exactly the redundancy the substrate exists to eliminate.
- **No versioning story for the query API.** The library will grow. S02's predicate syntax is v1; if S07 adds `OR` or negation, existing consumers may break. Nothing in §8 addresses evolution.
- **`/commit` is a shared resource.** Wiring validation into `/commit` (§7) means every future skill that wants a commit hook must coordinate. There is no discussion of hook ordering, composability, or failure-mode interaction with `/lgtm`, which chains through `/commit`.
- **PROJECT_SUMMARY.md being empty (§12).** Flagged but not confronted: this means the "semantic root" node has no content, and any query that traverses toward "project context" hits an empty file. This is not a substrate bug — it is a substrate-doesn't-help-yet condition that should shape which consumers are viable in v1.

---

## 6. FEASIBILITY ASSESSMENT

**Score: 6 / 10**

**Rationale:** The technical core — walk `project/*`, extract nodes and edges from frontmatter, expose shell queries — is straightforward and the non-goals are well-drawn. But two structural problems drag the score: (1) `/status` is a tree render, not a graph query, so the S01–S03 sequence designs the query API in the dark and validates it against the wrong shape; (2) the anemic-graph problem is conceded but unaddressed, meaning the substrate's differentiating queries will return empty until an unspecified backfill happens. The proposal is workable but bets on a proof-of-value path that does not actually prove value.

**Required conditions for this to succeed:**
- Name and commit to a *second* consumer before S01 begins — one that exercises `mentions_skill`, `depends_on`, or `orphan=true`. Candidates: `/reconcile` optimization, an `/impact` skill, or `/dooo` dependency awareness.
- Split validation into its own skill (`/validate-board` or similar) invoked *by* `/commit`, not bundled into the substrate. Resolves open decision #2 and decouples the two failure modes.
- Specify the predicate syntax formally (grammar, escaping, list values, negation) before S02 starts.
- Resolve `TodoEntry` identity before S01 ships, because `queued_as` is load-bearing for downstream skills.
- Design a documented bypass for commit-time validation (env var, `--no-validate` flag) *before* enabling the hook, not after users complain.
- Decide worktree semantics explicitly.

---

## 7. VERDICT

**Overall judgment:** CAUTIOUS

> The proposal is coherent, well-scoped, and honestly self-critical, but it commits to the wrong forcing function and defers the two hardest problems (anemic edges, validation friction) into the "author self-assessment" bucket instead of designing solutions. Ship this only after a second consumer is named and validation is decoupled from the substrate — otherwise you get a well-built library that renders trees and blocks commits, and nothing else.

---

## 8. RECOMMENDED NEXT STEPS

1. **Name the second consumer in writing** and add it to §4 as a co-equal acceptance test. Prefer `/reconcile` optimization or an `/impact` skill — something that actually exercises graph traversal, not tree rendering. If no second consumer can be named, that is the signal to defer the epic, not proceed with it.
2. **Reorder the story decomposition** so the query API (S02) is designed *against* both consumers, not just `/status`. S03 should be "port both consumers concurrently," and only then is the API considered validated.
3. **Split validation into a separate story and a separate skill.** Let `/commit` invoke it, but do not conflate "read the board" with "police the board." Resolves open decision #2 explicitly.
4. **Prototype the extractor in one afternoon** and measure real latency on the current board (which is small but growing). Replace the 50–200ms guess in §7 with a number. If the measured number is over 150ms cold, revisit persistence-as-optional-cache before committing to §9.
5. **Write the predicate grammar** in a half-page appendix to §8 before S02 opens. Include escaping, list-valued fields, and a stance on negation and `OR`.
6. **Decide worktree semantics** — one sentence in §5 — before S01 opens. This project uses worktrees heavily; silence will produce silently wrong results.
7. **Design the validation bypass** (env var or flag) as part of S04, not as a follow-up. Document it in the story acceptance criteria.

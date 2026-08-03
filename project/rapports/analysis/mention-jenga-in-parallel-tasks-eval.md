# Evaluation Rapport: mention-jenga-in-parallel-tasks

## Goal
Update `parallel-tasks.md` to mention the `/jenga` skill where relevant, so readers understand the full picture of parallel task execution in the JengaAgent workflow.

## References
`project/.wiki/concepts/parallel-tasks.md`, `.agents/skills/jenga/SKILL.md`

## Observations

### `parallel-tasks.md`
The page is well-structured and thoroughly explains `/dooo` as the parallel orchestrator. It covers when parallelism applies, what makes a task parallelisable, post-parallel reconciliation, and sub-agent session mechanics. However, `/jenga` — which also executes independent tasks in parallel as part of its Phase 4 — is entirely absent. A reader of this page has no idea that a separate skill exists which automates the same parallel execution pattern across the *entire board* without manual selection. The distinction between "I want to hand-pick which tasks run in parallel" (`/dooo`) and "I want everything eligible on the board to run automatically" (`/jenga`) is never drawn.

### `.agents/skills/jenga/SKILL.md`
`/jenga` Phase 4 explicitly groups tasks by independence and launches them as background sub-agents simultaneously — the same mechanism `/dooo` uses. The key differentiator is automation level: `/dooo` is interactive (asks the user before each parallel batch), while `/jenga` is hands-free (decomposes, queues, and executes everything without prompts). This distinction is directly relevant to anyone deciding how to run parallel tasks and belongs in `parallel-tasks.md`.

## Gaps & Issues
- **Missing `/jenga` entirely** — the page never mentions `/jenga` even though it performs parallel task execution as a core part of its Phase 4 loop.
- **No comparison between `/dooo` and `/jenga`** — readers cannot make an informed choice between the two. `/dooo` is interactive and selective; `/jenga` is fully automated and board-wide. This distinction is absent.
- **"When Not to Use `/dooo`" section is incomplete** — it doesn't mention that `/jenga` is the appropriate alternative when you want full-board automation rather than task-by-task selection.
- **No mention of `/jenga`'s parallel mechanics** — `/jenga` also uses background sub-agents and checks for dependency resolution, which reinforces the same concepts the page already explains.

## Score
**Score**: 3/5
**Justification**: The page covers `/dooo` thoroughly but omits `/jenga` entirely, leaving a significant gap for users who need to choose between interactive parallel execution and fully automated board-wide parallel execution.

## Summary
`parallel-tasks.md` is a solid reference for `/dooo` but fails to acknowledge `/jenga`, which shares the same parallel execution model. Without a comparison of the two skills, users lack the context to choose the right tool. Adding a section or callout that positions `/jenga` as the hands-free, full-board alternative to `/dooo` would complete the page's coverage of parallel task execution in JengaAgent.

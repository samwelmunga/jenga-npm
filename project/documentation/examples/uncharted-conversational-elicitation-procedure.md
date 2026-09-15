# Uncharted's Conversational Elicitation Procedure

## What it is

`/uncharted`'s current human-in-the-loop procedure for building understanding of a
system/service with no board provenance (`onboard`'s default mode, and
`segment --mode investigate`). It runs in two stages: **Directory Triage** (once, up
front) and a per-candidate **Convergence Loop**. The output is coarse-tier graph
nodes/edges in `project/knowledge-graph/graph.json`, plus a board item — not the
fixed 7-heading Understanding Document the deterministic (`--legacy`/`delivery`)
pipeline produces.

## Why it exists

Two problems it is explicitly designed to defend against:

- **Confirmation fatigue** — asking the user to confirm every single finding would
  exhaust their attention on a large codebase. Solved by *risk-weighted gating*:
  low-risk, high-confidence findings auto-accept (but are still logged as
  auditable), and only high-uncertainty or high-impact findings force a prompt.
- **Fabricated confidence** — the Human-Oracle-Availability Limitation documents
  that the person answering may not actually know the code either, and a
  confidently wrong answer is undetectable by this flow. The documented mitigation
  is to write hedged answers honestly into the node's `description` rather than
  rounding them up to confirmed.

## How it works (core mechanics)

1. **Directory Triage** — a deterministic pattern/gitignore pass (`directory-triage.sh`)
   classifies candidate directories as `ignored`, then a judgement pass proposes
   `exclude`/`generalize` for the remainder. Both lists are confirmed together in
   **one** gate before any investigation starts.
2. **Convergence Loop**, per surviving candidate:
   - Dispatch developer + tester Investigative Mode traces (two vantage points).
   - Draft a candidate node/edge from both traces.
   - **Risk-weighted gating** decides whether this specific finding needs a prompt
     at all — driven entirely by the finding's own uncertainty/impact (an inference
     the traces don't fully support, a structurally central node, or a node the
     Human-Oracle-Availability Limitation already flagged).
   - If gated, confirm/correct in rounds, capped (`elicitation-state.sh turn`),
     with an explicit unresolved-node choice once the cap is hit.
   - On convergence, write the node/edge and checkpoint immediately.

**What decides how much scrutiny a candidate gets today:** the finding's own
risk/impact, evaluated *after* the trace already exists. Nothing in either stage
asks the user, up front, how well *they themselves* already know the service —
that signal is never collected or used to scale verification strictness for the
rest of the run.

## When to use it (and when not)

Documented as a complementary path "for codebases where *some* human context
exists" — explicitly not a fix for the hardest, genuinely zero-oracle case, where
the deterministic pipeline (`onboard --legacy`, `segment --mode delivery`) remains
the tool of record.

## The gap this goal targets

The attached procedure diagram proposes a structural addition this loop doesn't
have:

1. **An upfront familiarity check** — "Are you familiar with this service/segment?"
   (Yes / A little / No) — used to set a **verification depth** for the rest of
   that service's investigation (shallow verification / some verification / strict
   verification as little as possible from the user). Today, verification depth is
   decided per-finding by risk-weighted gating, never by the human's own stated
   prior familiarity with the target as a whole.
2. **A standard, reusable question set split by node kind**, rather than an
   open-ended "propose understanding, ask to confirm/correct":
   - **External nodes** (dependencies/consumers outside the service): what are
     these nodes, what do they do, is the service producing to or consuming from
     each one, and who is the producer/consumer.
   - **Internal/service node itself**: what is this, what does it do, who consumes
     the service.

Neither the Directory Triage pass nor the Convergence Loop currently names or
distinguishes an internal-vs-external question template, and neither collects a
familiarity signal before choosing how hard to push for confirmation.

# Knowledge Graph — Coarse Graph STUB Schema

> **STUB — this is not E20_S01's schema.**
>
> This file defines a minimal, intentionally throwaway coarse-graph node/edge schema so that
> **E20_S08** ("Interactive Architecture Elicitation — Uncharted Integration") can be prototyped
> without waiting on **E20_S01** (the epic's real, eventual node/edge schema and JSON Schema
> publication under `project/knowledge-graph/graph.json`). E20_S01 has no committed landing
> schedule; this stub exists purely to unblock E20_S08's other tasks in the meantime.
>
> **This schema will be replaced wholesale once E20_S01 lands.** Nothing that depends on this file
> should assume field stability, forward compatibility, or migration support — when E20_S01's real
> schema is published, this file should be deleted (or reduced to a pointer at the real schema) and
> every consumer of it re-pointed. Do not extend this stub with new fields expecting them to survive
> the swap; keep it minimal.

---

## Node Schema

| Field         | Type                | Required | Description                                                                 |
|---------------|---------------------|----------|-------------------------------------------------------------------------------|
| `id`          | string              | yes      | Unique node identifier within the coarse graph.                              |
| `type`        | string              | yes      | Node kind (e.g. `service`, `module`, `function`, `data-type`). Free-text in the stub — E20_S01 may formalize an enum. |
| `label`       | string              | yes      | Short human-readable name for the node.                                      |
| `description` | string              | yes      | Free-text description of what the node represents.                          |
| `source`      | `human` \| `ast`    | yes      | Provenance of this node — see **Provenance Field** below.                    |
| `status`      | `active` \| `superseded` | no  | Present only once a conflict has been resolved against this node — see **Evidence-Wins Conflict Rule** below. Absence means `active`. |
| `superseded_by` | string (node `id`) | no    | Required when `status: superseded`. Points at the node that superseded this one. |

## Edge Schema

| Field         | Type   | Required | Description                                             |
|---------------|--------|----------|----------------------------------------------------------|
| `id`          | string | yes      | Unique edge identifier within the coarse graph.          |
| `from`        | string | yes      | Source node `id`.                                        |
| `to`          | string | yes      | Target node `id`.                                        |
| `type`        | string | yes      | Edge kind (e.g. `depends-on`, `calls`, `flows-to`). Free-text in the stub. |
| `description` | string | yes      | Free-text description of the relationship.                |

---

## Provenance Field — `source: human | ast`

Every stub node declares how it came to exist:

- **`human`** — written by a human-in-the-loop conversational elicitation session (the flow E20_S08
  is building: propose understanding, ask the user to confirm or correct, write the resulting node).
  This is a **coarse** node: it reflects a person's understanding of the code, not mechanical
  extraction.
- **`ast`** — written by an automated, AST-derived extraction pipeline. This is a **fine-grained**
  node: it reflects what the code mechanically, verifiably does. No such pipeline exists yet as of
  this stub (it is scoped to E20_S02's prospective AST-diff maintenance work); the `ast` value is
  defined here so the conflict rule below has both sides of the conflict to refer to from day one.

There is no third value. A node's `source` is fixed at creation time and is not itself mutated by
conflict resolution — conflict resolution only ever adds `status`/`superseded_by` to a `human` node
(see below); it never rewrites a node's `source`.

## Evidence-Wins Conflict Rule

**Trigger:** a `human`-sourced coarse node and a (future) `ast`-sourced fine node both describe the
same underlying code, and they disagree — e.g. a human described a module's purpose one way during
elicitation, and a later AST-derived extraction of the same code area produces a materially
different description or classification.

**Rule:** the AST-derived (`source: ast`) entry takes precedence as the authoritative description.
The human-authored (`source: human`) entry is **not deleted**. Instead:

1. The human node's `status` field is set to `superseded`.
2. The human node's `superseded_by` field is set to the `id` of the AST-derived node that
   superseded it.
3. The AST-derived node is written normally (`source: ast`, no `status` field — it is the new
   active, authoritative entry for that piece of code).

This preserves the human node as a retained, annotated rationale/history layer rather than silently
discarding a person's prior understanding — useful for later review of *why* a human once believed
something different, and for detecting elicitation sessions that were confidently wrong.

**Worked example:**

Before conflict resolution — a human-authored coarse node:

```json
{
  "id": "node-042",
  "type": "module",
  "label": "billing-worker",
  "description": "Background job that retries failed charges.",
  "source": "human"
}
```

After a later AST-derived extraction disagrees (the module actually reconciles ledger entries, it
does not retry charges) and the conflict is resolved:

```json
{
  "id": "node-042",
  "type": "module",
  "label": "billing-worker",
  "description": "Background job that retries failed charges.",
  "source": "human",
  "status": "superseded",
  "superseded_by": "node-091"
}
```

```json
{
  "id": "node-091",
  "type": "module",
  "label": "billing-worker",
  "description": "Background job that reconciles ledger entries against the payment provider.",
  "source": "ast"
}
```

`node-042` remains in the graph, readable, and traceable to what replaced it — it is superseded, not
gone.

---

## Relationship to `[ARCH]` Board Tagging

Board items generated by the E20_S08 elicitation flow that populate this stub schema are tagged
`[ARCH]` (see `templates/SCRUM_BOARD_SCHEMA.md`'s "Board Item Tag Conventions" section) rather than
`[SPIKE]` — this is durable architectural-inventory record-keeping, not bounded research.

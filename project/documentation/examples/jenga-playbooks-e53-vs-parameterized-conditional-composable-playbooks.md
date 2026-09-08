---
last_update: 2026-09-08
---

# Jenga's Existing "Playbook" Feature (E53) — Explained, and Compared to a Richer Playbook Idea

## 1. What it is

E53 (`Jenga Natural-Language Dispatcher & Playbooks`, story `E53_S02`, status `Passed with
remarks`) added a small, real feature: `/jenga` (the board orchestrator) can now accept free-text
intent as its argument, and when that intent spans more than one skill, it can propose a
**pre-authored, named chain of skills** — a *playbook* — for the user to confirm before any of it
runs.

A playbook is a JSON data file. The one shipped example, `skills/jenga/playbooks/brainstorm-to-mirror.json`:

```json
{
  "id": "brainstorm-to-mirror",
  "name": "Idea to Public Release",
  "description": "Takes a rough idea all the way from planning through implementation, committing, and a public mirror release -- the canonical end-to-end Jenga workflow chain.",
  "keywords": ["idea to release", "plan and ship", "full workflow", "..."],
  "examples": [
    "I have an idea, help me plan it, build it, and ship it",
    "let's go from a rough idea all the way to a public release"
  ],
  "steps": ["brainstorm", "todo", "do", "dev-done", "mirror-public"]
}
```

`steps` is the entire execution definition: an ordered list of **bare skill names**. Nothing else.

## 2. Why it exists

Before E53, `/jenga` (and `/route`) could match free text to exactly *one* skill. If your intent
actually spanned several skills ("take this idea all the way to a public release"), you'd either
have to know and type every command yourself, or the router would pick the single closest skill
and stop short. E53_S02 closes that gap for the specific case where a **known, pre-defined**
multi-skill shape exists — it does not attempt to compose arbitrary chains on the fly.

## 3. How it works

Four scripts under `skills/jenga/scripts/`, each doing one deterministic job:

1. **`load-playbooks.sh`** — scans `skills/jenga/playbooks/*.json` (skipping `schema.json`
   itself), validates each file against the schema, drops (with a stderr warning) any playbook
   missing a required field or referencing a skill that doesn't exist, and emits the surviving
   catalog as JSON.
2. **`match-playbook.sh`** — runs **only as a fallback**, after `/jenga`'s existing single-skill
   match already failed to produce a confident result. It runs the same three-pass heuristic
   `/route` uses for single-skill matching (keyword → example-similarity → description), but
   scoped to the playbook catalog. Output is one of `playbook_match`, `ambiguous`, or `no_match`.
3. **`render-playbook-confirmation.sh`** — turns a `playbook_match` into an editable, numbered,
   checked-by-default confirmation list, exactly like `/jenga`'s existing bare/`<ids>` confirmation
   UX. Nothing executes until the user confirms; `cancel` halts the whole `/jenga` invocation with
   zero steps run.
4. **`run-playbook-step.sh`** — a pure sequencing state machine (`init` → repeated `advance
   <state_file> passed|failed`). It tracks which step is current, which completed, and enforces
   that a `failed` outcome **halts the chain permanently** — a further `advance` against a halted
   state file is rejected outright (exit code 3), so there's no accidental silent resumption.

Critically, per `E53_S02_T04`'s wiring spec, each step is invoked "exactly as `/route`'s Step 6
already does for a single matched skill" — which means every step receives the *same* enriched
composite message built once from the original raw prompt. There is no per-step differentiation.

## 4. When to use it (today)

- You want a **named, reusable, pre-authored** multi-skill chain that a free-text prompt can
  trigger (e.g. "take this from idea to release").
- The chain is **linear and fixed** — always the same skills, in the same order, every time it
  runs.
- "Good enough" failure handling is: stop immediately, report what completed and what didn't.

## 5. The gap: a richer "Playbooks" idea, compared point-by-point

Separately, a different, NOT-yet-implemented idea was described: user-authored playbook files
where **each step carries its own bracketed natural-language instruction** —

```
-> /j.uncharted [AI search the codebase for specifically http-request related content]
-> /j.doc [Document the request/response of every call to a rapport file]
```

— motivated by both reusability *and* durability/shareability (checked into git, runnable by a
teammate without the author present), with two more requirements: real conditional branching, and
playbooks that can invoke other playbooks.

Here is what E53 does and doesn't cover, per requirement, grounded in the code above:

| Requirement | E53 today | Gap |
|---|---|---|
| Reusability (named, re-runnable chain) | ✅ Yes — that's the whole point of the JSON catalog | None |
| Durability/shareability (git-checked-in, teammate-runnable) | ✅ Yes — playbooks are files in `skills/jenga/playbooks/`, committed like any other source | Partial: only reachable via `/jenga`'s NL matching today, not a direct `j.playbook <id>` invocation — a teammate has to phrase a prompt the matcher recognizes, not name the playbook directly |
| Per-step parameterization / bracketed instructions | ❌ No | `steps` is `string[]` (bare skill names only) — the schema has no field for a per-step instruction, and the wiring passes the *same* composite message to every step. Closing this gap means adding a field (e.g. `steps: [{skill, instruction}]`) and changing the invocation wiring in `E53_S02_T04`'s logic to build a distinct message per step |
| Conditional / branching logic | ❌ No | `run-playbook-step.sh` only has one branch point: `passed` (continue) vs. `failed` (halt permanently, no retry, no alternate path). There's no way to express "if step 1 finds nothing, skip step 2" or "run step 3 only if step 1's result matches X" |
| Playbook-to-playbook composition | ❌ No | `steps` entries are validated against `skills/<name>/SKILL.md` existence only — there's no schema concept of a step that resolves to *another playbook file* instead of a skill, and no cycle/recursion handling exists because nothing calls back into `load-playbooks.sh`/`match-playbook.sh` from within a running chain |

**Bottom line:** E53 is real, shipped, and directly overlaps in *purpose* (named, reusable,
shareable multi-skill chains, confirm-before-execute, deterministic sequencing). It is a genuine
foundation — the catalog format, loader, and confirmation UX are all reusable as-is. But on the
three specific mechanics the newer idea needs (per-step parameters, conditionals, and playbook
composition), E53 has no support at all; those would be net-new schema fields and net-new
execution logic layered on top of `run-playbook-step.sh`'s current all-or-nothing linear model,
not something already lurking in the current implementation waiting to be turned on.

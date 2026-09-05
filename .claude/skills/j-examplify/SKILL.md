---
name: j:j-examplify
description: Polyfill alias of the examplify skill under a collision-safe directory name. Identical behavior to /examplify — Explains concepts, features, use cases, and patterns based on provided context — a description, scenario, code snippet, or file. Use when the user wants to understand what something is, how it works, when to use it, or wants a concrete example. Use when the bare /examplify form is shadowed by another tool's own built-in command of the same name.
keywords:
  - examplify
  - explain
  - example
  - how does
  - understand
  - j-examplify
  - polyfill
examples:
  - "explain how this works"
  - "give me an example of X"
  - "j-examplify"
---

# Concept Explainer

This skill is a literal-directory-name duplicate of `skills/examplify/`. It exists so that `/j-examplify` (and `j:j-examplify`) give a guaranteed-unshadowed way to reach the same flow as `/examplify`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/examplify` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh examplify` from `skills/examplify/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

If the context is unclear or too broad, ask one focused clarifying question before proceeding. Otherwise, infer and proceed.

Explain the concept by covering:

1. **What it is** — a plain-language definition
2. **Why it exists** — the problem it solves
3. **How it works** — core mechanics
4. **When to use it** — and when not to
5. **Example(s)** — grounded in the user's context; show a before/after when relevant

After delivering the explanation, save a copy to:
`project/documentation/examples/<concept_and_context>.md`

Derive the filename from the concept + context (lowercased, hyphenated). Tell the user where the file was saved.

## Follow-up

If further discussion reveals new information about the topic — a new use case, correction, or better example — ask the user:

> "That adds something new to what we covered — want me to update the saved file?"
1. Yes
2. No

If yes, append the new content under an `## Additional Notes` section. Do not overwrite the original.
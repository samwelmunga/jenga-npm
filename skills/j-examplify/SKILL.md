---
name: j.examplify
description: Explains concepts, features, use cases, and patterns based on provided context — a description, scenario, code snippet, or file. Use when the user wants to understand what something is, how it works, when to use it, or wants a concrete example.
keywords:
  - examplify
  - explain
  - example
  - how does
  - understand
  - j-examplify
examples:
  - "explain how this works"
  - "give me an example of X"
  - "j-examplify"
---

# Concept Explainer

`skills/j-examplify/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-examplify/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/examplify/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

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

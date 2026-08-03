---
name: examplify
description: Explains concepts, features, use cases, and patterns based on provided context — a description, scenario, code snippet, or file. Use when the user wants to understand what something is, how it works, when to use it, or wants a concrete example.
keywords:
  - examplify
  - explain
  - example
  - how does
  - understand
examples:
  - "explain how this works"
  - "give me an example of X"
---

# Concept Explainer

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
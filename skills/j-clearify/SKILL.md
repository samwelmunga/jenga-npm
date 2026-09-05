---
name: j:j-clearify
description: Polyfill alias of the clearify skill under a collision-safe directory name. Identical behavior to /clearify — Clarifies ambiguous, dense, or under-specified prompts and conversation on request — inspects an attached prompt or falls back to the current conversation and surfaces plain-language clarifications with examples. Use when the bare /clearify form is shadowed by another tool's own built-in command of the same name.
keywords:
  - clarify this
  - clarify
  - what do you mean
  - I don't understand
  - wtf
  - explain that again
  - can you simplify
  - j-clearify
  - polyfill
examples:
  - "clarify this"
  - "clearify the last message"
  - "wtf does this mean"
  - "I don't understand what you're asking me to do here"
  - "j-clearify"
alias: wtf
---

# Clearify — Ambiguity Clarification

This skill is a literal-directory-name duplicate of `skills/clearify/`. It exists so that `/j-clearify` (and `j:j-clearify`) give a guaranteed-unshadowed way to reach the same flow as `/clearify`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/clearify` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh clearify` from `skills/clearify/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

> **Note on the `alias: wtf` frontmatter field:** this repo has no runtime mechanism that reads an `alias` key to route slash commands — no existing `SKILL.md` implements one, and `project/configs/workflow.json` has no alias registry. The field here documents the intended relationship only. `/wtf` is made invocable as a working alias by the companion skill folder at `skills/wtf/SKILL.md`, which delegates to these same instructions.

## Instructions

1. **Determine the target content.**
   - If the user attached a prompt, file, or pasted block of text with this invocation, treat that as the target content.
   - Otherwise, fall back to the most recent user message, plus any surrounding conversation context needed to make sense of it (e.g. the message it's replying to, an earlier instruction it references).
   - Note: this is the only fallback distinction that matters — do not ask the user which content to clarify; infer it from what's available.

2. **Identify ambiguous or dense formulations** in the target content. Look for:
   - Jargon or domain-specific terms used without definition
   - Unclear pronouns or references ("it", "that", "this one" — where the referent isn't obvious)
   - Compound asks (multiple distinct requests bundled into one sentence)
   - Unstated assumptions (the request depends on context the reader doesn't have)
   - Vague quantifiers or qualifiers ("soon", "a bit", "some of them") where precision matters
   - Overloaded or dense sentences that pack too much meaning into too little structure

3. **For each ambiguous item found, output a structured block** with:
   - **Plain-language clarification** — what it most likely means, stated simply and directly
   - **Simplified restatement** — the original phrasing rewritten in plain terms
   - **Additional context** — relevant background the user may be missing (why this term/reference matters, what it typically implies)
   - **Example(s)** — a concrete worked example, included only where it would actually help clarify the specific ambiguity — skip this sub-section for an item if an example wouldn't add value, rather than manufacturing a weak one

4. **Format the output so it's scannable.** Use a header or bold label per ambiguous item (e.g. `### 1. "the usual setup"` or `**1. "the usual setup"**`) — never collapse multiple ambiguous items into a single unstructured paragraph. If there are multiple items, number them in the order they appear in the source content.

5. **Handle the zero-ambiguity case explicitly.** If nothing in the target content is actually ambiguous, dense, or under-specified, say so plainly — e.g. "Nothing here looks ambiguous — the request is clear as written." Do not manufacture findings just to have something to report.

## Examples
- `/clearify` — Clarify the most recent user message / relevant conversation context
- `/clearify <pasted text>` — Clarify the attached text directly
- `/wtf` — Alias for `/clearify`, invoked via the companion skill in `skills/wtf/`

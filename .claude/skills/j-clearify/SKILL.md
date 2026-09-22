---
name: j.clearify
description: Clarifies ambiguous, dense, or under-specified prompts and conversation on request — inspects an attached prompt or falls back to the current conversation and surfaces plain-language clarifications with examples.
keywords:
  - clarify this
  - clarify
  - what do you mean
  - I don't understand
  - wtf
  - explain that again
  - can you simplify
  - j-clearify
examples:
  - "clarify this"
  - "clearify the last message"
  - "wtf does this mean"
  - "I don't understand what you're asking me to do here"
  - "j-clearify"
alias: wtf
---

# Clearify — Ambiguity Clarification

`skills/j-clearify/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-clearify/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/clearify/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

> **Note on the `alias: wtf` frontmatter field:** this repo has no runtime mechanism that reads an `alias` key to route slash commands — no existing `SKILL.md` implements one, and `project/configs/workflow.json` has no alias registry. The field here documents the intended relationship only. `/wtf` is made invocable as a working alias by the companion skill folder at `skills/j-wtf/SKILL.md`, which delegates to these same instructions.

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
- `/wtf` — Alias for `/clearify`, invoked via the companion skill in `skills/j-wtf/`

---
name: j.clearify
description: "DEPRECATED legacy alias of /clarify, kept only because this skill was originally shipped under a misspelled name. Use j.clarify instead. Behaviour is identical: clarifies ambiguous, dense, or under-specified prompts and conversation on request."
deprecated: true
deprecated_in_favor_of: j.clarify
keywords:
  - clearify
  - j-clearify
examples:
  - "clearify the last message"
  - "j-clearify"
alias: clarify
---

# Clearify — Deprecated Alias of /clarify

> ⚠️ **Deprecated legacy skill — this name was a typo.** `clearify` is a misspelling of `clarify`. The correctly spelled skill is `j.clarify` (`skills/j-clarify/SKILL.md`), and it is the canonical one. `j.clearify` / `/j-clearify` is kept only so existing client projects that already invoke the misspelled name keep working. It may be removed in a future major version; new usage should always use `j.clarify`.

`/clearify` is an alias of `/clarify`. Follow `skills/j-clarify/SKILL.md` in full — do not duplicate or reimplement its ambiguity-detection logic here. Read that file's `## Instructions` section and execute it exactly as written, using whatever prompt or conversation context is attached to this `/clearify` invocation.

## Instructions

1. Tell the user, in one short line before the clarification output, that `/clearify` is a deprecated misspelled alias and that `/clarify` is the name to use from now on. Say this once per invocation; do not repeat it inside the clarification itself.
2. Then follow `skills/j-clarify/SKILL.md`'s `## Instructions` exactly.

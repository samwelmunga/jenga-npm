---
name: j:j-jbp
description: Polyfill alias of the jbp skill under a collision-safe directory name. Identical behavior to /jbp — Scaffold the project using the JengaBasePlate boilerplate repo template from https://github.com/samwelmunga/JengaBasePlate.git. Use when the bare /jbp form is shadowed by another tool's own built-in command of the same name.
keywords:
  - jbp
  - boilerplate
  - scaffold
  - template
  - jenga base
  - j-jbp
  - polyfill
examples:
  - "scaffold with JengaBasePlate"
  - "set up the base template"
  - "j-jbp"
---

# JBP — JengaBasePlate Scaffold

This skill is a literal-directory-name duplicate of `skills/jbp/`. It exists so that `/j-jbp` (and `j:j-jbp`) give a guaranteed-unshadowed way to reach the same flow as `/jbp`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/jbp` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh jbp` from `skills/jbp/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

Use the following repo as the boilerplate framework for this project:

```
https://github.com/samwelmunga/JengaBasePlate.git
```

Clone or pull the template and apply its structure to the current project.

---
name: <skill-name>
description: <One-sentence description of what this skill does and when to use it.>
metadata:
  prefered_agent: <agent-name>   # optional — remove if not applicable
output_types: <type>             # optional — forwardable output type(s) this skill produces; a single
                                 #   type string or a list of {when, type} entries. Declare only if this
                                 #   skill genuinely produces output a playbook step could consume
                                 #   (honesty over breadth, E53_S11). Remove if not applicable.
input_types: <type>              # optional — forwarded input type(s) this skill accepts; same two
                                 #   shapes as output_types. May be broadly declared — honesty over
                                 #   breadth is scoped to output_types only (E62_S01_T03).
                                 #   Remove if not applicable.
---

> Type values come from the canonical vocabulary in `templates/playbook-types.json`. See
> `docs/skill-authoring.md`'s `output_types` and `input_types` sections for the full contract,
> including the `text` rule and the normalize-versus-convert boundary.

# <Skill Title> — <Short tagline>

## Instructions

### 1. <First step title>

<Describe what to do in this step.>

### 2. <Second step title>

<Describe what to do in this step.>

### Session End

When this skill's session concludes, emit the following signal on its own line so the Jenga Router clears the active session:

```
[JENGA:SESSION_END:<skill-name>]
```

Replace `<skill-name>` with the actual skill name from the frontmatter.

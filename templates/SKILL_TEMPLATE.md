---
name: <skill-name>
description: <One-sentence description of what this skill does and when to use it.>
metadata:
  prefered_agent: <agent-name>   # optional — remove if not applicable
---

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

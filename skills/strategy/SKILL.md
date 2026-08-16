---
name: strategy
description: Walk through a guided conversation to capture or update docs/STRATEGY.md — covering Vision, Value Proposition, Scope, and Target Audience — one section at a time.
metadata:
  prefered_agent: developer
keywords:
  - strategy
  - strategic brief
  - vision
  - value proposition
  - target audience
examples:
  - "/strategy"
  - "let's capture the strategy"
  - "update the strategy brief"
  - "write the strategy doc"
---

# Strategy — Guided Capture of docs/STRATEGY.md

## Entry Point

Check whether `docs/STRATEGY.md` exists before proceeding.

- If the file does **not** exist → run **Phase A — New Capture Flow** below.
- If the file **does** exist → run **Phase B — Update Existing File** below.

---

## Phase A — New Capture Flow

Walk the user through four sections in order. Ask **one focused question per section**. Do not present a list of questions up front. Wait for the user's answer before moving to the next section.

### Step 1 — Vision

Ask the user exactly:

> "What is the long-term direction or ambition for this project? Describe where you want it to be in 3–5 years, or what success ultimately looks like."

Wait for the answer. Record it as the **Vision** content.

### Step 2 — Value Proposition

Ask the user exactly:

> "What makes this project uniquely valuable? What would users or teams miss most if it didn't exist?"

Wait for the answer. Record it as the **Value Proposition** content.

### Step 3 — Scope: In Scope

Ask the user exactly:

> "What does this project explicitly cover? List the main capabilities or areas of responsibility."

Wait for the answer. Record it as the **In Scope** content.

### Step 4 — Scope: Out of Scope

Ask the user exactly:

> "What does this project explicitly NOT cover? (Do not include revenue models, pricing, or competitive analysis — those are always out of scope.)"

Wait for the answer. Record it as the **Out of Scope** content. The model must also always append to the Out of Scope section (regardless of whether the user mentions them):

- Revenue model, pricing strategy, or monetisation plans
- Competitive analysis or feature comparison with other tools

Do not ask the user for these — include them silently.

### Step 5 — Target Audience

Ask the user exactly:

> "Who is this built for? Describe the primary user personas or teams."

Wait for the answer. Record it as the **Target Audience** content.

---

## Pre-Write Summary and Confirmation

After collecting all five pieces of content (Vision, Value Proposition, In Scope, Out of Scope, Target Audience), surface a formatted summary. Use exactly this shape:

```
Here is what will be written to docs/STRATEGY.md:

## Vision
<vision content>

## Value Proposition
<value proposition content>

## Scope

### In Scope
<in-scope content>

### Out of Scope
<out-of-scope content (user answer + always-excluded items)>

## Target Audience
<target audience content>

---

Does this look right? Type **yes** to write `docs/STRATEGY.md`, or tell me what to change.
```

- If the user says **yes** (or any clear affirmative) → proceed to the Write step.
- If the user requests a change → re-ask the relevant question(s) using the same prompts from Phase A, collect the updated answer(s), then loop back to this summary step. Do not write the file until the user explicitly confirms.

---

## Write the File

Generate `docs/STRATEGY.md` using **only the content collected in the conversation**. Do not invent facts, add filler text, or leave any placeholder text in the output.

The file must follow this exact structure:

```markdown
# Strategy Brief

> **Audience:** Investors and strategic partners. This document does not include revenue models, pricing, or competitive analysis.

---

## Vision

<vision content>

---

## Value Proposition

<value proposition content>

---

## Scope

### In Scope

<in-scope content>

### Out of Scope

<out-of-scope content>

---

## Target Audience

<target audience content>
```

Write the file to `docs/STRATEGY.md`. After writing, print exactly:

```
Written to `docs/STRATEGY.md` — captured Vision, Value Proposition, Scope, and Target Audience.
```

---

## Phase B — Update Existing File

`docs/STRATEGY.md` already exists. Do **not** run the new-capture flow. Instead, walk the user through each section so they can decide what to keep and what to replace.

### Step 1 — Read the Existing File

Read `docs/STRATEGY.md` in full. Parse out the content under each of the four sections:

- **Vision** — content under `## Vision`
- **Value Proposition** — content under `## Value Proposition`
- **In Scope** — content under `### In Scope`
- **Out of Scope** — content under `### Out of Scope`
- **Target Audience** — content under `## Target Audience`

Store these as the current values for each section. They will be used as defaults unless the user explicitly chooses to update them.

### Step 2 — Surface Each Section One at a Time

Work through the sections in this order: Vision, Value Proposition, Scope (In + Out together), Target Audience.

For **Vision**, present exactly:

> "Here is the current Vision:
>
> ---
> <existing vision content>
> ---
>
> Do you want to keep this or update it? (keep / update)"

- If "keep" → store the existing Vision content unchanged and move on.
- If "update" → ask exactly:
  > "What is the long-term direction or ambition for this project? Describe where you want it to be in 3–5 years, or what success ultimately looks like."
  Wait for the answer. Store it as the new Vision content.

For **Value Proposition**, present exactly:

> "Here is the current Value Proposition:
>
> ---
> <existing value proposition content>
> ---
>
> Do you want to keep this or update it? (keep / update)"

- If "keep" → store the existing Value Proposition content unchanged and move on.
- If "update" → ask exactly:
  > "What makes this project uniquely valuable? What would users or teams miss most if it didn't exist?"
  Wait for the answer. Store it as the new Value Proposition content.

For **Scope**, present the In Scope and Out of Scope content together:

> "Here is the current Scope:
>
> **In Scope**
> ---
> <existing in-scope content>
> ---
>
> **Out of Scope**
> ---
> <existing out-of-scope content>
> ---
>
> Do you want to keep this or update it? (keep / update)"

- If "keep" → store the existing In Scope and Out of Scope content unchanged and move on.
- If "update" → ask the two focused scope questions from Phase A in sequence:
  1. > "What does this project explicitly cover? List the main capabilities or areas of responsibility."
     Wait for the answer. Store as the new In Scope content.
  2. > "What does this project explicitly NOT cover? (Do not include revenue models, pricing, or competitive analysis — those are always out of scope.)"
     Wait for the answer. Store as the new Out of Scope content. Silently append the always-excluded items (revenue model, pricing strategy, competitive analysis) as in Phase A — do not ask the user for these.

For **Target Audience**, present exactly:

> "Here is the current Target Audience:
>
> ---
> <existing target audience content>
> ---
>
> Do you want to keep this or update it? (keep / update)"

- If "keep" → store the existing Target Audience content unchanged and move on.
- If "update" → ask exactly:
  > "Who is this built for? Describe the primary user personas or teams."
  Wait for the answer. Store it as the new Target Audience content.

### Step 3 — Pre-Write Summary and Confirmation

After all four sections have been decided (either kept or updated), surface a full formatted preview of the final document. Use exactly this shape:

```
Here is what will be written to docs/STRATEGY.md:

## Vision
<vision content>

## Value Proposition
<value proposition content>

## Scope

### In Scope
<in-scope content>

### Out of Scope
<out-of-scope content>

## Target Audience
<target audience content>

---

Does this look right? Type **yes** to overwrite `docs/STRATEGY.md`, or tell me what to change.
```

- If the user says **yes** (or any clear affirmative) → proceed to the Write step.
- If the user requests a change → re-surface only the relevant section(s) using the same keep/update flow above, collect the updated answer(s), then loop back to this preview step. Do not write the file until the user explicitly confirms.

### Step 4 — Write the File

Overwrite `docs/STRATEGY.md` using exactly the same format as Phase A output — only real content from the conversation, no placeholder text. Apply all hard constraints from the Hard Constraints block below.

After writing, print exactly:

```
Written to `docs/STRATEGY.md` — updated Vision, Value Proposition, Scope, and Target Audience.
```

If some sections were kept unchanged and others were updated, list only the updated sections:

```
Written to `docs/STRATEGY.md` — updated <list of updated sections>.
```

---

## Hard Constraints

Enforce these rules throughout the entire skill session — at every step, in every question, and in the written output:

1. **Never ask about** revenue model, pricing, monetisation, competitive analysis, market positioning, financial projections, or any topic outside Vision, Value Proposition, Scope, and Target Audience.
2. **Never write the file** without receiving explicit user confirmation ("yes" or a clear affirmative) at the pre-write summary step.
3. **Never include placeholder text** in the written output. Every section must contain real content from the conversation.
4. **Never add sections** beyond the four defined ones (Vision, Value Proposition, Scope, Target Audience) and their required sub-sections.
5. **Always include** the audience callout block at the top of the written file, verbatim.
6. **Always include** the always-excluded Out of Scope items (revenue model, pricing, competitive analysis) even if the user omits them.

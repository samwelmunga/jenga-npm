<!--
  NODE QUESTION TEMPLATE — /uncharted Convergence Loop.

  Added by E40_S06_T03. Consumed by the Convergence Loop's Step 5
  ("Confirm/correct", skills/j-uncharted/SKILL.md) whenever risk-weighted
  gating (Step 4) decides a finding needs a confirm prompt under
  `verification_depth: shallow` or `moderate`. Never reached under `strict`
  — Step 4's strict branch converges the node directly, without ever
  reaching Step 5, so this template is simply not invoked in that case.

  Two fixed variants, selected by node kind:

    INTERNAL — the node represents the candidate/service itself (the thing
      `/uncharted` is investigating).
    EXTERNAL — the node represents something outside the candidate that the
      traces surfaced: a dependency it calls, or a consumer that calls it.

  This replaces a fully open-ended "propose understanding, ask the user to
  confirm or correct it" prompt for any node that fits one of these two
  kinds — which, per the Convergence Loop, is every node this flow drafts.
  Wording is fixed and matches the brainstorm's agreed phrasing verbatim
  (project/documentation/examples/uncharted-conversational-elicitation-procedure.md);
  do not paraphrase it when presenting the prompt.

  Usage: present the drafted node/edge summary first (per Step 3's draft),
  then ask the questions below for the selected variant, then offer the
  same confirm / correct-with-detail / defer-as-unconfirmed / other choice
  Step 5 already documents. This file supplies the fixed *questions*; the
  response mechanics (turn cap, converge call) are unchanged and live in
  SKILL.md, not here.
-->

# Node Question Template

## Internal Node

Use when the node represents the candidate/service itself — the thing this investigation is about,
not something external to it.

1. What is this?
2. What does it do?
3. Who consumes it?
4. Other (describe below)

## External Node

Use when the node represents a dependency or consumer the traces surfaced outside the candidate —
something the service calls, or something that calls the service.

1. What is this?
2. What does it do?
3. Is the service producing to it, or consuming from it?
4. Who is the producer, and who is the consumer?
5. Other (describe below)

---

After the selected question set, present the standard confirm/correct choice (per the Interaction
Pattern in `CLAUDE.md` and Convergence Loop Step 5):

```
1. Confirm the draft as accurate
2. Correct it — describe what's wrong
3. Defer — mark this node "unconfirmed" for now
4. Other (describe below)
```

Silence, a counter-question, or an ambiguous reply is not consent — re-ask, the same convention used
at every other confirmation gate in this skill.

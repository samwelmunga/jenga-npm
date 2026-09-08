# `/jenga`'s Invocation Parameter — The Three Entry Modes

## 1. What it is

`/jenga` accepts exactly **one positional argument** — there are no flags
(`--foo bar` style options don't exist on this command). That single argument
is read once, at the very start of the run (Phase 0.75, "Entry Mode
Resolution"), and it determines which of three **entry modes** the rest of
the run executes under:

| You type | Entry mode | Argument value seen by the skill |
|---|---|---|
| `/jenga` | **Bare** | no argument at all |
| `/jenga <ids>` | **Scoped** | a non-empty string that is not the literal `*` |
| `/jenga *` | **Wildcard** | the literal single character `*` |

Everything downstream — the picker, the confirmation tree, whether any board
IDs are actually resolved — branches off which of these three the raw
argument matched.

## 2. Why it exists

Before this parameter existed, `/jenga` had one behavior: decompose the
*entire* board, queue everything, and execute everything, with zero user
prompts. That's efficient when you genuinely want the whole backlog moving,
but dangerous as a default — a bare `/jenga` could kick off dozens of
worktrees and subagents against work the user never meant to start yet.

The single-argument design (from E45, "Interactive Scope Selection for
Jenga") keeps the original zero-prompt power available, but moves it behind
an explicit, hard-to-typo opt-in (`*`), while making the *default* invocation
(no argument) safe: it always shows the user what's about to run before
committing to it.

## 3. How it works

The argument is classified once, in `skills/jenga/SKILL.md` Phase 0.75, by a
simple three-way check on the raw string:

- **No argument at all** → **bare branch**. `/jenga` invokes
  `skills/jenga/scripts/render-picker.sh` with no arguments, which renders a
  numbered checklist of the whole board. The user's reply is fed back into
  the same script in "continue" mode until they either confirm a selection
  or cancel. A confirmed selection then flows into the same confirmation-tree
  step the scoped branch uses (see below).

- **Any other non-empty argument** → **scoped branch**. The *whole* argument
  string is treated as a comma-separated list of board-ID fragments and
  handed to `skills/jenga/scripts/resolve-id.sh`. That script parses each
  comma-delimited segment against a fuzzy-ID grammar — for example `E01s02`,
  `e01 S04 t02`, and even the untagged `0103` all resolve to real board IDs
  (`E01_S02`, `E01_S04_T02`, `E01_S03` respectively). If every segment
  resolves, the run proceeds straight to a confirmation tree (skipping the
  picker). If *any* segment is rejected — ambiguous, malformed, or simply not
  on the board — the entire invocation halts and reports each rejection's
  reason verbatim; no partial scope is ever assembled from the segments that
  did resolve.

- **The literal string `*`** → **wildcard branch**. This is checked as an
  exact string match, not a wildcard glob — `*` is the only value that
  qualifies. This branch skips the picker *and* the confirmation tree
  entirely and reproduces the original fully-automated pipeline: the whole
  board is decomposed, queued, and executed with no user prompts at all. It
  is the only entry mode where that's true.

Both the bare and scoped branches converge on the same **shared confirmation
step** once a candidate ID set exists — an editable checklist tree the user
can toggle before anything actually runs. Only the wildcard branch bypasses
this.

## 4. When to use it

- **Bare `/jenga`** — default choice when you're not sure exactly what's
  ready to run, or want to eyeball the board before committing. Safest
  option; always requires at least one confirmation round-trip.
- **`/jenga <ids>`** — when you already know precisely which epic(s),
  story(ies), or task(s) you want (e.g. `/jenga E32_S05`), and want to skip
  hunting for them in a picker, while still getting a final confirm step.
- **`/jenga *`** — only when you deliberately want the entire board moving
  with zero interruptions — e.g. an unattended/CI-style run, or a backlog
  you've already fully vetted. Don't reach for this out of impatience with
  the picker; a mistyped scope here has no confirmation step to catch it.

## 5. Example

```
/jenga
```
→ renders a full-board picker; user selects `2,5,7`; a confirmation tree
appears listing those items (plus any undecomposed epics/stories they
belong to); user confirms; only those items are decomposed/queued/executed.

```
/jenga E01_S04_T02, E32_S05
```
→ skips the picker, resolves both IDs directly, shows the confirmation tree
for just those two, then runs on confirm.

```
/jenga *
```
→ no picker, no confirmation — the entire board is decomposed into stories
and tasks, everything is queued into `todo.md`, and every eligible item
starts executing immediately.

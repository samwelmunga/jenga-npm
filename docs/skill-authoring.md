# Skill Authoring Guide

Skills are stored in `skills/<name>/SKILL.md` and invoked with `j.<name>` in a Claude Code session —
the canonical form, namespaced by `E50_S01` and given its current `.` separator by `E50_S07`. The old
bare `/<name>` form keeps resolving permanently as an alias. See "Invocation Convention" below for
the mechanics, the naming constraint every skill `name` must satisfy, and the full migration policy.

---

## Invocation Convention

`E50` namespaces every Jenga skill invocation under a `j.` prefix (e.g. `j.status`, `j.commit`,
`j.init`) to avoid collision with, or masquerading by, a same-named command from another tool or
skill installed in the same agent session. This section records the two decisions this required —
the rename mechanism and the old-form migration policy — and the investigation behind them, so the
routing-surface tasks that implement the actual cutover (`E50_S01_T02` Claude Code native,
`E50_S01_T03` Jenga Router MCP, `E50_S01_T04` Copilot/Codex templates) share one unambiguous
contract instead of each re-deciding it.

### Decision 1 — Rename mechanism: frontmatter-only, with a validated separator

**Directory names under `skills/` do not change.** Only the frontmatter `name:` field changes, from
`name: <skill-name>` to `name: j.<skill-name>`.

This deliberately breaks the invariant stated elsewhere in this guide that `name` "must match the
directory name under `skills/`". The invariant is replaced with a new one: once migrated, a skill's
frontmatter `name` equals `j.` followed by its (unprefixed) directory name — the directory name
remains the bare, on-disk identifier; the frontmatter `name` becomes the canonical, `j.`-prefixed
invocation identifier that downstream routing surfaces read.

#### The constraint the separator must satisfy

A skill's frontmatter `name:` is **not free-form text**. Consuming host tools parse it and *validate
the value*, and a name that fails validation does not load at all — the skill is simply absent, with
no partial or degraded mode. The binding constraint is therefore the **strictest name validator among
all host tools that load Jenga skills**. Currently that is GitHub Copilot CLI's:

```
Skill name must start with an ASCII letter or number and contain only
ASCII letters (a-z, A-Z), numbers, hyphens, underscores, dots, and spaces
```

Any new separator, prefix, or naming scheme must be checked against this rule — and against the
equivalent rule of any host tool added later — **before** it is adopted.

**Why this is stated so emphatically.** `E50_S01` originally chose `:` and justified it by arguing
that a colon was safe *because* it lived in frontmatter rather than in a filename — i.e. it checked
the constraint imposed by the *filesystem* and concluded the frontmatter value was therefore
unconstrained. That inference was false. `E50_S07` found the Copilot CLI rejecting **82 of 82** Jenga
skills on version 1.0.83 — a total outage on that surface, not a partial degradation. The filename
argument below is still correct about filenames; it was never a licence to treat the frontmatter
value as unvalidated.

**Two things the outage did *not* prove.** Both were considered and disproved during the `E50_S07`
investigation; do not re-derive them:
1. **The rule is not "A-Z only."** Hyphens, underscores, dots and spaces are all legal. The only
   character Jenga ever used that is off the allow-list is `:`.
2. **The `j-<name>` directory twins (`E50_S05`) were not the cause and are not invalid.** Their
   directory names are perfectly legal. They failed only because their frontmatter carried
   `name: j:j-<name>` — the same colon. See the twins section below; that mechanism is untouched.

#### The chosen separator: `.`

`j.<name>` was selected from four candidates because it is legal under the rule above, it keeps
`E50`'s namespace intent fully intact (`j.status` is still one unmistakably-Jenga identifier, not a
bare name that anything else could supply), and it is a one-character diff from `j:` — making the
cutover a separator swap rather than a redesign of the convention.

**Verify empirically, not from documentation.** The check for Copilot is `copilot skill list` run
from the repo root: a valid name appears in the listing, an invalid one appears under
"failed to load" with the reason. `tests/` carries a regression gate for exactly this (`E50_S07_T04`),
so a future name change that a host tool would reject fails the suite instead of shipping.

#### Why not rename the directories themselves

- **The host tool's identity for a skill is its frontmatter `name`, not its directory name.** Verified
  on Copilot CLI 1.0.83: a skill living in a directory named `status/` but declaring
  `name: j.status` is listed as `j.status`. Renaming the directory would therefore buy nothing on
  that surface — the prefix is already carried by the field the tool actually reads.
- A directory rename could never have rescued the old `:` separator anyway. `:` is not a valid
  filename character on Windows (reserved for drive letters / alternate data streams), and this
  project has no `"os"` restriction in `package.json` and ships as a general-purpose npm package
  (`@jenga-ai/agent`) — it must not assume a POSIX-only install/dev surface. A directory literally
  named `skills/j:status/` would break on Windows checkouts, npm installs, and any Windows
  contributor's clone. `.` *is* a legal filename character, so this particular objection no longer
  binds the current separator — but the remaining reasons below still do.
- Claude Code's own native skill resolution is a **literal-string, directory-name-based match**,
  independent of `SKILL.md` content. `templates/agent-context.md.tpl`'s Skill Routing section states
  this explicitly: "If you are Claude Code, `/skill-name` is a native harness-level mechanism: the
  harness itself intercepts the literal command and loads the skill for you, independent of anything
  written here." That means a frontmatter change alone cannot, by itself, make the harness resolve a
  *new* literal string on the Claude Code native surface — the actual wiring for that surface is
  `E50_S01_T02`'s job, using this decision's identifier as its source of truth. What this task fixes
  is the **canonical identifier** every surface should treat as "this skill's real name" going
  forward — not the low-level mechanics of how each individual surface's resolver gets there.
- `scripts/postinstall.js` and `lib/mirror.js` (the install/dev mirror pipeline) copy `skills/` and
  `agents/` by directory name and are entirely content-agnostic about `SKILL.md` — a frontmatter-only
  change requires no changes to either and cannot break the mirror/install path.
- `mcp/router/skill-index.js` already indexes skills by their frontmatter `fm.name` (not directory
  name), and `mcp/router/index.js`'s `route_prompt` already emits whatever string is in
  `match.skill.name` (`transformed: "/${match.skill.name} ${text}"`). A frontmatter-only rename is
  therefore a real, load-bearing signal for that surface — `E50_S01_T03` only needs to teach the
  router to also match legacy bare-form input against the same record (see Decision 2), not to
  restructure how the index is built.

Verified before deciding (at `E50_S01`, when the repo had 42 skills): every `skills/*/SKILL.md`
frontmatter `name:` matched its directory name exactly, so there was no pre-existing drift to
reconcile. The invariant has held through `E50_S07`'s separator swap across all 82 skills.

### Decision 2 — Old bare-form migration policy: alias (not deprecation warning, not removal)

**The bare `/skill-name` form keeps resolving indefinitely, on all three routing surfaces, alongside
the new `j.skill-name` form.** No warning is emitted and no removal is scheduled by this decision.

This is the only one of the three candidate policies (alias / deprecation warning / removal) that can
be implemented **uniformly** across all three surfaces given Decision 1:

- **Claude Code native.** Because directories are not renamed, the bare form keeps resolving through
  the exact same harness-level literal-string match it always has — Jenga has no interception point
  on that path at all ("independent of anything written here," per the same harness quote above).
  Concretely, this means neither a runtime deprecation warning nor an actual removal of the bare form
  is achievable on this surface without literally renaming/deleting the directory — which would
  reopen the Windows-filename problem Decision 1 exists to avoid. A policy that only 2 of 3 surfaces
  can actually enforce is not the uniform decision this story requires.
- **Jenga Router MCP.** Easily supports a warning or removal (structured JSON response, full control
  over matching) — but is deliberately kept as a plain alias to stay consistent with the native
  surface above, not because it's technically constrained.
- **Copilot/Codex prose templates.** Also easily supports a warning or removal (fully
  instruction-driven) — same reasoning: kept as a plain alias for cross-surface consistency.

**Reasoning for choosing alias over the other two, given the above:** requiring every surface to
behave identically was treated as more valuable than extracting a stronger nudge from the two
surfaces capable of one. A policy that warns or removes on 2 surfaces while silently aliasing on the
third would be a worse outcome than a plain, honest alias everywhere — it would give users a
false impression of uniform deprecation while the Claude Code native surface quietly never
enforced it. Full removal was also rejected outright for the reason given for Claude Code native
above: it is not actually achievable there without the same directory-rename/Windows tradeoff, so
"remove everywhere" was never a real option under Decision 1.

**Residual risk, left open by this task on purpose:** because the bare form is never removed or
warned against, the collision/masquerade risk motivating this epic persists on the *bare* namespace
indefinitely — only the new `j.`-prefixed namespace gets the `E50_S02` allow-list guard's protection.
Actually retiring the bare form would require revisiting the directory-rename tradeoff in Decision 1
(e.g. accepting a Windows-incompatible directory layout, or some other mechanism not yet designed)
and is out of scope here — a future task, not this one, if the tradeoff is ever revisited.

### What `E50_S01_T02`–`T04` inherit from this decision

Each routing-surface task implements the surface-specific mechanics of the same contract:
1. Treat a skill's canonical identifier as `j.<name>` (frontmatter `name`, once migrated).
2. Also keep matching the corresponding bare `<name>` input to the same skill record — no warning,
   no removal.
3. Never rename `skills/<name>/` or `agents/<name>` directories to carry the `j.` prefix — the
   prefix lives in frontmatter only (see "Why not rename the directories themselves" above). The
   separate `skills/j-<name>/` twins are not an exception to this: they are additional directories,
   not renames of the originals.

`scripts/apply-j-prefix.sh` (this task) performs the deterministic parts of step 1 (frontmatter
rewrite) and updates bare `/<name>` prose mentions in `agents/*.md` to `j.<name>` (per the Skill
Implementation Principle in `CLAUDE.md`) — `--dry-run` supported so `E50_S01_T02` can verify its
output before committing to it.

### `j-<name>` directory twins — a separate, complementary mechanism (`E50_S04`/`E50_S05`)

Distinct from everything above, every skill (except where explicitly excluded — see below) also has a
second, literal directory under `skills/j-<name>/` — a full functional duplicate of `skills/<name>/`,
invocable as `/j-<name>`.

**Purpose.** Decision 1 above is a frontmatter-only rename precisely because Claude Code's native
resolver does a literal-string, directory-name match, and Jenga has no interception point on that
surface at all. That means if a host tool ships its own built-in command with the exact same bare
name as a Jenga skill — the motivating case was GitHub Copilot's own built-in `/init` — it can shadow
Jenga's bare `/<name>` form on that surface, and no frontmatter change can fix it. `j-init`
(`E50_S04`) was built as a one-off fix: a byte-for-byte duplicate of `skills/init/` under the
collision-safe directory name `skills/j-init/`, giving a guaranteed-unshadowed path to the same flow
regardless of what else is installed. `E50_S05` generalizes that one-off pattern to every skill.

**How this differs from the `j.<name>` prefix convention.** The prefix convention (Decision 1 above) is
a frontmatter-only identifier change — no new directory, no new files. The `j-<name>` pattern is the
opposite: a real, second, on-disk directory, deliberately duplicating content rather than aliasing it,
because the collision it defends against happens at the directory-name-resolution layer the
frontmatter prefix cannot reach. The two are complementary, not alternatives — a skill keeps its `j.<name>`
frontmatter identifier *and* gains a `j-<name>` directory twin; neither replaces the other.

**Generation and sync.** `scripts/generate-j-alias.sh <skill-name>` is the only supported way to
create or update a `skills/j-<name>/` directory — per `CLAUDE.md`'s Skill Implementation Principle,
this is never hand-maintained. It copies the full `skills/<skill-name>/` tree, rewrites
self-referential path references and frontmatter (`name: j.<skill-name>` → `name: j.j-<skill-name>`),
and is idempotent and fully rebuilding on every run, so a source change is picked up in full on the
next invocation rather than incrementally patched. `E50_S05_T02` ran it once across all 41 eligible
skills; re-running it against a changed source skill is the ongoing lockstep-sync path.

**Exclusions.** `skills/init/`/`skills/j-init/` are excluded (already hand-built and paired before the
generator existed), `skills/jenga/` and `skills/jenga-permission-level/` are excluded (root
orchestrator commands — the invocation surface for these two must stay exactly `/jenga`/`j.jenga`
and `/jenga-permission-level`/`j.jenga-permission-level`, never a doubled `j-jenga` alias), and
`skills/index/` is excluded (no `SKILL.md` — not a skill, not part of routing).

---

## Frontmatter Spec

Every `SKILL.md` begins with a YAML frontmatter block. All fields except `name` and `description` are optional.

```yaml
---
name: <skill-name>
description: <one-sentence description shown in j.help listings>
metadata:
  prefered_agent: <agent_name>       # optional — delegate execution to a sub-agent
keywords:                            # optional — short phrases for keyword routing
  - "<phrase 1>"
  - "<phrase 2>"
examples:                            # optional — natural-language prompts for semantic routing
  - "<example prompt 1>"
  - "<example prompt 2>"
minimum_permission_level: <1-5>       # optional — minimum session permission level required to run this skill
output_types: <type> | [{when, type}] # optional — declares this skill's forwardable output type(s) for playbooks (E53_S03_T02)
---
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | ✅ | Skill name. Before `E50_S01` migration: must match the directory name under `skills/`. After migration: `j.` + the directory name — see "Invocation Convention" above. |
| `description` | string | ✅ | One-sentence description shown in `j.help` listings and the skill registry. |
| `metadata.prefered_agent` | string | ❌ | Sub-agent to delegate execution to. Valid values: `scrum-master`, `developer`, `tester`. |
| `keywords` | string[] | ❌ | Short words or phrases (1–3 words) strongly associated with this skill. Used by the Jenga Router for keyword matching. |
| `examples` | string[] | ❌ | Natural-language prompt strings that should trigger this skill. Used by the Jenga Router for semantic matching. |
| `minimum_permission_level` | integer | ❌ | Minimum session permission level (`1`-`5`) required to run this skill. Skills that set this field must gate execution via `scripts/check-permission-level.sh`. |
| `output_types` | string \| `{when, type}`[] | ❌ | Declares what type(s) of forwardable output this skill produces, for `/jenga` playbook `forward_from` steps to reference. See "Playbooks — StepObject Schema and `output_types`" below. |

---

### `keywords`

An optional array of short strings (1–3 words each) that are strongly associated with this skill. The Jenga Router uses these for fast keyword-based dispatch before falling back to semantic matching.

**Guidelines:**
- Keep phrases short — one to three words.
- Include the canonical command name as well as common synonyms.
- Avoid generic words that could match many skills (e.g. "task", "run").

**Example:**
```yaml
keywords:
  - "brainstorm"
  - "plan"
  - "feature planning"
  - "scrum planning"
```

---

### `examples`

An optional array of natural-language strings representing prompts that should trigger this skill. The Jenga Router uses these for semantic (embedding-based) matching when keyword matching yields no clear winner.

**Guidelines:**
- Write examples as a user would naturally type them.
- Cover diverse phrasings of the same intent.
- Aim for 3–8 examples per skill.

**Example:**
```yaml
examples:
  - "let's plan a new feature"
  - "I need to brainstorm ideas for X"
  - "help me think through this epic"
  - "can we scope out the next milestone?"
```

---

### `minimum_permission_level`

An optional integer (`1`-`5`) declaring the minimum session permission level a skill needs to run correctly. This corresponds to the 5-tier system defined by the `j.jenga-permission-level` epic: `1` = Locked, `2` = Guarded (the permanent default), `3` = Standard, `4` = Elevated, `5` = Unrestricted. See the level matrix under `templates/permission-levels/` for what each tier permits.

Set this field only when a skill genuinely cannot complete its work at the default Guarded (2) level — e.g. it needs to run commands that Guarded denies. Most skills should omit this field entirely and run at the default level.

**Guidelines:**
- Use the lowest level that actually satisfies the skill's needs — never request more than necessary.
- Skills that set this field **must** call `scripts/check-permission-level.sh <minimum-level>` at the top of their instructions, before any other work, to gate execution on the current session level.
- If the current session level is below the declared minimum, the skill must surface an explicit confirmation prompt to the user before elevating — silent auto-elevation is never permitted.
- Elevation happens via the same mechanism as `j.jenga-permission-level <n>` (i.e. the skill drives the same level switch, it does not invent a separate one).
- Immediately after the skill's own work completes, reset the session level back to Guarded (2) — regardless of what level it was elevated to. Elevation must never be held past the skill's own execution, and must never be left for the next session start to clean up.
- Do not use this field to hold a session at an elevated level across multiple skills or commands — each elevation is scoped to a single skill invocation.

**Example:**
```yaml
minimum_permission_level: 4
```

---

### `output_types`

An optional field (`E53_S03_T02`) declaring what type(s) of forwardable output this skill produces,
so a `/jenga` playbook step can name this skill as a `forward_from` source (see "Playbooks —
StepObject Schema and `output_types`" below for the full playbook-side contract). Takes one of two
shapes:

- a **single static type string** — this skill always produces the same output type, regardless of
  how it's invoked:
  ```yaml
  output_types: text
  ```
- a **list of `{when, type}` objects** — this skill's output type depends on how it was invoked.
  Each `when` is either one of the two built-in predicates (`argument_empty` / `argument_nonempty`),
  or a named reference to this skill's own classifier script (a skill with its own argument
  grammar, e.g. `j.jenga`'s Phase 0.75 entry-mode resolution):
  ```yaml
  output_types:
    - when: detect-nl-intent
      type: id_list
  ```
  A classifier-script `when` value must match an executable script's basename under this skill's
  own `scripts/` directory (e.g. `detect-nl-intent` → `skills/jenga/scripts/detect-nl-intent.sh`) —
  `skills/jenga/scripts/load-playbooks.sh` checks that the script exists on disk at load time, but
  never runs it to determine which branch would actually fire. See "Playbooks — StepObject Schema
  and `output_types`" below for exactly what claim this load-time check does and does not make.

**Guidelines:**
- The declared type value(s) should be one of the entries in the canonical type vocabulary,
  `templates/playbook-types.json` (`text`, `id_list`, `file_list` as of this writing) — see
  "Playbook Type Registry Governance" below before adding a new type.
- Only declare `output_types` if this skill genuinely produces output another playbook step could
  meaningfully consume. Partial adoption is intentional and expected: as of `E53_S03`, only
  `j.status`, `j.uncharted`, `j.jenga`, and `j.reconcile` declare it. A skill with no declared
  `output_types` simply cannot be a playbook `forward_from` source — this is not a defect to fix
  proactively for every skill.

---

## Complete Example

```yaml
---
name: brainstorm
description: Engage the scrum-master agent in a focused planning session to define, refine, or challenge features, improvements, tasks, stories, and epics.
metadata:
  prefered_agent: scrum-master
keywords:
  - "brainstorm"
  - "plan"
  - "feature planning"
examples:
  - "let's plan a new feature"
  - "I need to brainstorm ideas for X"
  - "help me think through this epic before committing it to the board"
---
```

---

## Skill Body

After the frontmatter, write the skill instructions in plain Markdown. The instructions are passed directly to the executing agent (or to the main Claude Code agent if no `prefered_agent` is set).

Follow these conventions:

- Use numbered steps for sequential workflows.
- Use `bash` code blocks for any shell commands the skill should run.
- Reference board paths via `$(bash "$([ -f scripts/board_resolver.sh ] && echo scripts/board_resolver.sh || echo node_modules/@jenga-ai/agent/scripts/board_resolver.sh)")` rather than hard-coding them — see "Invoking a root-level `scripts/` file" below for why the resolving form is required, not just the bare path.

### Invoking a root-level `scripts/` file

`postinstall.js` mirrors only `skills/` and `agents/` into a consumer's `.claude/`/`.agents/` —
`scripts/` (and `templates/`, `lib/`) is never copied there. A `SKILL.md` instruction written as a
bare `bash scripts/<name>.sh` assumes the executing agent's cwd has its own `scripts/` directory,
which is true only inside this monorepo's own dev checkout (where `scripts/` sits at the repo root).
For a genuine npm consumer, that same file lives at `node_modules/@jenga-ai/agent/scripts/<name>.sh`
instead, so the bare form fails outright the first time a consumer's agent reaches that step
(confirmed: this broke `/uncharted`'s `validate-proposed-items.sh` and `elicitation-state.sh`
`with-lock.sh` calls, and the same bare pattern is used by `/todo`'s and `/do`'s `todo_manager.sh`
and `board_resolver.sh` calls).

Because the Bash tool's shell state does not persist between calls, a variable resolved once cannot
be reused by a later invocation — every command that touches a root-level `scripts/` file must
resolve its own path in the same command, checking for the specific target file (not just that some
`scripts/` directory exists, since a consumer's own unrelated project may already have one):

```bash
bash "$([ -f scripts/<name>.sh ] && echo scripts/<name>.sh || echo node_modules/@jenga-ai/agent/scripts/<name>.sh)" <args>
```

This is the same monorepo-checkout-vs-installed-package fallback already used programmatically
inside scripts themselves (`skills/init/scripts/init.sh`'s `PKG_ROOT` resolution,
`skills/uncharted/scripts/elicitation-state.sh`'s `WITH_LOCK` resolution) — just expressed as a
self-contained prose idiom since a `SKILL.md` instruction has no `$SCRIPT_DIR` of its own to climb
from.

### Invoking a root-level `templates/` file

`postinstall.js` mirrors only `skills/` and `agents/` into a consumer's `.claude/`/`.agents/` —
`templates/` (like `scripts/`) is never copied there either. A `SKILL.md` or `agents/*.md`
instruction written as a bare `templates/<name>` reference assumes the executing agent's cwd has
its own `templates/` directory, which is true only inside this monorepo's own dev checkout (where
`templates/` sits at the repo root). For a genuine npm consumer, that same file lives at
`node_modules/@jenga-ai/agent/templates/<name>` instead, so the bare form resolves to nothing the
first time a consumer's agent tries to read it — the `templates/` counterpart of the same defect
already fixed above for `scripts/`.

Unlike a `.sh` script, a `templates/` file is never executed — it is read as a document (a schema
reference such as `templates/SCRUM_BOARD_SCHEMA.md`), used as a scaffold to copy from (e.g.
`templates/USER_INSTRUCTIONS_TEMPLATE.md`, `templates/EXECUTION_PLAN_TEMPLATE.md`,
`templates/EXECUTION_SUMMARY_TEMPLATE.md`, `templates/PROBLEM_RAPPORT_TEMPLATE.md`,
`templates/CHANGELOG_TEMPLATE.md`), or copied wholesale over a settings file (e.g.
`templates/permission-levels/level-<n>-<name>.json`) — and a `SKILL.md`/`agents/*.md` instruction
has no `$SCRIPT_DIR` of its own to climb from regardless. The fix is the same inline
bash-substitution shape used for `scripts/` above, adapted to check for the specific target file
(not bare directory presence, since a consumer's own unrelated project may already have its own
unrelated `templates/` dir):

```bash
$([ -f templates/<name> ] && echo templates/<name> || echo node_modules/@jenga-ai/agent/templates/<name>)
```

For example, a reference to the board schema resolves as:

```
$([ -f templates/SCRUM_BOARD_SCHEMA.md ] && echo templates/SCRUM_BOARD_SCHEMA.md || echo node_modules/@jenga-ai/agent/templates/SCRUM_BOARD_SCHEMA.md)
```

Every prose reference to a specific root-level `templates/` file must resolve through this idiom
rather than the bare path — whether the reference reads the file's contents, copies it as a
scaffold, or overwrites another file with it.

**Out of scope:** `skills/self-sync/SKILL.md`'s own mentions of `templates/` as one of the
directories it mirrors (alongside `skills/`, `agents/`, `scripts/`, etc.) are not single-file
references and are not part of this idiom — that skill's entire job is to operate on the
monorepo's own root-level `templates/` directory as a whole, which by definition only exists in
this monorepo's own dev checkout (there is no consumer-side installation for `/self-sync` to run
against in the first place).

---

## Playbooks — StepObject Schema and `output_types`

A `/jenga` playbook (`skills/jenga/playbooks/*.json`) is an ordered chain of steps that `/jenga`'s
natural-language branch may propose as an editable, confirmable numbered list. This section
documents the `StepObject` step shape and its load-time validation, added by `E53_S03` on top of
the playbook mechanism `E53_S02` shipped. The single source of truth for this validation is
`skills/jenga/scripts/load-playbooks.sh` — its own header comment is the authoritative, most
detailed reference; this section is a skill-author-facing summary of that same contract, written
against the actual landed implementation (not the original design proposal).

### The `StepObject` schema

Each entry in a playbook's `steps` array is either a **bare string** or a **`StepObject`**:

- A **bare string** (e.g. `"brainstorm"`) is unchanged, original behavior — shorthand for
  `{"skill": "brainstorm"}`. No migration is ever required: an all-bare-string playbook loads
  byte-for-byte the same as before `E53_S03`, and a bare-string step is never rewritten into an
  object form in the loader's output.

- A **`StepObject`** is a JSON object with exactly one of these two target fields (mutually
  exclusive — a step naming both, or naming neither, is rejected):
  - `skill: "<name>"` — invokes a single skill, same as a bare string.
  - `playbook: "<id>"` — composes in another playbook by ID (full composition semantics, cycle
    detection, and depth limiting are `E53_S05`'s scope; this story only accepts the shape).

  Plus these optional fields:
  - `instruction: "<text>"` — static natural-language text appended to this step's own invocation
    message.
  - `forward_from: "<name>"` — names an **earlier** step in the *same* playbook (by that step's
    skill name) whose typed output becomes this step's actual invocation input. See "forward_from
    resolution" below for the load-time rules this triggers.
  - `resolve: "<text>"` — natural-language instructions for reshaping/filtering/type-bridging the
    value forwarded into this step (e.g. "pick the first three items"). See "The `resolve` /
    confirmation-gate rule" below for the one load-time rejection this field triggers. `E53_S06`
    owns `resolve`'s actual runtime behavior — this story only validates it at load time.
  - `version` / `schema_version` (either key name) — **reserved, currently a no-op.** Accepted and
    passed through unchanged; not yet acted upon by anything. Exists so a future schema revision
    has a place to declare itself without every existing playbook needing a retroactive migration.

```json
{
  "steps": [
    "brainstorm",
    {"skill": "todo", "forward_from": "brainstorm", "instruction": "capture as a task"},
    {"playbook": "some-other-playbook-id"}
  ]
}
```

### `forward_from` resolution

A step's `forward_from: "<name>"` is validated entirely at load time, entirely from files already
on disk:

1. **Existence** — `<name>` must equal the skill name of some earlier step in the same playbook. A
   `playbook`-type step never satisfies this (it has no single skill name).
2. **Declared output** — the named source skill's own `SKILL.md` must declare a non-empty
   `output_types` (see the frontmatter field above). A skill with no declared `output_types` can
   never be a forward source — this is the type registry's partial-adoption rule made
   load-time-enforced.
3. **The Blocker 1 structural check**, for classifier-script sources only — when the source's
   `output_types` is the `{when, type}` list form and a given entry's `when` is a classifier-script
   reference (not one of the two built-in predicates), the loader checks only that a script
   matching that reference actually exists on disk
   (`skills/<name>/scripts/<when>.sh`) — it never runs that script, and never claims to know which
   branch would fire at real invocation time. The honest claim this check makes is: *if* this
   classifier-based source continues at all (produces output rather than halting), *then* its
   declared type applies. `j.jenga`'s own classifier (`detect-nl-intent.sh`) is the concrete
   example this check was built against — see `skills/jenga/scripts/load-playbooks.sh`'s header for
   the full end-to-end trace this claim is based on.

A `forward_from` failing any of these three checks causes the **whole playbook** to be
rejected (stderr warning, skipped) — never just the offending step, consistent with this loader's
existing "a chain with a broken link is not a usable chain" granularity.

### The `resolve` / confirmation-gate rule

`resolve` ships, as of `E53_S03`, for reshaping/filtering/type-bridging a forwarded value **only**
— never for pre-authorizing a downstream confirmation. Concretely: a step carrying both `resolve`
and `playbook` is rejected at load time. The loader's documented convention for what counts as a
"downstream confirmation gate" is exactly this — any `playbook`-composition step, since entering a
nested playbook always passes through that playbook's own up-front confirmation
(`render-playbook-confirmation.sh`) before any of its steps run. `resolve` may only ever shape a
value flowing into an ordinary `skill` step.

### Playbook Type Registry Governance

The canonical playbook type vocabulary lives in `templates/playbook-types.json` (currently `text`,
`id_list`, `file_list`). It is **owned by the Scrum Master**, mirroring the same ownership pattern
already established for `PROJECT_SUMMARY.md`. Registry additions or changes route through the
normal board-item (task) process — never an ungoverned direct edit to that file. If a skill you're
authoring needs a type the registry doesn't yet have, raise it as a task rather than adding the
entry yourself.

---

## Threat Model — the `j.` Allow-List Guard

The `j.` skill allow-list guard (`E50_S02`) checks whether a `j.`-prefixed invocation matches a
canonical list of genuine Jenga skill identifiers before treating it as trusted.

**In scope.** The guard prevents an unrelated or malicious skill from adopting the `j.` prefix and
being invoked as though it were a genuine Jenga skill — it defends the **invocation-matching layer**
against name-collision and masquerading.

**Explicitly out of scope.** The guard does **not** sandbox, scan, or otherwise verify the *content*
of a third-party skill file. A skill whose identifier doesn't collide with anything on the allow-list,
or one installed under a name that legitimately isn't `j.`-prefixed, is neither made safer nor less
safe by this guard — content-level trust of any skill, Jenga's own or third-party, is a separate,
unaddressed concern.

This residual risk is a deliberate scope boundary of `E50_S02`, not an oversight.
- Keep the skill body focused on *what to do*, not *how Claude works*.

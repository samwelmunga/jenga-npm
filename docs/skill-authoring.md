# Skill Authoring Guide

A skill is defined by a `SKILL.md` under its own directory in `skills/`, and is invoked as `j.<name>`
in a Claude Code session — the canonical invocation identifier, namespaced by `E50_S01` and given its
current `.` separator by `E50_S07`.

As of the **2026-09-09 reopening of `E50`**, the canonical *directory* is `skills/j-<name>/`, and the
bare `/<name>` slash form is **hard-broken — not aliased, not redirected, not deprecation-shimmed**.
This reverses the earlier "permanent alias" policy, which is retained below as superseded history
(Decision 2). Start at **"The Canonical Naming Contract"** — it is the ratified target state that
`E50_S11`–`E50_S18` implement against. "Invocation Convention" then covers the mechanics, the naming
constraint every skill `name` must satisfy, and the decision history behind both.

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

> **Partially superseded 2026-09-09.** Directory names *do* now change — to `skills/j-<name>/`, per
> "The Canonical Naming Contract" below. What survives is this decision's **separator analysis**: the
> canonical frontmatter value is still `j.<name>`, chosen for exactly the validator reasons given
> here, and that reasoning is untouched. What is withdrawn is the "directories are never touched"
> premise — which means the **"Why not rename the directories themselves" subsection below is
> superseded as a conclusion**, even though its individual observations remain factually accurate.
> Read that subsection as *why a `j.`-dotted directory was rejected*, not as a standing bar on
> renaming directories at all: the contract renames them to `j-<name>`, a hyphenated name that is
> legal on every filesystem and so never triggers the Windows objection recorded there.

This deliberately breaks the invariant stated elsewhere in this guide that `name` "must match the
directory name under `skills/`". The invariant is replaced with a new one: once migrated, a skill's
frontmatter `name` equals `j.` followed by its (unprefixed) directory name — the directory name
remains the bare, on-disk identifier; the frontmatter `name` becomes the canonical, `j.`-prefixed
invocation identifier that downstream routing surfaces read. *(Post-2026-09-09, read "unprefixed
directory name" as the directory name with its `j-` prefix stripped: `skills/j-commit/` →
`name: j.commit`. The value is unchanged; only how you derive it from the directory is.)*

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
   `name: j:j-<name>` — the same colon. *(That colon diagnosis is unchanged. The `j-<name>`
   directories themselves were later promoted from twin to sole canonical form by the 2026-09-09
   reopening — see "The Canonical Naming Contract" below.)*

#### The chosen separator: `.`

`j.<name>` was selected from four candidates because it is legal under the rule above, it keeps
`E50`'s namespace intent fully intact (`j.status` is still one unmistakably-Jenga identifier, not a
bare name that anything else could supply), and it is a one-character diff from `j:` — making the
cutover a separator swap rather than a redesign of the convention.

**Verify empirically, not from documentation.** The check for Copilot is `copilot skill list` run
from the repo root: a valid name appears in the listing, an invalid one appears under
"failed to load" with the reason. `tests/` carries a regression gate for exactly this (`E50_S07_T04`),
so a future name change that a host tool would reject fails the suite instead of shipping.

#### Why not rename the directories themselves — ⚠️ conclusion superseded 2026-09-09

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
  binds the current separator — but the remaining reasons below still did, at the time this decision
  was taken. *(Superseded 2026-09-09 as a conclusion: directories are renamed after all, to
  `skills/j-<name>/`. The Windows objection never applied to a hyphenated name.)*
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
  therefore a real, load-bearing signal for that surface — `E50_S01_T03` only needed to point the
  router at the migrated identifier, not to restructure how the index is built. (This bullet
  originally also had the router match legacy bare-form input against the same record, per Decision
  2. That bare-form matching is withdrawn by the 2026-09-09 contract — see "The Canonical Naming
  Contract" below. The `fm.name`-indexing mechanics described here are unaffected, since the
  canonical frontmatter value remains `j.<name>`.)

Verified before deciding (at `E50_S01`, when the repo had 42 skills): every `skills/*/SKILL.md`
frontmatter `name:` matched its directory name exactly, so there was no pre-existing drift to
reconcile. The invariant has held through `E50_S07`'s separator swap across all 82 skills.

### Decision 2 — Old bare-form migration policy: alias — ⚠️ SUPERSEDED 2026-09-09

> **SUPERSEDED — this is no longer current policy.** The 2026-09-09 reopening of `E50` reversed this
> decision. The bare `/<name>` form is **not** a permanent alias: its directory is deleted, and the
> form hard-breaks with no redirect, alias, or deprecation shim. The current, ratified policy is
> "The Canonical Naming Contract" below; this decision is retained **only as history**, so the
> reasoning that produced it stays readable and the same ground is not re-argued from scratch.
>
> **What actually changed:** this decision assumed directories are never renamed (Decision 1), which
> made the bare form unremovable on the Claude Code native surface and therefore made "alias
> everywhere" the only uniform option. The reopening accepts the directory rename that assumption
> ruled out — which is exactly what makes removal achievable on that surface, and dissolves the
> "only 2 of 3 surfaces can enforce it" argument below. See the contract section for why the
> tradeoff was re-taken.

**Original reasoning, as decided at `E50_S01` (historical record — do not read as current policy):**

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

*(End of historical record.* That tradeoff **was** revisited, on 2026-09-09, and the residual risk
this paragraph left open is what the reversal closes: with the bare directory deleted, the bare
namespace it left unguarded no longer resolves to a Jenga skill at all. The rename is safe here
because the canonical directory is `skills/j-<name>/` — an ordinary hyphenated name, legal on every
filesystem — so it never reintroduces the Windows-filename problem that a literal `skills/j:status/`
would have. See the contract section below.*)

### What `E50_S01_T02`–`T04` inherit from this decision

Each routing-surface task implements the surface-specific mechanics of the same contract:
1. Treat a skill's canonical identifier as `j.<name>` (frontmatter `name`, once migrated). **Still
   current** — this is the one item the 2026-09-09 reversal leaves entirely intact.
2. ~~Also keep matching the corresponding bare `<name>` input to the same skill record — no warning,
   no removal.~~ **Withdrawn 2026-09-09.** Bare `<name>` input is not matched to any skill record on
   any surface; the form is hard-broken, not aliased. See "The Canonical Naming Contract" below.
3. ~~Never rename `skills/<name>/` ... to carry the `j.` prefix.~~ **Reversed 2026-09-09 for
   `skills/`.** The canonical skill directory *is* renamed — to `skills/j-<name>/`, with the
   bare-name directory deleted. Note this is a `j-` (hyphen) directory name, not the `j.` (dot)
   frontmatter prefix the original item was about; the dot form was never legal as a directory name
   and still isn't. **`agents/<name>` is unaffected** and is still never renamed — this contract
   governs `skills/` only.

`scripts/apply-j-prefix.sh` (this task) performs the deterministic parts of step 1 (frontmatter
rewrite) and updates bare `/<name>` prose mentions in `agents/*.md` to `j.<name>` (per the Skill
Implementation Principle in `CLAUDE.md`) — `--dry-run` supported so `E50_S01_T02` can verify its
output before committing to it.

### The Canonical Naming Contract — `skills/j-<name>/` is the sole canonical form (2026-09-09)

**This section is the current, ratified policy** and supersedes Decision 2 above. It is a **settled
user decision, dated 2026-09-09**, transcribed from `E50_S10`. It is not an open question, and the
eight downstream stories `E50_S11`–`E50_S18` are written against it: do not re-derive, re-open, or
soften it. What follows is the target state; the mechanical cutover (directory deletion, frontmatter
rewrite, reference updates) is owned by those stories, not by this document.

| | previously (bare) | previously (twin) | **settled end state** |
|---|---|---|---|
| directory | `skills/commit/` | `skills/j-commit/` | `skills/j-commit/` (sole canonical) |
| frontmatter `name:` | `j.commit` | `j.j-commit` | **`j.commit`** |
| resolves as | `/commit`, `j.commit` | `/j-commit`, `j.j-commit` | `/j-commit`, `j.commit` |

#### Two separable identifiers — the distinction that matters most

Read the table as two independent columns of change, because conflating them is the single easiest
way to get this contract wrong:

1. **The directory** is renamed `skills/<name>/` → `skills/j-<name>/`, and the old bare-name
   directory is **deleted**. Claude Code resolves skills by literal directory name, so deleting
   `skills/commit/` is precisely what breaks bare `/commit` — the directory *is* the slash form on
   that surface. `/j-commit` becomes the directory-based slash form.
2. **The frontmatter `name:` is `j.<name>` — deliberately kept, not doubled.** Every existing twin's
   `name:` is rewritten `j.j-<name>` → `j.<name>` (owned by `E50_S15`, which lands that rename in the
   same change as the bare-directory deletion).

The net effect is smaller than it first appears: **`j.<name>` — the invocation form this guide already
teaches everywhere — survives untouched.** Only bare `/<name>` breaks.

**The rejected alternative, recorded so it is not relitigated.** `name: j.j-<name>` — i.e. letting the
twin's current doubled frontmatter value stand as canonical — was **considered and declined** on
2026-09-09. Adopting it would have broken `j.commit`, the one identifier users and docs actually rely
on, in exchange for nothing: the frontmatter value carries no collision-safety role (that job belongs
entirely to the directory name), so doubling it imposes churn on every user and every doc reference
while defending against nothing. `j.<name>` is canonical.

#### What "hard break" concretely means

The bare `/<name>` form is **hard-broken: no redirect, no alias, no deprecation shim, no warning.**
For a user who types `/commit` after the cutover:

- **The command does not resolve, and no Jenga skill runs.** Nothing redirects them to `/j-commit`,
  and nothing tells them that is the form they now want.
- **Claude Code native — the failure is not Jenga-visible.** Jenga has no interception point on this
  surface (see Decision 2's own reasoning, which remains factually correct on this point): the
  harness matches the literal string against directory names itself. With no matching directory,
  Jenga emits nothing — there is no Jenga-authored error message, because there is no Jenga code
  path to author one from. Whatever the user sees is the host tool's own generic unknown-command
  behavior, which Jenga neither controls nor guarantees.
- **Jenga Router MCP / Copilot-Codex prose templates — no bare-form matching by policy.** These
  surfaces *could* technically keep matching bare input (they did so only for cross-surface
  consistency with the native surface, never from constraint). Under this contract they no longer
  do: bare `<name>` is not an alias to be matched on any surface.
- **The dangerous case is a stale reference in a config file, and it is silent.**
  `skills/jenga/scripts/load-playbooks.sh` (L690-700) requires every playbook step's
  `skills/<name>/SKILL.md` to exist on disk; if any step's skill is missing, it prints a warning to
  **stderr** and **skips the entire playbook**. In normal use that stderr line is not surfaced to the
  user, so the playbook simply, silently, stops existing. This is not hypothetical — it is exactly
  the failure that triggered this reopening (see "Why this reversed" below), and it is why
  `E50_S11`–`E50_S18` must update *every* bare-name reference, not just the directories themselves.

**Summary of user-visibility: the break is loud for the person who typed the command (their command
plainly does nothing) and silent everywhere else.** Silent breakage in machine-read references is the
risk this cutover has to be careful about, not the interactive case.

#### Skill *content* is unchanged by this reopening

This is a renaming and reference-updating change only. **No skill's instructions, behavior, scripts,
or any other body content are modified by it.** What changes is exactly three things: directory
names, frontmatter `name:` values, and the references that resolve them. A skill that worked before
the cutover does the same thing after it, reached by a different name.

#### This supersedes `mirror.sh`'s mirror-time twin-name fixup

`skills/mirror-public/scripts/mirror.sh`'s `rewrite_orphaned_twin_names()` (L1361-1527) already
performs exactly this `j.j-<name>` → `j.<name>` rewrite — but as a **mirror-time fixup**, applied on
the way out to the public mirror, leaving the private repo in the un-rewritten state. Adopting
`name: j.<name>` **natively, as the private repo's own committed state**, makes that fixup redundant
by construction: there is no orphaned doubled name left for it to repair. This is the written basis
for `E50_S16` retiring or neutralising that function. It is also the deeper point of the whole
reversal — the private repo and the public mirror now agree on which directory form exists, instead
of the mirror silently transforming one into the other.

#### Permanent exceptions — three directories keep their bare names

These three are **permanent, deliberate exceptions**. They keep their current bare directory names
and are **not deleted, not renamed, and not twinned**:

| Directory | Reason |
|---|---|
| `skills/jenga/` | Root orchestrator command, deliberately excluded from twin generation by `E50_S06` (already `Merged`). Its invocation surface must stay exactly `/jenga` / `j.jenga` — never a doubled `j-jenga`. |
| `skills/jenga-permission-level/` | Same reason and same `E50_S06` exclusion. Its surface must stay exactly `/jenga-permission-level` / `j.jenga-permission-level`. |
| `skills/index/` | Not a skill at all — it has no `SKILL.md` and is not part of routing, so it has nothing to rename and no invocation form to preserve. |

Note the consequence for the first two: because they were never twinned, bare `/jenga` and
`/jenga-permission-level` **keep working**. They are the only bare slash forms that survive, and they
survive because these directories were always the canonical ones — not because any alias was kept.

`skills/init/` / `skills/j-init/` were also historically listed as an exclusion, but only because the
pair was hand-built before `scripts/generate-j-alias.sh` existed. Under this contract they are not an
exception at all: `skills/j-init/` is simply already at its canonical name, and `skills/init/` is
deleted like every other bare-name directory.

#### Generation: the source → twin relationship no longer applies as written

`scripts/generate-j-alias.sh <skill-name>` was built to copy a bare-name source tree into a
`skills/j-<name>/` duplicate, rewriting self-referential paths and frontmatter
(`name: j.<skill-name>` → `name: j.j-<skill-name>`). Both ends of that relationship are invalidated
here: there is no bare-name source directory left to copy *from*, and the `j.j-<name>` frontmatter
value it produces is no longer canonical. Retiring or inverting that generator is **`E50_S14`'s
scope** — until it lands, do not run it against the canonical `skills/j-<name>/` directories, as it
would reintroduce the doubled frontmatter name this contract removes. The `j-<name>` directory is now
the canonical source that is edited directly, not a generated artifact kept in lockstep with another.

#### Why this reversed (one paragraph of history)

The original collision-safety rationale for `j-<name>` directories still stands and is unchanged: a
host tool shipping its own built-in command under the same bare name — the motivating case was GitHub
Copilot's own built-in `/init` — can shadow Jenga's bare `/<name>` form on the native surface, and no
frontmatter change can reach that. What changed is that maintaining **both** forms proved to be its
own failure mode. A public-mirror stage-deploy gate failure (`tests/load-playbooks-stepobject.bats`)
was traced to the private repo and the public mirror disagreeing about which directory form exists:
`.publicignore` blocklisted the canonical bare-name directories, so the mirror carried only twins,
while `skills/jenga/playbooks/brainstorm-to-mirror.json` still referenced those skills by bare name —
and `load-playbooks.sh` silently skips any playbook whose step directories don't resolve. Keeping two
parallel naming schemes is what allowed the two repos to drift apart in the first place. **One
canonical form everywhere is what prevents that entire class of bug**, and that is the decision
recorded here.

---

## Frontmatter Spec

Every `SKILL.md` begins with a YAML frontmatter block. All fields except `name` and `description` are optional.

```yaml
---
name: j.<skill-name>
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
| `name` | string | ✅ | Skill name. Canonically `j.<name>` for a skill living in `skills/j-<name>/` — e.g. `skills/j-commit/` declares `name: j.commit`. Note it is **not** `j.` + the literal directory name (that would give the rejected `j.j-commit`); strip the directory's `j-` prefix first. See "The Canonical Naming Contract" above. |
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
name: j.brainstorm
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

- A **bare string** (e.g. `"j-brainstorm"`) is unchanged, original behavior — shorthand for
  `{"skill": "j-brainstorm"}`. "Bare" here describes the **JSON shape** (a string rather than a
  `StepObject`), not a bare *skill name*: the value is always a canonical directory name, which
  under `E50_S10`'s naming contract is `j-<name>`. No migration is ever required: an all-bare-string
  playbook loads
  byte-for-byte the same as before `E53_S03`, and a bare-string step is never rewritten into an
  object form in the loader's output.

- A **`StepObject`** is a JSON object with exactly one of these two target fields (mutually
  exclusive — a step naming both, or naming neither, is rejected):
  - `skill: "<name>"` — invokes a single skill, same as a bare string.
  - `playbook: "<id>"` — composes in another playbook by ID. Full composition semantics — existence
    validation, cycle detection, and a configurable nesting-depth limit — are `E53_S05`'s scope;
    see "Playbook Composition" below.

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
    "j-brainstorm",
    {"skill": "j-todo", "forward_from": "j-brainstorm", "instruction": "capture as a task"},
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

#### `resolve`'s runtime behavior (`E53_S06`)

Everything above is validated entirely at **load time**, by `load-playbooks.sh` — it never
executes `resolve`, only checks its shape and the confirmation-gate rejection. `resolve`'s actual
**runtime** behavior is implemented as agent-facing prose in `skills/jenga/SKILL.md`'s
Natural-language branch step 5e-ii (`E53_S06_T01`), immediately after `forward_from` resolution
and before the step is invoked:

- **No-op without `forward_from`** — a step carrying `resolve` but no `forward_from` (or one that
  resolved to no forwardable value) has nothing to reshape. This is a defined, non-crashing
  behavior, never an error: the `resolve` field is simply ignored, and the step is invoked with
  whatever input it would otherwise have received.
- **The transform** — when both `forward_from` and `resolve` are present, the agent applies its
  own LLM judgment to reshape/filter/type-bridge the forwarded value per `resolve`'s
  natural-language instructions (e.g. "pick the first three items", "convert this file_list to a
  text summary"). The transformed value — never the raw forwarded value — becomes the step's
  actual invocation input.
- **Hard-fail, never silent pass-through** — if the transform cannot cleanly produce a usable,
  type-compatible result, the target step is never invoked and no differently-shaped value is ever
  guessed or passed through. Instead, `run-playbook-step.sh advance <state_file> failed "<note>"`
  is called with a note that includes the raw pre-transform value (for debugging), and the chain
  halts exactly as any other step failure would — no silent skip-ahead.

#### The named, scoped exception

This is a **deliberate, documented, scoped exception** to `CLAUDE.md`'s "Skill Implementation
Principle — Scripts Over Inline Logic": open-ended reshaping, filtering, and type-bridging
genuinely need the agent's own LLM judgment, which a deterministic script cannot provide — there is
no fixed, enumerable algorithm for "pick the first three items" or "convert this file_list to a
text summary" the way there is for, say, cycle detection or shape validation. `resolve` is never
used for anything else in this codebase's playbook mechanism. In particular, it is **never** used
to pre-authorize a downstream confirmation — that combination remains the load-time-rejected one
documented above.

This exclusion is **permanent, not deferred.** `E53_S07` ("Confirmation-Driven `resolve` (Deferred,
Safety-Gated)") was the story tracking whether `resolve` should ever gain the ability to
pre-authorize a downstream confirmation gate on the user's behalf. Its mandatory safety review
(2026-09-09) **rejected** the capability: Jenga's confirmation gates are a deliberate
human-in-the-loop safety rail, and an opt-in-per-author bypass creates risk for whoever *runs* the
playbook, who may have no visibility that a confirmation they'd expect to answer was already
silently pre-answered upstream. The review also weighed the solution assessment's own recommended
alternative (permanently reject the combination at load time, exactly as implemented here) over
the conditional alternative (ship it behind a mandatory visible marker plus a runtime override
flag) and chose the former. No future work should re-open confirmation pre-authorization without a
new, equally explicit safety review — see `E53_S07`'s story file for the full rationale.

#### `j.playbook <id>` — direct playbook invocation (`E53_S06_T03`)

`j.playbook <id>` (`skills/j-playbook/SKILL.md`) invokes a specific playbook directly by ID,
skipping `/jenga`'s natural-language matching (`detect-nl-intent.sh`/`match-playbook.sh`) entirely.
It resolves the id via `load-playbooks.sh lookup <id>` (`E53_S06_T02`), a small additive sibling to
that script's full-catalog mode, which returns a structured result distinguishing three outcomes:
`valid` (the id resolved and passed every validation pass), `invalid` (a file for that id exists
but failed validation — the specific reason is surfaced, never a generic "not found"), and
`not_found` (no file for that id exists at all). On `valid`, `j.playbook <id>` reuses
`skills/jenga/SKILL.md`'s own chain confirmation and sequential-runner steps by reference — a
`resolve` step or a composed/nested playbook reached this way behaves identically to reaching it
through `/jenga`'s natural-language branch, with no special-casing for this entry point.

### Playbook Composition

A `{"playbook": "<id>"}` step composes another playbook's own chain into this one, resolved
entirely at load time by `skills/jenga/scripts/load-playbooks.sh` (`E53_S05_T01`, cross-boundary
transparency extended by `E53_S05_T02`). That script's own header ("COMPOSITION RESOLUTION"
section) is the authoritative, most detailed reference; this is the skill-author-facing summary.

- **Existence validation** — `<id>` must resolve to a real playbook file (`<id>.json` under
  `skills/jenga/playbooks/`) that itself passes this loader's own local validation. A reference to
  a nonexistent file, or to a file that exists but fails its own validation, causes the **whole
  referencing playbook** to be dropped (stderr warning, never a hard crash) — the same
  "a chain with a broken link is not a usable chain" granularity every other check in this loader
  already uses.
- **Cycle detection** — a playbook's composition graph (its `playbook`-type steps, transitively) is
  walked depth-first; a step whose target id is already on the current resolution path — including
  a playbook composing itself directly — is a cycle, and the referencing playbook is dropped with a
  stderr warning naming the cycle.
- **Configurable nesting-depth limit** — composition may nest at most `max_composition_depth` levels
  deep, read from `project/configs/playbook-config.json` (a dedicated config file, kept separate
  from `project/configs/scope-thresholds.json`'s `/jenga`/`/do` execution-scope thresholds), and
  defaulting to **3** when the file/field is absent or invalid. This is an explicitly TUNABLE SAFETY
  DEFAULT, not an architectural ceiling — a playbook author needing a deeper composition chain
  raises the value in that config file. A composition step nested past the configured limit is
  dropped (stderr warning) before its target is even resolved.
- **Flattening and origin annotation** — a valid composition step is replaced, in place, by the
  referenced playbook's own already-resolved step sequence, recursively, so the catalog's emitted
  `steps` array for any playbook never contains a raw `playbook`-type entry. A step that came from an
  actual nested inclusion (composition depth > 1) carries two passthrough-only fields,
  `_origin_playbook` and `_origin_depth`, once spliced into a parent — a playbook's own depth-1
  (un-composed) steps are never annotated and remain byte-for-byte unchanged, preserving the
  bare-string backward-compatibility guarantee documented above for a playbook that uses no
  composition at all.
- **`forward_from`/`conditional` are transparent across composition boundaries** — because this
  loader's `forward_from`/`conditional` validation loop runs AFTER composition resolution, over the
  fully flattened step list, a step inside a composed playbook can be a `forward_from` source (or a
  `conditional.depends_on` target) for a step outside it, and vice versa, with no special-casing
  anywhere in the loader or in `/jenga`'s own dispatch logic.
- **Duplicate skill-name collisions are rejected** — every downstream script in this chain addresses
  a step purely by its resolved skill name; a flattened composition containing two or more steps
  that resolve to the same skill name is dropped with a stderr warning rather than silently
  corrupting that addressing.

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

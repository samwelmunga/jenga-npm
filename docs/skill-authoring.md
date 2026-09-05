# Skill Authoring Guide

Skills are stored in `skills/<name>/SKILL.md` and invoked with `j:<name>` in a Claude Code session —
the canonical form as of `E50_S01`. The old bare `/<name>` form keeps resolving permanently as an
alias. See "Invocation Convention" below for the mechanics and the full migration policy.

---

## Invocation Convention

`E50` namespaces every Jenga skill invocation under a `j:` prefix (e.g. `j:status`, `j:commit`,
`j:init`) to avoid collision with, or masquerading by, a same-named command from another tool or
skill installed in the same agent session. This section records the two decisions this required —
the rename mechanism and the old-form migration policy — and the investigation behind them, so the
routing-surface tasks that implement the actual cutover (`E50_S01_T02` Claude Code native,
`E50_S01_T03` Jenga Router MCP, `E50_S01_T04` Copilot/Codex templates) share one unambiguous
contract instead of each re-deciding it.

### Decision 1 — Rename mechanism: frontmatter-only, not a directory rename

**Directory names under `skills/` do not change.** Only the frontmatter `name:` field changes, from
`name: <skill-name>` to `name: j:<skill-name>`.

This deliberately breaks the invariant stated elsewhere in this guide that `name` "must match the
directory name under `skills/`". The invariant is replaced with a new one: once migrated, a skill's
frontmatter `name` equals `j:` followed by its (unprefixed) directory name — the directory name
remains the bare, on-disk identifier; the frontmatter `name` becomes the canonical, `j:`-prefixed
invocation identifier that downstream routing surfaces read.

**Why not rename the directories themselves:**
- `:` is not a valid filename character on Windows (reserved for drive letters / alternate data
  streams). This project has no `"os"` restriction in `package.json` and ships as a general-purpose
  npm package (`@jenga-ai/agent`) — it must not assume a POSIX-only install/dev surface. A directory
  literally named `skills/j:status/` would break on Windows checkouts, npm installs, and any Windows
  contributor's local clone.
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

Verified before deciding: every one of this repo's 42 `skills/*/SKILL.md` files currently has a
frontmatter `name:` that matches its directory name exactly (no pre-existing drift to reconcile).

### Decision 2 — Old bare-form migration policy: alias (not deprecation warning, not removal)

**The bare `/skill-name` form keeps resolving indefinitely, on all three routing surfaces, alongside
the new `j:skill-name` form.** No warning is emitted and no removal is scheduled by this decision.

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
indefinitely — only the new `j:`-prefixed namespace gets the `E50_S02` allow-list guard's protection.
Actually retiring the bare form would require revisiting the directory-rename tradeoff in Decision 1
(e.g. accepting a Windows-incompatible directory layout, or some other mechanism not yet designed)
and is out of scope here — a future task, not this one, if the tradeoff is ever revisited.

### What `E50_S01_T02`–`T04` inherit from this decision

Each routing-surface task implements the surface-specific mechanics of the same contract:
1. Treat a skill's canonical identifier as `j:<name>` (frontmatter `name`, once migrated).
2. Also keep matching the corresponding bare `<name>` input to the same skill record — no warning,
   no removal.
3. Never rename `skills/<name>/` or `agents/<name>` directories to include a colon.

`scripts/apply-j-prefix.sh` (this task) performs the deterministic parts of step 1 (frontmatter
rewrite) and updates bare `/<name>` prose mentions in `agents/*.md` to `j:<name>` (per the Skill
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

**How this differs from the `j:<name>` colon convention.** The colon convention (Decision 1 above) is
a frontmatter-only identifier change — no new directory, no new files. The `j-<name>` pattern is the
opposite: a real, second, on-disk directory, deliberately duplicating content rather than aliasing it,
because the collision it defends against happens at the directory-name-resolution layer the colon
convention cannot reach. The two are complementary, not alternatives — a skill keeps its `j:<name>`
frontmatter identifier *and* gains a `j-<name>` directory twin; neither replaces the other.

**Generation and sync.** `scripts/generate-j-alias.sh <skill-name>` is the only supported way to
create or update a `skills/j-<name>/` directory — per `CLAUDE.md`'s Skill Implementation Principle,
this is never hand-maintained. It copies the full `skills/<skill-name>/` tree, rewrites
self-referential path references and frontmatter (`name: j:<skill-name>` → `name: j:j-<skill-name>`),
and is idempotent and fully rebuilding on every run, so a source change is picked up in full on the
next invocation rather than incrementally patched. `E50_S05_T02` ran it once across all 41 eligible
skills; re-running it against a changed source skill is the ongoing lockstep-sync path.

**Exclusions.** `skills/init/`/`skills/j-init/` are excluded (already hand-built and paired before the
generator existed), `skills/jenga/` and `skills/jenga-permission-level/` are excluded (root
orchestrator commands — the invocation surface for these two must stay exactly `/jenga`/`j:jenga`
and `/jenga-permission-level`/`j:jenga-permission-level`, never a doubled `j-jenga` alias), and
`skills/index/` is excluded (no `SKILL.md` — not a skill, not part of routing).

---

## Frontmatter Spec

Every `SKILL.md` begins with a YAML frontmatter block. All fields except `name` and `description` are optional.

```yaml
---
name: <skill-name>
description: <one-sentence description shown in j:help listings>
metadata:
  prefered_agent: <agent_name>       # optional — delegate execution to a sub-agent
keywords:                            # optional — short phrases for keyword routing
  - "<phrase 1>"
  - "<phrase 2>"
examples:                            # optional — natural-language prompts for semantic routing
  - "<example prompt 1>"
  - "<example prompt 2>"
minimum_permission_level: <1-5>       # optional — minimum session permission level required to run this skill
---
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | ✅ | Skill name. Before `E50_S01` migration: must match the directory name under `skills/`. After migration: `j:` + the directory name — see "Invocation Convention" above. |
| `description` | string | ✅ | One-sentence description shown in `j:help` listings and the skill registry. |
| `metadata.prefered_agent` | string | ❌ | Sub-agent to delegate execution to. Valid values: `scrum-master`, `developer`, `tester`. |
| `keywords` | string[] | ❌ | Short words or phrases (1–3 words) strongly associated with this skill. Used by the Jenga Router for keyword matching. |
| `examples` | string[] | ❌ | Natural-language prompt strings that should trigger this skill. Used by the Jenga Router for semantic matching. |
| `minimum_permission_level` | integer | ❌ | Minimum session permission level (`1`-`5`) required to run this skill. Skills that set this field must gate execution via `scripts/check-permission-level.sh`. |

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

An optional integer (`1`-`5`) declaring the minimum session permission level a skill needs to run correctly. This corresponds to the 5-tier system defined by the `j:jenga-permission-level` epic: `1` = Locked, `2` = Guarded (the permanent default), `3` = Standard, `4` = Elevated, `5` = Unrestricted. See the level matrix under `templates/permission-levels/` for what each tier permits.

Set this field only when a skill genuinely cannot complete its work at the default Guarded (2) level — e.g. it needs to run commands that Guarded denies. Most skills should omit this field entirely and run at the default level.

**Guidelines:**
- Use the lowest level that actually satisfies the skill's needs — never request more than necessary.
- Skills that set this field **must** call `scripts/check-permission-level.sh <minimum-level>` at the top of their instructions, before any other work, to gate execution on the current session level.
- If the current session level is below the declared minimum, the skill must surface an explicit confirmation prompt to the user before elevating — silent auto-elevation is never permitted.
- Elevation happens via the same mechanism as `j:jenga-permission-level <n>` (i.e. the skill drives the same level switch, it does not invent a separate one).
- Immediately after the skill's own work completes, reset the session level back to Guarded (2) — regardless of what level it was elevated to. Elevation must never be held past the skill's own execution, and must never be left for the next session start to clean up.
- Do not use this field to hold a session at an elevated level across multiple skills or commands — each elevation is scoped to a single skill invocation.

**Example:**
```yaml
minimum_permission_level: 4
```

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
- Reference board paths via `$(bash scripts/board_resolver.sh)` rather than hard-coding them.

---

## Threat Model — the `j:` Allow-List Guard

The `j:` skill allow-list guard (`E50_S02`) checks whether a `j:`-prefixed invocation matches a
canonical list of genuine Jenga skill identifiers before treating it as trusted.

**In scope.** The guard prevents an unrelated or malicious skill from adopting the `j:` prefix and
being invoked as though it were a genuine Jenga skill — it defends the **invocation-matching layer**
against name-collision and masquerading.

**Explicitly out of scope.** The guard does **not** sandbox, scan, or otherwise verify the *content*
of a third-party skill file. A skill whose identifier doesn't collide with anything on the allow-list,
or one installed under a name that legitimately isn't `j:`-prefixed, is neither made safer nor less
safe by this guard — content-level trust of any skill, Jenga's own or third-party, is a separate,
unaddressed concern.

This residual risk is a deliberate scope boundary of `E50_S02`, not an oversight.
- Keep the skill body focused on *what to do*, not *how Claude works*.

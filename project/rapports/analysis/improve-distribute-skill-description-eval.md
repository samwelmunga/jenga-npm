# Evaluation Rapport: improve-distribute-skill-description

## Goal
Improve the description of the `/distribute` skill — what it is, when to use it, and how to set it up — so that a new user encountering the skill for the first time fully understands the concept, the use-cases, and the required configuration.

## References
`.agents/skills/distribute/SKILL.md`, `project/.wiki/documentation.md` (lines 595–620), `.agents/hooks/distribute-changes.sh`, `.jenga_paths.example`

## Observations

### `.agents/skills/distribute/SKILL.md`
The SKILL.md frontmatter description reads: *"distribute the latest workflow changes to all consumer projects registered in .jenga_paths. Detects projects via jenga.config.json, respects .jenga_ignore per project, and prints a summary."* This is mechanically accurate but conceptually thin — it describes the mechanism without explaining the mental model. A user who has never used `/distribute` doesn't know what "consumer projects" means, why they would have multiple projects using the same workflow, or what `jenga.config.json` represents. The instruction body is detailed and operationally complete (release types, dry-run, flags, failure handling), but it assumes the setup is already in place — there is no onboarding section explaining how to configure `.jenga_paths`, what a consumer project needs in its `jenga.config.json`, what `target_dir` is, or when you'd reach for this skill over other options.

### `project/.wiki/documentation.md` — `/distribute` section
The wiki entry adds slightly more context ("After improving the workflow… wanting to sync those changes to projects that use this workflow") and includes a concrete example trace. However:
- **"What it is" is absent at the conceptual level.** There is no explanation of the distributed-workflow model — that JengaAgent can be used as a shared, versioned workflow layer across a team's projects, and `/distribute` is the mechanism for keeping all those projects current.
- **Setup instructions are entirely missing.** No mention of how to create `.jenga_paths`, what needs to be in a consumer project's `jenga.config.json` (`workflow_version`, `target_dir`), or what `.jenga_ignore` is for. A new user would have no idea how to get started.
- **"When to use" is one sentence** and doesn't distinguish from alternatives (e.g., `amend` vs versioned releases, or why you'd use `--force`).

### `.agents/hooks/distribute-changes.sh`
The script reveals the actual model clearly: it reads absolute paths from `.jenga_paths`, scans each path for directories containing `jenga.config.json` at up to 2 levels deep, copies a defined set of workflow items (`bin`, `lib`, `scripts`, `agents`, `hooks`, `mcp`, `skills`, `templates`, `settings.json`) into each consumer project's `target_dir`, and skips or warns if the consumer's `workflow_version` is ahead. This mental model — a *single master workflow repo distributing versioned snapshots to N consumer projects* — is nowhere expressed in prose anywhere in the documentation.

### `.jenga_paths.example`
This file is the closest thing to a setup guide and it is never referenced from anywhere in the skill description, wiki, or intro guide. It explains the path format clearly but is buried and undiscoverable.

## Gaps & Issues

- **No conceptual explanation of the distributed-workflow model** — the idea that JengaAgent can act as a shared, versioned workflow layer across multiple projects is the core value proposition of `/distribute` and it is never stated anywhere.
- **Zero setup documentation** — nowhere does any user-facing file explain: (1) create `.jenga_paths`, (2) each consumer project needs a `jenga.config.json` with `target_dir` and `workflow_version`, (3) optionally create `.jenga_ignore`. A first-time user cannot use this skill without reverse-engineering the shell script.
- **`target_dir` is never explained** — this is the most critical config field in a consumer project's `jenga.config.json` and it appears nowhere in documentation or the SKILL.md instructions.
- **SKILL.md frontmatter `description` is routing-hostile** — it uses implementation jargon (`.jenga_paths`, `jenga.config.json`) before the concept is established, making the skill hard to discover via `/route` or `/help`.
- **`amend` vs versioned releases distinction is under-explained** — documentation mentions it but doesn't clearly say: use `amend` to quietly onboard a new project or fix a missed file without incrementing version; use `patch/minor/major` to broadcast a versioned upgrade to all registered consumers.
- **`.jenga_paths.example` is never linked** — the primary onboarding artifact for setup is completely hidden.
- **No dedicated concept card** in `.wiki/concepts/` for workflow distribution (unlike other concepts such as `session-continuity`, `board-hierarchy`, etc.).

## Score
**Score**: 2/5
**Justification**: The skill is operationally complete for someone who already knows how it works, but entirely fails to onboard a new user — the distributed-workflow mental model, setup steps, and key config fields are all absent from every user-facing surface.

## Summary
`/distribute` has a functioning implementation and reasonable operational instructions, but its descriptions across SKILL.md, the wiki, and the intro guide treat it as a power-user command rather than explaining what it is and why it exists. The most critical missing pieces are: a one-paragraph conceptual explanation of the distributed-workflow model, a step-by-step setup guide (`.jenga_paths`, `jenga.config.json` with `target_dir`, `.jenga_ignore`), and a clearer "when to use which release type" guide. Fixing these three areas would transform `/distribute` from an undiscoverable command into a well-understood, self-service feature.

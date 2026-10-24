# Strategy Brief

> **Audience:** Investors and strategic partners.
> This document describes the strategic direction of Jenga AI. It does not include revenue models, pricing, or competitive analysis.

---

## Vision

Jenga AI's vision is to become the standard meta-framework for structured agentic software development — making it as easy to deploy a disciplined, multi-agent engineering workflow as it is to install a package.

We believe that AI-assisted development reaches its full potential only when it is structured: with clear roles, bounded responsibilities, a shared project board, and auditable communication between agents. Jenga AI provides that structure out of the box.

---

## Value Proposition

Jenga AI gives software teams a production-ready agentic workflow without building one from scratch.

Instead of a single AI assistant operating on an ad-hoc basis, Jenga AI provides:

- **Role-bounded agents** — scrum master, developer, tester, and AI engineer each with exclusive write permissions and defined responsibilities
- **A skill library** — over thirty slash-command skills covering planning, execution, review, publishing, documentation, and maintenance
- **A structured project board** — epics, stories, and tasks tracked as version-controlled Markdown files with strict frontmatter schema
- **npm distribution** — install into any project with `npm install jenga-agent`; postinstall wires up agents, skills, hooks, and scripts automatically

The result is an engineering team that can delegate complex, multi-step implementation work to agents with confidence that it will be planned, reviewed, tested, and committed in a repeatable, auditable way.

---

## Scope

### In Scope

- The agent definitions (scrum-master, developer, tester, ai-engineer) and their communication contract
- The skill library (`/do`, `/jenga`, `/publish`, `/doc`, `/train`, and all others in `skills/`)
- The project board system: epic/story/task schema, board files, queue, and rollup logic
- Script infrastructure for CI, board operations, validation, and session lifecycle hooks
- npm packaging and distribution via the `/publish` skill
- Documentation tooling: `/doc`, `/doc-sync`, the path-objectives registry, and this convention

### Out of Scope

The following are explicitly outside the scope of this document and of Jenga AI itself:

- Revenue model, pricing strategy, or monetisation plans
- Competitive analysis or feature comparison with other tools
- Internal financial projections

---

## Target Audience

Jenga AI is built for:

- **Software engineering teams** who want structured, auditable AI-assisted development workflows without building the scaffolding themselves
- **AI/ML engineers** who need a disciplined pipeline for model training jobs, evaluation, and iteration alongside a working software project
- **Claude Code users** who want to move beyond single-assistant sessions into a multi-agent, role-bounded workflow
- **Developer tooling authors** who want to distribute their own skill libraries or agent configurations via the Jenga AI extension model

---

## Off-npm Discovery Channels

npm ranking follows download volume, and download volume is driven off-registry. This table is the durable tracker for those channels (story `E41_S06`). Rules below were noted from general knowledge of each platform and should be re-checked at the channel's own rules page before posting. Marketplace-specific research is tracked separately in `E41_S06_T02`.

| Channel | Owner | Status | Target date | Submission rules | Pursue/Skip |
|---|---|---|---|---|---|
| Claude Code plugin marketplace | maintainer | Not started | TBD | TBD, researched in E41_S06_T02 (submission format, review process, package fit) | Pursue: highest-intent audience, already searching for exactly this |
| GitHub `awesome-*` lists | maintainer | Not started | TBD | One PR per list (e.g. awesome-claude-code, awesome-ai-agents); follow each repo's CONTRIBUTING and entry format, alphabetical or category placement | Pursue: free, durable backlinks and low effort per list |
| Reddit | maintainer | Not started | TBD | Per-subreddit self-promotion rules (r/ClaudeAI, r/LocalLLaMA); read sidebar first, many cap self-promo to a small share of posts | Pursue: relevant communities, but only with a substantive post and after reading each ruleset |
| X / Bluesky | maintainer | Not started | TBD | No approval process; a launch thread with E38 scenario transcripts and terminal casts as media | Pursue: no gate, reuses E38 assets, but low reach without an existing following |
| Dev.to / Hashnode | maintainer | Not started | TBD | Self-publish; long-form "why we built this" post with canonical URL set when cross-posting | Pursue: both index well in Google and the post is reusable elsewhere |
| Show HN | maintainer | Not started | TBD | Title prefixed "Show HN:", must be something people can try, no vote solicitation; one shot per project in practice | Skip for now: one-shot channel, revisit once docs and E38 scenarios are strong |

## Claude Code plugin marketplace: submission requirements

> Research for `E41_S06_T02`, fetched 2026-10-21. This section expands the "Claude Code plugin marketplace" row of the off-npm channels table created by `E41_S06_T01` (that table lives on a separate branch and is intentionally not duplicated here; link or merge this section under that row).
>
> Confidence tags: **[primary]** = the claim comes from a page fetched in full from Anthropic's official docs; **[excerpt]** = seen only in a web-search result excerpt; **[repo]** = verified by inspecting this repository; **[inference]** = our reading, not stated by the docs. Doc URLs below are the ones fetched; Anthropic edits these pages often, so re-check before acting.

### Summary

- There are three distinct routes, and only two are open to us: (1) our own self-hosted marketplace (no review, available immediately), (2) a listing in Anthropic's directory via the developer portal (reviewed), and (3) the official `claude-plugins-official` marketplace (not open to submissions; partner contact only).
- `@jenga-ai/agent` does **not** qualify as-is for any of them. It ships as an npm package whose `postinstall` copies skills into the consumer project; a plugin needs a plugin-root layout, a `.claude-plugin/plugin.json`, and self-contained paths. Estimated changes are listed under "Package structure fit".

### 1. Submission format

| Claim | Source | Confidence |
|---|---|---|
| A marketplace is a repo/dir with `.claude-plugin/marketplace.json`; required top-level fields are `name`, `owner`, `plugins[]`; each plugin entry needs `name` and `source`. Publishing to your own marketplace needs no submission form: once the file is in a git repo, the plugin is published. | [Create a marketplace](https://code.claude.com/docs/en/plugin-marketplaces), [Publish](https://code.claude.com/docs/en/plugins/publish) | [primary] |
| Plugin `source` can be a relative path, `github`, `git-subdir`, `url`, `archive`, `npm`, or `command`. Users add it with `claude plugin marketplace add <owner>/<repo>` then `claude plugin install <name>@<marketplace>`. | [Create a marketplace](https://code.claude.com/docs/en/plugin-marketplaces) | [primary] |
| `plugin.json` lives at `.claude-plugin/plugin.json`; only `name` is required (kebab-case). Recommended: `description`, `version`, `author`, `homepage`, `repository`, `license`. Listing fields `icon`, `documentationUrl`, `supportUrl`, `privacyPolicyUrl`, `termsOfServiceUrl` are read by Anthropic's directory only. The manifest itself is optional; defaults are discovered from the standard layout. | [Manifest reference](https://code.claude.com/docs/en/plugins-reference) | [primary] |
| Anthropic's directory submission is made in the developer portal at claude.ai/directory/manage ("Submit new" then "Plugin bundle"), from a **public GitHub repository**; the portal's Validate step checks the repo before submission. | [Publish](https://code.claude.com/docs/en/plugins/publish), [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| Skills are not a standalone submission type; they must be inside a plugin bundle. | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| Local pre-check: `claude plugin validate --strict ./plugin`. The portal applies extra rules the CLI does not check. | [Publish](https://code.claude.com/docs/en/plugins/publish), [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |

### 2. Review process and turnaround

| Claim | Source | Confidence |
|---|---|---|
| Own marketplace: no review at all. Anthropic does not review third-party marketplaces. | [Publish](https://code.claude.com/docs/en/plugins/publish), [Anthropic's marketplaces](https://code.claude.com/docs/en/plugins/anthropic-marketplaces) | [primary] |
| Directory: every plugin version gets automated validation plus a security scan; a person reviews a **new listing** before it goes live. A first submission failing the security scan is rejected; later versions that fail cannot go live. Findings are Blocks / Policy hold (a reviewer reads it) / Warning / Note. | [Publish to the directory](https://claude.com/docs/directory/publish), [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |
| **Turnaround: not stated.** "Review time isn't fixed"; status is shown in the portal. Do not plan around a number. | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| Submitter needs a paid claude.ai plan (Pro, Max, Team, Enterprise); the listing belongs to the submitting organization, and the first organization to submit a repo folder owns it. | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| After approval, updates need no resubmission: the directory follows the tracked branch/tag, scans each new commit, and serves it once published. | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| Every listing is subject to the Anthropic Software Directory Terms and Software Directory Policy (not fetched; read before submitting). | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary for existence, content not read] |

### 3. Official vs community vs directory (which channel is realistic)

| Marketplace | How a plugin gets in | Source | Confidence |
|---|---|---|---|
| `claude-plugins-official` (auto-added to Claude Code) | Does **not** take submissions through the directory portal; "if you work with an Anthropic partner contact, ask them". | [Publish](https://code.claude.com/docs/en/plugins/publish), [Anthropic's marketplaces](https://code.claude.com/docs/en/plugins/anthropic-marketplaces) | [primary] |
| `claude-community` (`anthropics/claude-plugins-community`) | Third-party plugins submitted to Anthropic; read-only mirror, submissions via clau.de/plugin-directory-submission per the repo description. The current docs route submissions through the developer portal instead (the earlier forms are being retired), so treat the clau.de form as possibly stale. | [Anthropic's marketplaces](https://code.claude.com/docs/en/plugins/anthropic-marketplaces); repo description in search excerpt | [primary] for the marketplace; [excerpt] for the clau.de form |
| Anthropic directory (claude.ai/directory, `/plugin directory`) | Developer portal submission above; installs reach Claude Code as `<name>@synced` via account sync. No separate "Claude Marketplace" submission exists. | [Publish](https://code.claude.com/docs/en/plugins/publish), [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| "Anthropic verified" label | No application; Anthropic decides during review. | [Anthropic's marketplaces](https://code.claude.com/docs/en/plugins/anthropic-marketplaces), [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |

Recommended order (our inference): (a) self-host a marketplace from the public repo now (zero review, zero blockers beyond the layout work below); (b) submit to the directory once the plugin layout passes the portal's Validate; (c) do not plan on `claude-plugins-official`.

### 4. Package structure fit: does `@jenga-ai/agent` qualify as-is?

**Verdict: no. It needs a plugin-shaped packaging, not a rewrite.** Plugin layout per the manifest reference [primary]: `.claude-plugin/plugin.json` plus `skills/`, `agents/`, `hooks/hooks.json`, `scripts/` at the **plugin root**; everything the plugin runs must be inside the plugin folder; files outside the plugin directory are not copied into the cache; component paths must start with `./` and may not escape the root ([Manifest reference](https://code.claude.com/docs/en/plugins-reference), [Plugin loading](https://code.claude.com/docs/en/plugins/loading)).

Findings against this repository (all **[repo]** unless noted):

| Area | Repo today | Gap |
|---|---|---|
| Manifest | No `.claude-plugin/` directory exists. `package.json` is the only manifest. | Add `.claude-plugin/plugin.json` (name, version, description, author, license `Apache-2.0` is already in `LICENSE`, homepage, repository). A hand-maintained second version source needs a sync/test. |
| Skills | 56 entries under `skills/` (55 `j-*`/jenga skills with `SKILL.md`, plus `index/` with no `SKILL.md`), 275 files, 3.2 MB, all text, no file over 256 KiB. The standard `skills/<name>/SKILL.md` shape already matches. | Directory names are `j-<name>` while frontmatter is `name: j.<name>`. Plugin skills are namespaced `<plugin-name>:<skill>` [primary]; whether the namespace uses the directory name or the frontmatter `name` was **not verified** and the resulting invocation (`/jenga-ai:j-commit`-style vs `j.commit`) must be tested with `claude --plugin-dir`. The `j.<name>` / `/j-<name>` invocation convention in CLAUDE.md would change inside a plugin. |
| Agents | `agents/` has 6 `.md` files at the root (developer, tester, scrum-master, ai_engineer, scrutiny-agent, solution-assessor). Default `agents/` scan matches. | Agents appear namespaced (`<plugin>:developer`) [primary]; any skill text that dispatches `developer`/`tester` by bare name needs checking. Agents load in Claude Code and Cowork, not claude.ai chat [primary, platform-support]. |
| Hooks | Hooks are defined in root `settings.json` (and six permission-level copies), not `hooks/hooks.json`. `hooks/` holds scripts only. WorktreeCreate/WorktreeRemove/SessionEnd/PreToolUse are wired there. | Need a `hooks/hooks.json` with a top-level `hooks` key using `${CLAUDE_PLUGIN_ROOT}`. Whether plugin hooks support every event we use (notably `WorktreeCreate`/`WorktreeRemove`, which replace default worktree behavior) was **not verified**; the hooks reference page was not fetched. Plugins also cannot set permission modes/`permissions.deny` in `settings.json` (only `agent` and `subagentStatusLine` take effect [primary]), so the 5-tier permission-level system and the PreToolUse registration "in six files" would not carry over. |
| Paths | 16 SKILL.md files (46 lines) invoke scripts via `node_modules/@jenga-ai/agent/scripts/...`, and 56 files under `skills/` reference `node_modules/@jenga-ai/agent`; many scripts read `$JENGA_PROJECT_DIR`/`$CLAUDE_PROJECT_DIR`. 77 files in root `scripts/`, plus `lib/`, `templates/`, `mcp/` outside the skills tree. | Under a plugin, the install root is `${CLAUDE_PLUGIN_ROOT}` (cache path that changes per version), not `node_modules/@jenga-ai/agent`. The 46 script references need a resolver or a plugin-specific rewrite. Content shared via `../` is rejected, and the directory checklist requires hook/MCP commands to use `${CLAUDE_PLUGIN_ROOT}/<file>` with no other variables [primary]. The existing `$([ -f scripts/x ] && echo scripts/x || echo node_modules/...)` fallback pattern is not plugin-aware. |
| Install lifecycle | `postinstall` (`scripts/postinstall.js`) mirrors skills/agents into `<consumer>/.claude/` and `.agents/`, and is documented as load-bearing. | Plugins have no postinstall equivalent. Claude Code installs Node dependencies only from a lockfile with `--ignore-scripts` [primary]; nothing like the mirror runs. The mirror, manifest-based upgrade cleanup, and `.jenga-version` logic are unnecessary in a plugin but anything the framework expects at `<project>/.claude/` would be missing. |
| Repo content | Repo root also has `project/` (board, app with UI dist), `tests/`, `jobs/`, `site/`. | The plugin folder is a subfolder or a dedicated repo; the public mirror (`jenga-npm`) is the candidate source. A plugin-only subfolder triggers the stricter "scripts the validator couldn't follow" hold [primary]. Keeping the plugin at the root of its own repository avoids that hold. |
| Dashboard / MCP | `mcp/*` servers and `project/app` are packaged in npm. | MCP servers must be declared with `command`+`args` or `url`, not `.mcpb`; local MCP servers do not run in claude.ai chat [primary]. Optional for a first release. |

Estimated work (our inference, not stated by Anthropic): plugin manifest and marketplace file are small; the real cost is the path model (48 skills plus scripts), the hooks/permissions model, and the loss of the `postinstall` mirror. A thin "Jenga lite" plugin (skills and agents only, hooks and permission tiers omitted) is the cheapest first step.

### 5. Other hard prerequisites (directory route)

| Prerequisite | Source | Confidence |
|---|---|---|
| Plugin repo must be a **public GitHub repository** before the listing goes live. Our private monorepo is not eligible; the public mirror `jenga-npm` is the natural source. | [Publish to the directory](https://claude.com/docs/directory/publish) | [primary] |
| README of at least 40 words (code blocks excluded) in the plugin folder, and a license (a `LICENSE` file or `license` in `plugin.json`); both **block** if missing. We already ship `LICENSE` (Apache-2.0) and `README.md`. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |
| Name rules: lowercase, digits, hyphens, at most 64 chars; must not be reserved (`claude`, `anthropic`, `official`, `plugin`, `mcp`, `test`) or start with `claude-`, `anthropic-`, `cc-plugin-`; must be unique across organizations; names matching a known brand are held for review. A name like `jenga` or `jenga-ai` is likely fine but uniqueness against existing listings is **unchecked**. Name is effectively permanent once published. | [Manifest reference](https://code.claude.com/docs/en/plugins-reference), [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist), [Publish](https://code.claude.com/docs/en/plugins/publish) | [primary] |
| Per-file limits: files over 256 KiB (non-image/font), more than 512 files, or any non-text/non-image binary are **held for a reviewer**. Our `skills/` is 275 files, 3.2 MB total, all under 256 KiB, but `skills/`, `agents/`, `hooks/`, `scripts/`, `lib/` and `templates/` together are already about 430 files ([repo], counted 2026-10-21), leaving under 100 files of headroom before the 512-file reviewer hold; adding `mcp/` would likely cross it. Repository hard limits: under 50 MiB archived, under 10,000 files, each plugin-folder file under 5 MiB. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] for limits; [repo] for sizes |
| `package.json` plus `package-lock.json`/`npm-shrinkwrap.json` at plugin root is always held for reviewer; `npx`/`uvx` launchers must be pinned to exact versions; `.npmrc`-style registry config blocks with a launcher. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |
| Security scan flags undisclosed network sends, hidden code, or permission-setting changes; compiled/minified code is held. Our hooks write queue/log files and run shell on `PreToolUse` and `SessionEnd`; the README must describe this. The dashboard UI bundle (`project/app/ui/dist`) would be minified code and should stay out of the plugin. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary]; applicability to our hooks is [inference] |
| No credentials in any file; secrets via `userConfig` with `sensitive: true`. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |
| Commit regular files only (no symlinks, submodules, LFS pointers); no `.DS_Store`/`__MACOSX`; no `.gitattributes` with `export-ignore`/`filter`. | [Pre-submission checklist](https://claude.com/docs/plugins/pre-submission-checklist) | [primary] |
| Executables in a top-level `bin/` cannot be installed on claude.ai or Cowork (Claude Code only). Our `bin/jenga.js` is not at plugin level so no conflict unless moved. | [Platform support](https://claude.com/docs/plugins/platform-support) | [primary] |

### 6. Open questions to resolve before committing to this channel

1. Skill invocation form under the plugin namespace (directory name vs frontmatter `name`) - test with `claude --plugin-dir`.
2. Whether plugin hooks support `WorktreeCreate`/`WorktreeRemove` and `PreToolUse` with the same semantics as `settings.json` (hooks reference page not fetched).
3. Whether the framework can run without the `<project>/.claude/` mirror that `postinstall` creates.
4. Final plugin name and its uniqueness in the directory.
5. Directory Policy text (Anthropic Software Directory Policy) was not read.
6. Whether the first-run experience matches: the plugin cache is per version, so project-local `project/` scaffolding (`j.init`) is unaffected, but `${CLAUDE_PLUGIN_ROOT}` changes on each update.

### Sources

- https://code.claude.com/docs/en/plugin-marketplaces
- https://code.claude.com/docs/en/plugins-reference
- https://code.claude.com/docs/en/plugins/publish
- https://code.claude.com/docs/en/plugins/anthropic-marketplaces
- https://code.claude.com/docs/en/plugins/loading
- https://claude.com/docs/directory/publish
- https://claude.com/docs/plugins/pre-submission-checklist
- https://claude.com/docs/plugins/platform-support
- https://github.com/anthropics/claude-plugins-community (search excerpt only)

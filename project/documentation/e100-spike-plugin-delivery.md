# E100_S01_T03 spike: plugin delivery of hooks

**Time box: 2 hours.** Actual time spent: about 25 minutes (stopped early; all three questions answered to the extent the
sources allow). Retrieved 2026-11-19, Claude Code 2.1.236. Builds on `e100-findings-docs.md` (T01) and does not repeat it.
Labels: `confirmed by test`, `confirmed by official docs` (URL, 2026-11-19), `still unknown`. No answer rests on the epic's notes.

Sources: S = https://code.claude.com/docs/en/settings, H = https://code.claude.com/docs/en/hooks,
PR = https://code.claude.com/docs/en/plugins-reference, CLI = https://code.claude.com/docs/en/plugins/cli-reference,
CP = https://docs.github.com/en/copilot/reference/hooks-configuration, CX = https://learn.chatgpt.com/docs/hooks.

## Test method and safety

Throw-away fixture under the session scratchpad (`.../scratchpad/e100t03/`): a local marketplace with one plugin that ships
`hooks/hooks.json`, a fixture project whose `.claude/settings.json` holds a client-owned `enabledPlugins` entry, a hook and an
allow rule, with `CLAUDE_CONFIG_DIR` and `HOME` pointed into the scratchpad. No real settings file was written. SHA-256 of
this repo's `settings.json`, `.claude/settings.json` and `.agents/settings.json` (identical, `99262a13...ea95`) was recorded
before and after: unchanged. `~/.claude/settings.json` and `~/.claude.json` were not hashed (the sandbox denied the command that
included them); the test used a redirected `HOME`/`CLAUDE_CONFIG_DIR`, so they were not reachable by it, but that is not
independently proven by a checksum.

## Q1. Can an `enabledPlugins` entry be added safely?

**Yes, through the CLI; confirmed by test.** `claude plugin install spike-plug@spike-mkt --scope project` added
`"spike-plug@spike-mkt": true` next to the client's own `"client-own@somewhere": true`, leaving the client's `hooks` and
`permissions.allow` content intact. `claude plugin disable ... --scope project` set the entry to `false`; `claude plugin
uninstall ... --scope project` removed exactly that entry and nothing else. So additive write and defined removal both work.
Caveats from the test: the CLI re-serialises the file (key order changed, `enabledPlugins` moved to the end), so a byte-level
"client file unchanged" invariant cannot hold; and install requires a marketplace declared first (here `marketplace add`, which
itself writes `extraKnownMarketplaces` or the user scope). Docs: `--scope` names the settings file written, and `enable`/`disable`
at a higher-precedence scope write an override (CLI, confirmed by official docs). A project `enabledPlugins` is also subject to
folder trust and is not honoured in cloud sessions for marketplaces (S, "Settings in cloud sessions"). Hand-editing the JSON
instead of using the CLI: still unknown whether a plugin enabled that way without install loads (not tested).

## Q2. What happens to the preflight backstop if the plugin is disabled or `allowManagedHooksOnly` is set?

**Enforcement disappears silently in both cases; it can be detected only by reading state, not by an error.**

- Disabled plugin: docs say hooks merge "when a plugin is enabled" (H, "Plugin hooks"). That a disabled plugin's hooks do not run
  is the docs' implication, not a quoted rule (confirmed by official docs, inferred). Test: after `disable`, `enabledPlugins` shows
  `false`; Claude Code emits no warning at that point in the CLI output. Whether a running session notices only after
  `/reload-plugins`: S/CP say plugin changes need a reload (T01 finding 5).
- `allowManagedHooksOnly` (managed settings only): "Your user, project, local, and plugin hooks are blocked", except hooks of plugins
  force-enabled in managed `enabledPlugins`; plugins with a `command` source are disabled too (H; confirmed by official docs, 
  quoted by the fetch tool, the page was read only up to character 100000). Not tested: it needs a managed settings file in a
  system directory, which the hard rules forbid touching.
- **Can the plugin route silently switch off the backstop that `E89_S06` holds at every permission level? Yes.** The six-file
  invariant guarantees the hook is in the settings files; a plugin-carried hook is outside that guarantee, and either a
  `false` entry or a managed policy removes it with no error. Today's settings-file route is also dropped by `allowManagedHooksOnly`
  (user/project hooks are blocked there too), so that policy is not unique to plugins, but the plugin route adds the
  disable path a user can take with one command.
- What a doctor check would need to read: (1) `claude plugin list --json` and the `enabled` field for the carrying plugin
  (test confirmed: it reports `id`, `scope`, `enabled`, `installPath`, `projectPath`); (2) `enabledPlugins` merged across the
  four scopes (a `false` at a higher scope wins); (3) the managed settings sources for `allowManagedHooksOnly` and
  `strictPluginOnlyCustomization` (docs name them as Managed-scope keys); (4) as a ground truth, `/hooks` lists each live hook
  with its origin (H) but is interactive and read-only, so it is not scriptable; a scripted equivalent is `still unknown`.
  A direct behavioural probe (run a gated command, see whether `hooks/on_preflight_check.sh` fires) would be stronger; not tested.

## Q3. Effect on Copilot and Codex

- Copilot CLI: hook sources are policy, `.github/hooks/*.json`, `.github/copilot/settings.json`, user files and "each plugin's own
  `hooks.json`"; it also reads "Cross-tool `.claude/settings.json` and `.claude/settings.local.json` files in the repository"
  (CP, confirmed by official docs). `.agents/` is not mentioned. Whether Copilot reads Claude's `enabledPlugins` or resolves
  Claude plugins: `still unknown` (the page does not say). In cloud Copilot only `.github/hooks/*.json` loads; no plugins.
- Codex: hooks from `/etc/codex/hooks.json`, `~/.codex/hooks.json`, `.codex/hooks.json`, `requirements.toml`, and "hooks bundled in
  enabled plugins" (CX, confirmed by official docs). It does not mention `.claude/`, `.agents/` or `enabledPlugins`; a Claude
  `enabledPlugins` entry therefore has no documented effect on Codex. It sets `CLAUDE_PLUGIN_ROOT` for compatibility, which hints
  at shared plugin format but is not a delivery path.
- Conclusion: an `enabledPlugins` entry in `.claude/settings.json` is the Claude Code route only. Copilot and Codex would each need
  their own plugin install, so the plugin route does not remove the per-client work; it adds a third surface. (Note: this repo's
  own `hook-parity.md` records Copilot hooks at `.github/hooks/jenga.json`, consistent with CP.)

## Recommendation

**Continue as a later, non-main track; do not open a separate epic now and do not drop it.** Reason: Q1 shows the additive,
removable write works, which keeps the option open; Q2 shows a plugin-carried preflight backstop can be disabled silently, so it
must not carry the backstop (keep that in the settings files, per `E89_S06`); Q3 shows no cross-client benefit. If revisited,
scope it to non-enforcement hooks (for example the workflow-recorder hook) behind a doctor check on `claude plugin list --json`.
This does not alter `E100_S02` to `E100_S06`.

## Not verified

Behaviour of `allowManagedHooksOnly` (not run); whether a disabled plugin's hooks stop in a live session (docs-inferred only);
hand-edited `enabledPlugins` without install; scriptable equivalent of `/hooks`; Copilot reading `enabledPlugins`; the settings
reference entries for `enabledPlugins` (the reference is 458580 characters; the entries were not reached in the 0-300000 read);
checksums of `~/.claude/settings.json` and `~/.claude.json`.

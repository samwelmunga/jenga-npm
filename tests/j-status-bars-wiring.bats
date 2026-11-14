#!/usr/bin/env bats
#
# E92_S05_T05: j.status shows the render-status-bars.sh bar on every epic and story row, and changes nothing else.
# E92_S06_T26: the default path of j.status is now the T24 overview (skills/j-status/scripts/resolve-status-mode.sh picks the
# renderer); the bars of step 6.9 belong to the LEGACY path (`j.status --legacy`, `--all`), and the tests at the end assert both.
# Static checks on skills/j-status/SKILL.md and skills/j-status/assets/output_format.md. The banner lines and the Status
# Icons table below are the literal values at task start (commit 844cd602); the layout contract must keep them byte-identical.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO/skills/j-status/SKILL.md"
  FMT="$REPO/skills/j-status/assets/output_format.md"
  RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

@test "SKILL.md runs render-status-bars.sh once, with the dual-path idiom, and names it as the only source of the bars" {
  [ "$(grep -c 'bash "\$(\[ -f skills/j-status/scripts/render-status-bars.sh \] && echo skills/j-status/scripts/render-status-bars.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/render-status-bars.sh)"' "$SKILL")" -eq 1 ]
  grep -q 'only\*\* source of the bars' "$SKILL"
}

@test "SKILL.md step 6.9 sits between step 6.8 and step 6.10, and 6.5, 6.7 and 6.8 keep their commands" {
  run grep -n '^6\.[0-9]*\. \|^7\. ' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed 's/^\([0-9]*\):\([0-9.]*\)\..*/\2/' | tr '\n' ' ')" = "6.5 6.7 6.8 6.9 6.10 7 " ]
  grep -qF 'bash "$([ -f scripts/mark-deployed.sh ]' "$SKILL"
  grep -qF 'bash "$([ -f scripts/check-todo-format.sh ]' "$SKILL"
  grep -qF 'bash "$([ -f scripts/audit-status.sh ]' "$SKILL"
}

@test "SKILL.md holds no counting or drawing logic for the bars" {
  run grep -Eq '█|░|━|╌|⚑|#####|printf|awk|seq |\$\(\(|jq |bc ' "$SKILL"
  [ "$status" -eq 1 ]
  run grep -Eq 'board-progress\.sh|render-progress-bar\.sh' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "SKILL.md states the fallback: no output or an unavailable script leaves the rows as they were" {
  grep -q 'prints nothing, is missing or fails' "$SKILL"
  grep -q 'exactly as it did before bars existed' "$SKILL"
}

@test "output_format.md shows a bar on an epic row and on a story row, and none on task rows" {
  grep -Fq '📦 E01 · <Epic Title>  [<Status>]  [━━━━━━━╌╌╌]⚑ 2/3' "$FMT"
  grep -Fq '📖 E01_S01 · <Story Title>  [<Status>]  [━━━━━╌╌╌╌╌]⚑ 1/2' "$FMT"
  run grep -E '(✅|🔄|⏳) E01_S01_T0.*[█░━╌⚑]' "$FMT"
  [ "$status" -eq 1 ]
}

@test "output_format.md keeps its eight banner rules and four banner titles unchanged" {
  [ "$(grep -cFx "$RULE" "$FMT")" -eq 8 ]
  grep -Fxq ' PROJECT STATUS' "$FMT"
  grep -Fxq ' OPEN RAPPORTS  (2)' "$FMT"
  grep -Fxq ' QUEUE  (1 pending trigger for scrum master)' "$FMT"
  grep -Fxq " ⚠️  TODO.MD FORMATTING  (2 lines won't be recognized as queued)" "$FMT"
}

@test "output_format.md keeps the Status Icons table byte-identical" {
  expected='## Status Icons

| Icon | Status |
|------|--------|
| ✅ | Passed / Passed with remarks |
| ❌ | Failed / Rejected |
| 🔄 | In Progress |
| ⏳ | Pending |
| 🚫 | Blocked |
| 📦 | Epic |
| 📖 | Story |
| 🔧 | Task |'
  actual="$(sed -n '/^## Status Icons$/,$p' "$FMT")"
  [ "$actual" = "$expected" ]
}

# ---- E92_S06_T26: the default path and the --legacy path ---------------------------------------------------------------

RESOLVER_CMD='bash "$([ -f skills/j-status/scripts/resolve-status-mode.sh ] && echo skills/j-status/scripts/resolve-status-mode.sh || echo node_modules/@jenga-ai/agent/skills/j-status/scripts/resolve-status-mode.sh)"'

@test "SKILL.md step 1.5 calls resolve-status-mode.sh with the dual-path idiom, once, and sits before step 2" {
  [ "$(grep -cF "$RESOLVER_CMD mode" "$SKILL")" -eq 1 ]
  run grep -n '^1\.5\. \|^2\. ' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed 's/^\([0-9]*\):\([0-9.]*\)\..*/\2/' | tr '\n' ' ')" = "1.5 2 " ]
}

@test "SKILL.md names the default path: render replaces mode, stdout is printed unchanged, overview and scope" {
  grep -q 'the \*\*default path\*\*' "$SKILL"
  grep -q 'command with `render` in place of `mode`' "$SKILL"
  grep -q 'stdout unchanged' "$SKILL"
  grep -q '`overview` (no argument) or `scope`' "$SKILL"
}

@test "SKILL.md names the legacy path: --legacy, --all and --legacy <id>, with steps 2-4, 6.9 and 6.10 kept as written" {
  grep -q 'the \*\*legacy path\*\*' "$SKILL"
  grep -q '`legacy` (`--legacy`, or `--all` with no id) or `legacy-scope` (`--legacy <id>`)' "$SKILL"
  grep -q '^6\.9\. \*\*Collect the progress bars\*\* (legacy path only)' "$SKILL"
  grep -q '^6\.10\. \*\*Collect the extended scope block (legacy path only' "$SKILL"
}

@test "SKILL.md parses no arguments itself: no case statement, no flag handling code, the script does it" {
  grep -q 'parsed by a script, never by this file' "$SKILL"
  run grep -Eq '\bcase\b|getopts|shift|\$\{1|\$@' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "the resolver sends the default to the overview renderer and --legacy to render-status-bars.sh, the one step 6.9 runs" {
  D="$REPO/skills/j-status/scripts"
  [ "$(bash "$D/resolve-status-mode.sh" plan)" = "render-status-overview.sh" ]
  [ "$(bash "$D/resolve-status-mode.sh" plan --legacy)" = "render-status-bars.sh" ]
  [ "$(bash "$D/resolve-status-mode.sh" plan --all)" = "render-status-bars.sh" ]
  grep -qF 'skills/j-status/scripts/render-status-bars.sh' "$SKILL"
  [ -f "$D/render-status-overview.sh" ]
  [ -f "$D/render-status-bars.sh" ]
}

@test "output_format.md has a Default views section for the new renderers and marks the legacy layout" {
  grep -Fxq '## Default views (`E92_S06_T26`)' "$FMT"
  grep -Fq 'render-status-overview.sh' "$FMT"
  grep -Fq 'render-status-scope-view.sh' "$FMT"
  grep -Fxq '## Output Format (legacy layout: `j.status --all`, `j.status --legacy`, and the fallback)' "$FMT"
  grep -Fq 'Needs attention' "$FMT"
}

## Default views (`E92_S06_T26`)

`j.status` with no argument prints the overview of `render-status-overview.sh`, and `j.status <epic|story id>` prints the
scope view of `render-status-scope-view.sh`. SKILL.md step 1.5 calls `resolve-status-mode.sh` to choose between them and
prints the renderer's stdout **unchanged**; nothing in this file's legacy layout below applies to that text. After the
overview the sections for open rapports, the queue, the `todo.md` formatting warning and the dependency audit follow, in
the banner style shown under "Output Format"; a scope view prints only the view. `j.status --all` (no id) and
`j.status --legacy [<id>]` use the legacy layout below. Real output of `bash skills/j-status/scripts/resolve-status-mode.sh
render --cols 80 --color never` (UTF-8 locale, abridged to a few rows per group; the script prints every row):

```
Board · 92 epics · 1438/1575 tasks · 91 %
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╌╌╌⚑
  ◉ 2 in progress  ✕ 6 red  ○ 129 pending  ⊘ 101 rejected (not counted)

Needs attention (4)
  E70 ━━━━━━━━━━━━━━ 16/17 94 %  ✕1  Retire Jenga's Own Use of docs/ (Site Sour…
  E87 ━━━━━━━━━━━━━╌ 14/18 78 %  ✕2  Epic wrap-up workflow, task closure and a …

In progress (1)
  E92 ━━━━━━━━━━━━━━ 58/59 98 %  ◉1  Progress Visualisation: see how far a run,…

Started (16)
  E22 ━━━━━━━━━━━━━╌ 30/31 97 %    /publish Skill — Deployment Pipeline Orchest…

★ Complete (59)  977 tasks · hidden
⊘ Only rejected or empty (9): E02, E04, E23, E48, E55, E81, E82, E84, E90

Details for one epic: j.status <id>  ·  all rows: j.status --all
```

Real output of `... render E92_S06 --cols 80 --color never` (abridged to four task rows):

```
E92_S06 · Epic progress on cards, dependency tree in overlay, and restyle…  96 %

◉ E92_S06  Epic progress on cards, dependency tree in overlay, a… ━━━━━━━━ 25/26
    ● T01 done        Add the --graph mode to scripts/board-progress.sh: per-ep…
    ● T02 done        Derive task states (ready, loc…  after T01 ✓
    ● T04 done        Add GET /v1/progress-cards to …  after T01 ✓, T03 ✓
    ◉ T26 in progress j.status --legacy switch, SKIL…  after T21 ✓, T23 ✓, T25 ✓

Ready to take (0)
  Nothing is ready to take right now
```

## Output Format (legacy layout: `j.status --all`, `j.status --legacy`, and the fallback)


```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 PROJECT STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 E01 · <Epic Title>  [<Status>]  [━━━━━━━╌╌╌]⚑ 2/3 · 1 in progress
   📖 E01_S01 · <Story Title>  [<Status>]  [━━━━━╌╌╌╌╌]⚑ 1/2 · 1 in progress
      ✅ E01_S01_T01 · <Task Title>  [Passed]
      🔄 E01_S01_T02 · <Task Title>  [In Progress]
      ⏳ E01_S01_T03 · <Task Title>  [Pending]
   📖 E01_S02 · <Story Title>  [<Status>]
      ...

📦 E02 · <Epic Title>  [<Status>]
   ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 OPEN RAPPORTS  (2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  problems/E01_S02-auth-conflict.md
📊  analysis/E01-performance-baseline.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 QUEUE  (1 pending trigger for scrum master)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ⚠️  TODO.MD FORMATTING  (2 lines won't be recognized as queued)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
line 4: E05_S01_T02 – Verify terraform plan parity for dev and prod post-refactor (infra)
line 19: E12_S03 - Some other backwards entry
```

The bar after an epic or story row is the line `render-status-bars.sh` returned for that id (SKILL.md step 6.9), appended unchanged to the epic or
story row; task rows carry no bar. When the script returned nothing, rows print without it, as they always did.

Omit the `TODO.MD FORMATTING` section entirely when step 6.7's check exits `0` (nothing found) —
this is the common case and should not appear as an empty section.

## Extended scope block

Legacy path only (`j.status --legacy <epic-or-story-id>`, SKILL.md step 6.10; the default `j.status <id>` prints the scope
view above instead): the output of `render-status-scope.sh <id>` is printed unchanged after the scoped
part of the overview. The plain overview never shows it. Real output of `render-status-scope.sh E92_S05` (UTF-8 locale, 80 columns, no colour):

```
Dependency tree (E92_S05)
★ Goal: E92_S05
  ● E92_S05 Bars and counts in j.status, and a --summary mode on the shared script (optional) ╌╌ E92_S01
      ● E92_S05_T01 Done · Add the --summary mode to scripts/board-progress.sh: a compact whole-board overview block ━━ E92_S01_T05, E92_S02_T01
      ● E92_S05_T02 Done · Add the --by-parent mode to scripts/board-progress.sh: counts per epic and per story in one pass, for j.status ━━ E92_S05_T01

Ready to take
  Nothing is ready to take right now

  E92_S05_T01 unlocked by E92_S01_T05
  E92_S05_T02 unlocked by E92_S05_T01
```

The example is abridged to two task rows; the script prints every task of the scope. When it printed nothing, the block is omitted.

## Status Icons

| Icon | Status |
|------|--------|
| ✅ | Passed / Passed with remarks |
| ❌ | Failed / Rejected |
| 🔄 | In Progress |
| ⏳ | Pending |
| 🚫 | Blocked |
| 📦 | Epic |
| 📖 | Story |
| 🔧 | Task |

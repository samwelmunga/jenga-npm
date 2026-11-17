## Default views (`E92_S06_T26`)

`j.status` with no argument prints the overview, and `j.status <epic|story id>` prints the scope view; since `E92_S08_T06`
both are drawn by the Node renderer (`node lib/progress/cli.js overview|scope <id>`). SKILL.md step 1.5 calls
`resolve-status-mode.sh render --charset utf8 --color never <args>` and **copies its stdout into the reply as a fenced code
block**, byte for byte (a tool call's output is folded away in the desktop app); nothing in this file's legacy layout below
applies to that text. `--color never` is used for the copy because ANSI colour cannot render in chat markdown; colour needs
`--color always` in a real terminal. After the overview the sections for open rapports, the queue, the `todo.md` formatting
warning and the dependency audit follow, in the banner style shown under "Output Format"; a scope view prints only the view.
`j.status --all` (no id) and `j.status --legacy [<id>]` use the legacy layout below, and so does `render` when `node` is not
on `PATH` (one warning on stderr). The E92_S06 bash views `render-status-overview.sh` and `render-status-scope-view.sh` stay
on disk but are no longer routed. Real output of `bash skills/j-status/scripts/resolve-status-mode.sh render --charset utf8
--color never --cols 80` (abridged to a few rows per group; the renderer prints every row):

```
Board · 92 epics · 1445/1575 tasks · 92 %
  ▰▰▰▰▰▰▰▰▰▰▰▱⚑ 1445/1575 · 1 in progress · 6 red · ⊘ 101 rejected (not counted)
  ○ 123 pending

Needs attention (4)
  E70 ▰▰▰▰▰▰▰▰▰▰▰▰▰▰ 16/17 94 %  ✕1  Retire Jenga's Own Use of docs/ (Site Sour…
  E87 ▰▰▰▰▰▰▰▰▰▰▰▰▰▱ 14/18 78 %  ✕2  Epic wrap-up workflow, task closure and a …

Started (16)
  E22 ▰▰▰▰▰▰▰▰▰▰▰▰▰▱ 30/31 97 %    /publish Skill — Deployment Pipeline Orchest…
  E92 ▰▰▰▰▰▰▰▰▰▰▰▰▰▱ 63/69 91 %    Progress Visualisation: see how far a run, a…

Not started (3)
  E52 ▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0/2 0 %    Agent Orchestration — Cross-Session Message Iso…

★ Complete (60)  1034 tasks · hidden
⊘ Only rejected or empty (9): E02, E04, E23, E48, E55, E81, E82, E84, E90

Details for one epic: j.status <id>  ·  all rows: j.status --all
```

Real output of `... render E92_S08 --charset utf8 --color never --cols 80` (abridged to four task rows):

```
E92_S08 · Node terminal progress renderers with the new design, explicit …  40 %
Ready to take: E92_S08_T02, E92_S08_T03 (+1)

E92_S08  ▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱⚑ 4/10

NODE TERMINAL PROGRESS RENDERERS WITH THE NEW DESIGN, EXPLICIT UTF-8 AND … 4/10
  ● Decision: narrow-terminal layout of the scope tree, what the milestone line…
    └─▸ ◉ Node render core: explicit charset and colour, width, label and data …
          └─▸ ◉ Wire j.status to the Node renderer, keep --legacy on the bash p…
            └─▸ ○ Wire run-progress.sh, j.do, j.dooo, j.jenga and j.break to th…

Ready to take: Extract the graph-struc… · Node render core: expli…
Wire run-progress.sh, j… unlocked by Wire j.status to the No…
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

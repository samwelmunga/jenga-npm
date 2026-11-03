---
name: j.checklist
description: Guided front end for the pre-flight checklist registry — print it (one situation or all, grouped), and add, edit, remove, copy or move a checklist item without hand-editing JSON; every input is validated as it is given, destructive actions confirm first, and a failed validation never leaves a changed file.
keywords:
  - preflight checklist
  - checklist item
  - add checklist item
  - edit checklist item
  - remove checklist item
  - move checklist item
  - copy checklist item
  - show checklist
  - checklist registry
examples:
  - "show me the pre-commit checklist"
  - "add a pre-flight check that blocks commits containing TODO markers"
  - "change the enforcement of dependency-audit-reviewed to confirm"
  - "remove a checklist item"
  - "copy an item from my project's checklist into the shipped default"
  - "j.checklist"
---

# Checklist — Guided Pre-Flight Registry Manager

## Purpose

The pre-flight checklist registry (epic `E67`, data contract in `project/documentation/preflight-checklists.md`)
holds the standing checks that gate real operations: each item names the lifecycle situations it belongs to, how it is
satisfied (`machine` runs a `verify` command, `judgment` asks an agent to confirm) and how binding it is
(`block`, `confirm` or `advisory`). This skill is the guided way to **look at** that registry and to **append, edit,
remove, copy and move** items, so that managing it does not mean hand-editing JSON and hoping the result still
validates. Hand-editing stays supported.

This skill manages item **definitions** only. Ticking an item stays `scripts/checklist.sh tick`, and the checker, the
tick store and the enforcing hook are not touched by anything here. It is a **user** interface: it does not give
agents a route around the review path for agent-suggested items (developer and tester never write the registry).

**All deterministic work lives in scripts** (per `CLAUDE.md`'s "Scripts Over Inline Logic" principle): rendering, every
schema rule, the splice-and-validate write, the cross-file `copy`/`move` with its rollback, and the instance checks all
live in the three scripts below. This skill only runs the conversation around them and interprets their results. It
never builds JSON, checks a rule, formats a line or resolves a path itself.

## Script contract (what this skill relies on)

`<S>` below is `skills/j-checklist/scripts` in this repository, or
`node_modules/@jenga-ai/agent/skills/j-checklist/scripts` in a project that installed the package. Each script's own
header (`--help`) is authoritative for usage and every exit code.

| Call | Result |
|---|---|
| `<S>/checklist-print.sh [--all]` | Every situation, grouped, each under its own heading; numbering restarts at 1 in each group |
| `<S>/checklist-print.sh <situation>` | That situation's items only, one numbered line each, in the form the render template defines; read-only |
| `<S>/checklist-instance.sh status` | `instance<TAB><path>`, or `default<TAB><instance path (not yet created)><TAB><shipped default path>` |
| `<S>/checklist-instance.sh target <path>` | `shipped-default`, `new` (a copy/move would seed it) or `exists` |
| `<S>/checklist-instance.sh scratch` / `discard <path>` | Make / remove a scratch copy of the shipped default (steps 1 and 5: reads and the first-instance route when the project has no registry) |
| `<S>/checklist-entry.sh [--registry P] path` | The registry path in force |
| `<S>/checklist-entry.sh [--registry P] situations` | The situations an item may name in that registry, one per line |
| `<S>/checklist-entry.sh [--registry P] show <id>` | One item as JSON; exit 9 if absent |
| `<S>/checklist-entry.sh [--registry P] check <field> "<value>"` | `{"valid": true}` or `{"valid": false, "reason": "..."}`; exit 0 only when valid. Fields: `id`, `text`, `situation`, `situations`, `kind`, `verify`, `enforcement`, `tick-scope`; and `check coupling <kind> [<verify>]` |
| `<S>/checklist-entry.sh [--registry P] add --id I --text T --situation S... --kind K [--verify V] --enforcement E --tick-scope C` | Append one item; one JSON line on success |
| `<S>/checklist-entry.sh [--registry P] edit <id> [field flags]` | Change the named fields of one item |
| `<S>/checklist-entry.sh [--registry P] remove <id>` | Delete one item |
| `<S>/checklist-entry.sh [--registry SRC] copy <id> --to <path>` / `move <id> --to <path>` | Write the item into another registry file (`move` then removes it from the source) |
| `scripts/validate-checklists.sh <path>` | Exit `0` only if the registry is valid |

Option values are separate arguments (`--text "..."`, never `--text=...`). On a failed write the script exits non-zero,
the registry (both registries, for `copy` and `move`) is exactly as it was, and the reason is on stderr.

## Instructions

1. **Start by showing the registry.** Run `<S>/checklist-instance.sh status`, then `<S>/checklist-print.sh` and present
   the grouped result readably. If a script exits non-zero, show its stderr verbatim and stop (exit `1` from the printer
   means the registry in force is invalid: tell the user it needs fixing by hand first, do not try to repair it).
   - `instance` — say which file is in force.
   - `default` — say plainly that **this project has no checklist registry of its own yet**, so what is shown is the
     shipped default, and that adding anything will create the project's first registry (step 5 explains what that means).
     The entry script refuses every read on a project with no registry (exit `4`), so run `<S>/checklist-instance.sh
     scratch` now and keep the path it prints as `<scratch>` for the whole session. In this state pass
     `--registry <scratch>` to every read-only `checklist-entry.sh` call (`situations`, `show`, `check`) and to the
     writes in step 5. `<scratch>` is only a copy of what is in force, so what those calls answer is what the project
     sees. Run `<S>/checklist-instance.sh discard <scratch>` when the session ends, is cancelled, or the first registry has
     been created.

2. **Choose the action.** Present:

   ```
   What would you like to do?
   1. Show one situation only
   2. Add a checklist item
   3. Edit an item
   4. Remove an item
   5. Copy an item to another registry file
   6. Move an item to another registry file
   7. Other (describe below)
   ```

   Option 1: ask which situation (offer `<S>/checklist-entry.sh situations` as a numbered list, free text last), run
   `<S>/checklist-print.sh <situation>`, show it, and offer the menu again. An unknown situation (exit `3`) is reported as
   such. Option 7: follow the user's free-text request using these same scripts; never write JSON yourself.

3. **Pick an item by its printed number.** For edit, remove, copy and move, the user selects an item by the number the
   printer shows. Because numbering restarts in every group, first ask which situation (numbered list of
   `<S>/checklist-entry.sh situations`, free text last), run `<S>/checklist-print.sh <situation>`, and let the user pick a
   number from that single list. The id is the word after the number. Then run `<S>/checklist-entry.sh show <id>` and show
   the exact item. A typed id is accepted too; exit `9` means it does not exist.

   **Edit and remove need a project registry.** When `status` said `default`, every item shown is a shipped one, and the
   scripts only edit or remove an item in a registry the project owns. Say so, and offer `1. Add an item first (this
   creates the project's registry holding every shipped item, step 5), then edit or remove`, `2. Cancel`,
   `3. Other (describe below)`. Do not point `edit` or `remove` at `<scratch>` or at the shipped default.

4. **Gather one field at a time, validating each as it is given.** (Add, and the changed fields of Edit.) Before accepting
   a typed value, run `<S>/checklist-entry.sh check <field> "<value>"`; on `valid: false` show the reason verbatim, do
   not store or "fix" it, and ask again. Never repair a value silently.
   1. **id** (`check id`) — a short identifier for the item. A collision is reported by the script: offer "edit it instead".
   2. **text** (`check text`) — what must be true for the item to be satisfied.
   3. **situations** — offer `<S>/checklist-entry.sh situations` as a numbered multi-pick, free text last. Declaring a new
      situation is a by-hand edit of the file's top-level `situations`; say so rather than trying to do it.
   4. **kind** — `1. machine (a command verifies it)`, `2. judgment (an agent confirms it)`, `3. Other (describe below)`
      (`check kind`). For `machine`, ask for the **verify** command and run `check verify` and `check coupling machine
      "<verify>"`; for `judgment`, run `check coupling judgment` and ask for no command.
   5. **enforcement** — `1. advisory (reported, never stops anything)`, `2. confirm (an agent must tick or ask)`,
      `3. block (refuses the gated operation until satisfied)`, `4. Other (describe below)` (`check enforcement`). If the
      user picks `block`, give the disclosure in step 6 before going on.
   6. **tick scope** — `1. run (satisfied once per run)`, `2. persistent (stays ticked)`, `3. Other (describe below)`
      (`check tick-scope`).

   For Edit, show the item, ask which fields to change, and gather only those. The script's reply says what a change to
   `situations` or `kind` did to the rest of the item; relay it.

5. **Add.** After step 4, show the finished item, and **before the write** apply the two disclosures below if they
   apply, then confirm (`1. Write it`, `2. Change something`, `3. Cancel`). Nothing is written before this call, so
   cancelling at any point leaves no trace.
   - **The project already has a registry** (`status` said `instance`): run
     `<S>/checklist-entry.sh add --id ... ` with the gathered flags.
   - **The project has no registry yet** (`status` said `default`) — **creating the first instance switches the whole
     project to a new file.** Say this before writing: a project's own `checklists.json` *replaces* the shipped default
     whole and never merges with it, so from now on this project reads only the new file; it will be created holding
     **every item of the shipped default plus the new one** (so nothing is silently dropped), and later changes to the
     shipped default in newer package versions no longer reach this project on their own. Confirm with that stated. The
     script never creates a registry by `add`, so the route uses the `<scratch>` registry from step 1 (a copy of the
     shipped default, which the step 4 checks already ran against): `<S>/checklist-entry.sh --registry <scratch> add ...`,
     `<S>/checklist-entry.sh --registry <scratch> copy <id> --to <instance path from status>`, then
     `<S>/checklist-instance.sh discard <scratch>` (also when any step fails). Report the `SEEDED:` line the copy prints.

6. **Disclosure: `block` has real teeth.** Whenever the item as it will be written carries `enforcement: block` (set
   by Add, or by Edit), say plainly, before the write: the enforcing hook `hooks/on_preflight_check.sh` will **refuse the
   irreversible operation of that situation** (for example `git commit` for `pre-commit`) while the item is unsatisfied,
   **at every permission level including 5 (Unrestricted), with no environment variable that turns it off**; and a
   `machine` item with a wrong `verify` therefore blocks work until the registry is fixed by hand. Suggest the safer path:
   write it as `confirm` first, let it run once or twice to prove the `verify` does what is meant, then edit it to
   `block`. Offer `1. Use confirm first (recommended)`, `2. Keep block`, `3. Other (describe below)`, and honour the
   choice. If the item is a `machine` item, remind the user the `verify` command runs for real on every gated operation.

7. **Edit.** After step 4, apply step 6 if the result is `block`, confirm (`1. Write it`, `2. Change something`,
   `3. Cancel`), then run `<S>/checklist-entry.sh edit <id>` passing only the changed flags. If the script reports
   `"changed": false`, say nothing was changed.

8. **Remove — confirm first, showing the exact item.** Show `show <id>` output, say that removal is permanent and that
   the item's ticks are left behind (harmless: a tick is only honoured while it matches the item's definition), then
   `1. Remove it`, `2. Cancel`, `3. Other (describe below)`. Only then run `<S>/checklist-entry.sh remove <id>`.

9. **Copy and move — confirm first, showing the exact item.** Both write the item into another registry file named by
   path; there is no default target. Ask for the target path (offer `1. This project's own registry`, `2. The shipped
   default, templates/checklists.json`, `3. Another registry file (type its path)`, `4. Other (describe below)`; the
   project's own path is `status`' instance path). Then run `<S>/checklist-instance.sh target <path>` and show the exact
   item, the source, the target and, for `move`, that it is **removed from the source** once the target has it.
   - `shipped-default` — **any write to `templates/checklists.json` needs its own explicit confirmation** and this
     warning first: that file ships downstream to every project that installs the package, so it must stay free of
     project-specific policy; it is only ever an explicit target and never a `move` source. Do not offer it as a default.
   - `new` — the target will be **created by seeding**: it is written as the registry currently in force for a project
     with no instance (the shipped default) **plus the incoming item**, and a project whose own registry that path is
     switches to it whole (same disclosure as step 5). Say so before confirming.
   - `exists` — the item is appended after its last item.
   Confirm (`1. Do it`, `2. Cancel`, `3. Other (describe below)`), then run `copy` or `move`. If the item names a situation
   the target does not declare, the script refuses (exit `12`); say that declaring it in the target is a by-hand edit, and
   offer to retry afterwards. Never offer `move` out of the shipped default (the script refuses it too).

10. **Report the write result.** Branch on the script's exit status:
    - **`0`** — continue to step 11.
    - **non-zero** — show the stderr text verbatim (it names the failing rule) and **do not** report success. State what
      it means from the contract: `7` an input broke a schema rule, `8` that id already exists in the target (never
      overwritten, never renamed), `9` unknown id, `10` the item is managed by `j.conventions` (a generated `conv-` item:
      change it with `j.conventions`, and a hand edit would be overwritten on its next run), `11` the candidate failed
      validation so **nothing was changed**, `12` situation not declared by the target, `13` source and target are the
      same file or `move` out of the shipped default, `14` the target's directory is missing (create it first) or the
      target is not a regular file, `6` another process holds the lock (offer a retry shortly). The registry is exactly as
      it was; say so, and offer to retry the step that failed.

11. **Self-validate before declaring success — never skip this step.** Run `scripts/validate-checklists.sh <path>` on each
    registry that was written (the `registry` field of the result JSON; for `copy`/`move`, the `target`, and for `move`
    also the `source`).
    - **Exit `0`** — report success: which item changed, which file, and what happened (for a seed, the `SEEDED:` line
      verbatim). Offer `<S>/checklist-print.sh <situation>` to show the result.
    - **Any other exit** — report the validator's messages verbatim and state plainly that the file is not valid. Never
      claim success.

    Under no circumstances report success without having seen exit `0` from this exact call.

## Known limits (state them when they matter, never paper over them)

These are properties of the scripts underneath, documented in `project/documentation/preflight-checklists.md`:

- **Locks key on the path as given.** Two spellings of one file (a relative and an absolute path, or one through a
  symlink) do not exclude each other. When two sessions might edit the same registry, spell the path identically.
- **A hard kill during a `move` can leave a `.rollback` file.** A SIGKILL between the two replaces cannot be undone; the
  target's backup `<target>.rollback.<pid>` is left next to it. If such a file exists, tell the user and do not delete it
  for them: it is the target as it was before the move.
- **A SIGTERM sent only to the top-level script does not stop its lock child.** The `with-lock.sh` child finishes the
  `move` anyway. After an interrupted session, print the registry rather than assuming nothing happened.
- **A project's first registry is a snapshot of the shipped default** at the moment it is seeded.
- **Managed `conv-` items cannot be edited, removed, copied or moved here.** They belong to `j.conventions`.

## Edge Cases

- **The user cancels mid-flow.** Nothing is written: only the final `add`, `edit`, `remove`, `copy` or `move` call (and
  the seed `copy` in step 5) touches a registry. Discard `<scratch>` on cancel too.
- **The registry in force is hand-edited and invalid.** The scripts refuse and show the validator's messages; tell the user
  it needs fixing by hand first.
- **The user wants to change the shipped default's policy.** It is only reachable as an explicit `--to` target for `copy`
  or `move`, with the warning in step 9; there is no edit-in-place for it here.
- **Declaring a new situation, or changing `checklist_version`.** By hand only.
- **Ticking items or running checks.** `scripts/checklist.sh tick` and `scripts/checklist.sh check <situation>`; this skill
  does neither.

---
name: j.tools
description: Guided wizard to create, edit, remove and suppress entries in the preferred-tools registry — pick the user or project layer, validate every input as it is given, and self-validate the written file before reporting success.
keywords:
  - preferred tools
  - tools registry
  - add tool
  - edit tool
  - suppress tool
  - required tool
  - recommended tool
examples:
  - "add a preferred tool to my registry"
  - "make shellcheck a required tool for this project"
  - "suppress the shipped doctl entry in this project"
  - "show me the effective preferred tools"
  - "j.tools"
---

# Tools — Guided Preferred-Tools Registry Wizard

## Purpose

The preferred-tools registry (epic `E66`, contract in `project/documentation/preferred-tools-registry.md`)
declares which software and tools Jenga agents should reach for, how binding each choice is
(`required` or `recommended`), and why. It has three layers: a curated **shipped** list, a **user**
layer and a **project** layer, with precedence project over user over shipped. This skill is the
guided way to author the two writable layers (the shipped list is read-only): it adds, edits and
removes entries, suppresses a shipped entry from a layer, and shows the effective merged list.
Hand-editing the files stays fully supported, and the wizard preserves every entry it did not touch.

**All deterministic work lives in scripts** (per `CLAUDE.md`'s "Scripts Over Inline Logic"
principle): per-input validation, descriptor lookup, reading, and the atomic write with its built-in
validation all live in `skills/j-tools/scripts/tools-entry.sh`; listing the effective registry is
`scripts/resolve-tools.sh`; the final self-check is `scripts/validate-tools-registry.sh`. This skill
only runs the conversation around those scripts and interprets their results. It never builds JSON,
checks a rule, or resolves a path itself.

## Script contract (what this skill relies on)

| Call | Result |
|---|---|
| `skills/j-tools/scripts/tools-entry.sh path --layer user\|project` | Prints the layer file's path |
| `skills/j-tools/scripts/tools-entry.sh show --layer shipped\|user\|project [--name N]` | Prints the layer file (or one entry) as JSON; exit 1 if the named entry is absent. `shipped` is read only |
| `skills/j-tools/scripts/tools-entry.sh descriptors` | One real `j-connect` descriptor id per line |
| `skills/j-tools/scripts/tools-entry.sh check <category\|enforcement\|version\|descriptor\|name> "<value>" --layer L` | One JSON object `{"valid": true}` or `{"valid": false, "reason": "..."}` (exit 0 for both) |
| `skills/j-tools/scripts/tools-entry.sh add\|edit\|remove\|suppress\|unsuppress --layer L --name N [field flags]` | Validates the result, replaces the file atomically, prints one JSON object on success; on failure exit non-zero, the file is untouched and the reason is on stderr |
| `scripts/resolve-tools.sh --format text [--category C]` | The effective merged list, one line per entry |
| `scripts/validate-tools-registry.sh <path>` | Exit `0` only if the file is valid |

Field flags for `add` and `edit`: `--category`, `--enforcement`, `--rationale`, `--version`,
`--alternative "<name>::<why_not>"` (repeatable), `--descriptor`, `--install-text`, and `--add-category`
(declare a new category in that layer). `edit` also takes `--clear-alternatives`, `--clear-descriptor`
and `--clear-install-text`; run the script with `--help` for the full usage.

## Instructions

1. **Choose the action.** Present:

   ```
   What would you like to do?
   1. Add a tool
   2. Edit a tool
   3. Remove a tool
   4. Suppress a shipped tool (hide it from this layer and below)
   5. Show the effective tools list
   6. Other (describe below)
   ```

   For option 5 run `scripts/resolve-tools.sh --format text` (offer a category filter, and offer to
   pass `--category` if the user names one), present the result readably (grouped by category, showing
   enforcement and the layer each entry came from), and stop. A non-zero exit means a layer is invalid:
   show the stderr text verbatim. For option 6 follow the user's free-text request using the same
   scripts; never write JSON yourself.

2. **Choose the layer** (skip for option 5). Present:

   ```
   Which layer should this change go to?
   1. Project (shared with everyone on this project)
   2. User (applies to you across projects)
   3. Other (describe below)
   ```

   Run `skills/j-tools/scripts/tools-entry.sh path --layer <layer>` and tell the user which file will
   be changed. If that call fails (for example the project root cannot be resolved), show its stderr
   verbatim and stop; do not guess a path.

3. **Add.** Gather one field at a time, in this order, and validate each as it is given:

   1. **Name** — the tool's identity (for example `shellcheck`). Run `tools-entry.sh check name "<v>" --layer <layer>`;
      a result with `valid: false` (empty, or already present in this layer) is shown verbatim and the
      name is asked again. If the name already exists in this layer, offer "edit it instead" as option 1.
   2. **Category** — run `tools-entry.sh check category "<v>" --layer <layer>`. If invalid because the
      category is unknown, show the reason (it lists the allowed values) and offer: 1. Pick one of the
      allowed categories, 2. Declare it as a new category in this layer (the script's result says
      whether the name is acceptable as an extension; if so remember to pass `--add-category` on the
      write), 3. Other (describe below).
   3. **Enforcement** — present `1. required (binding: an agent needing a different tool stops and asks)`,
      `2. recommended (advisory: an agent may deviate and notes why)`, `3. Other (describe below)`.
      Validate the choice with `tools-entry.sh check enforcement "<v>"`.
   4. **Rationale** — why this tool is preferred; one or two sentences. Re-ask if empty.
   5. **Alternatives considered** — zero or more `<name> / why not` pairs, one at a time. The user may
      say none.
   6. **Version constraint** — for example `>=1.5`, `^20`, `>=18 <22`, or `*` for any. Validate with
      `tools-entry.sh check version "<v>"`; show the reason verbatim on failure and ask again. Never
      repair a malformed constraint silently.
   7. **Install hint** — first run `tools-entry.sh descriptors` and offer the real ids as numbered
      options (with "none of these, give a free-text hint only" and "Other (describe below)" last).
      A chosen id is validated with `tools-entry.sh check descriptor "<id>"`; a free-text hint
      (a command or URL) is optional when a descriptor is linked and required when none is.

   Summarise the entry and layer, ask for confirmation (`1. Write it`, `2. Change something`,
   `3. Cancel`), then run `tools-entry.sh add --layer <layer> --name ... ` with the gathered flags.
   Nothing is written before this call, so cancelling at any point leaves no trace.

4. **Edit.** Run `tools-entry.sh show --layer <layer>` and offer the entries of that layer by number
   (free text last). If the tool the user wants lives only in another layer or in the shipped list,
   explain that an entry is replaced whole by a higher layer (there is no field merge) and offer to
   create a replacement entry in the chosen layer via the Add flow, prefilled from
   `tools-entry.sh show --layer <source layer> --name <name>` (use `shipped` for a shipped entry). Otherwise show the
   current fields, ask which to change, gather and validate only those fields exactly as in step 3,
   confirm, and run `tools-entry.sh edit --layer <layer> --name <name>` passing only the changed flags.

5. **Remove.** Offer the layer's entries by number, confirm, then run
   `tools-entry.sh remove --layer <layer> --name <name>`. Note that a lower layer's entry of the same
   name becomes effective again.

6. **Suppress.** Run `scripts/resolve-tools.sh --format text` to show the entries that are currently
   effective from lower layers, let the user pick one (or type a name), explain that suppression only
   hides lower-layer entries and a same-layer entry of that name still wins, confirm, then run
   `tools-entry.sh suppress --layer <layer> --name <name>`. To undo, use
   `tools-entry.sh unsuppress --layer <layer> --name <name>`.

7. **Report the write result.** Branch on the script's exit status:
   - **`0`** — continue to step 8.
   - **non-zero** — show the stderr text verbatim (it names the failing rule) and **do not** report
     success. The script leaves the file exactly as it was, so say so, and offer to retry the step
     that failed.

8. **Self-validate before declaring success — never skip this step.** Run
   `scripts/validate-tools-registry.sh <path>` on the written layer file (the path from step 2).
   - **Exit `0`** — report success: which entry changed, in which layer file, and (for add, edit, remove
     and suppress) offer to show the effective list via `scripts/resolve-tools.sh --format text`.
   - **Any other exit** — report the validator's messages verbatim and state plainly that the file
     is not valid. Never claim success.

   Under no circumstances report success without having seen exit `0` from this exact call.

## Edge Cases

- **A hand-edited layer file exists and is currently invalid.** The write script refuses to change it
  and shows the validator's messages. Tell the user the file needs fixing by hand first; do not try
  to repair it.
- **The layer file does not exist yet.** The write script creates a minimal valid file. This is
  normal for both layers on first use.
- **Entries this wizard did not create** (hand-written, or extra keys) are preserved untouched by
  every write; mention this if the user worries about it.
- **The user wants to change the shipped list.** The shipped list is read-only. Offer to override an
  entry in the user or project layer (Add flow) or suppress it (Suppress flow).
- **Installing or authenticating a tool** is out of scope (that is `j.connect`'s job); the install
  hint only records the choice and links to a descriptor.
- **The user cancels mid-wizard** — nothing has been written; only the final script call in step 3,
  4, 5 or 6 touches disk.

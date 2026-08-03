# Plan: E01_S01_T01 — Scaffold /train skill structure

## Goal
Ensure `skills/train/SKILL.md` is complete, follows the pattern of other skills, documents
both subcommands, and explicitly states how unrecognised subcommands are handled.

## Files to touch
- `skills/train/SKILL.md` — update to meet all acceptance criteria

## Design
The SKILL.md already exists with substantive content. Updates needed:
1. Verify front-matter block matches other skills (`name`, `description`)
2. Document `new <type> <job-name>` and `run <job-dir>` subcommands clearly
3. Add an explicit **Usage / Help** section noting that argparse emits a usage message
   for unrecognised subcommands (this happens automatically via `required=True`)
4. Ensure types list is present: `classifiers`, `transformers`, `nlp`

## Verification
- File exists at `skills/train/SKILL.md`
- Front-matter present with name and description
- Both subcommands documented
- Unrecognised-subcommand behaviour documented

# Summary: E01_S01_T01 — Scaffold /train skill structure

## What was done
Updated `skills/train/SKILL.md` to explicitly document:
- Front-matter block (`name`, `description`)
- Usage block with subcommand list and unrecognised-subcommand behaviour note
- `new <type> <job-name>` full step-by-step including new CLI flags
- All supported types: `classifiers`, `transformers`, `nlp`
- `run <job-dir>` two-phase pipeline

## Acceptance criteria
- [x] `skills/train/SKILL.md` exists and follows the same structure as existing skills
- [x] Argument signature `new <type> <job-name>` is parsed correctly
- [x] `run <job-dir>` subcommand is documented
- [x] Unrecognised subcommands print a usage/help message (documented; argparse handles via `required=True`)

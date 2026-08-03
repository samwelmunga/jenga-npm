# Summary: E01_S02_T02 — Document workflow flags in each template README

## What was implemented
Added `## Workflow Configuration` section to all three template READMEs:
- `.training/template/classifiers/README.md`
- `.training/template/transformers/README.md`
- `.training/template/nlp/README.md`

## Section added
Each README now contains a table documenting all five `workflow:` flags:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `auto_run` | bool | `false` | Starts training immediately on invocation |
| `generate_start_sh` | bool | `true` | Emits a start.sh for manual execution |
| `confirm_before_run` | bool | `true` | Prompts before executing training |
| `auto_summarize` | bool | `true` | Surfaces results summary post-training |
| `auto_iterate` | bool | `false` | Reserved — re-run with adjusted config |

## Acceptance criteria
- [x] All three READMEs have a `## Workflow Configuration` section
- [x] Table covers all five flags with name, type, default, and description
- [x] Descriptions accurately reflect how the `/train` skill and `training_runner` MCP use each flag

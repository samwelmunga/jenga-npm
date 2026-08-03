# E01_S08 — Interactive Train Wizard: Execution Plan

## What Will Be Implemented

An interactive wizard mode for `train new`, triggered by `--interactive` (with optional `--full` to expand prompts to all fields), that guides the user through critical configuration decisions without needing to manually edit `config.yaml` after scaffolding.

## Key Design Decisions

1. **Positional args become optional** — `type` and `job_name` are changed from required positionals to `nargs='?'` so they can be omitted when `--interactive` is used. Non-interactive invocations still validate that both are present.

2. **Scaffold-then-configure flow** — The wizard scaffolds the job directory first (so the SIGINT handler has a directory to offer to delete), then prompts for config values, then patches the scaffolded `config.yaml`.

3. **SIGINT via try/except KeyboardInterrupt** — Python's `KeyboardInterrupt` is caught at the wizard boundary. If a scaffold dir exists at that point, the user is asked "Keep or delete?" before exiting.

4. **Explicit prompt schemas** — Field prompts are defined declaratively (key, prompt label, hint, default) for each job type, split into `critical` and `full` lists. This gives full control over UX copy and defaults.

5. **YAML patching via PyYAML** — Config is loaded with `yaml.safe_load`, values updated using dot-notation key traversal, then written back with `yaml.dump`. Comments are not preserved (acceptable for scaffolded files).

6. **Type coercion** — Integer/float fields detected by default value type are coerced before writing.

## Files to Create or Modify

| File | Action |
|------|--------|
| `skills/train/train_cli.py` | **Modify** — add `--interactive`/`--full` flags, `run_wizard()`, SIGINT handling |
| `skills/train/SKILL.md` | **Modify** — document new flags and wizard behaviour |
| `project/documentation/summaries/E01_S08-summary.md` | **Create** — execution summary |
| `project/board/stories/E01_S08_interactive-train-wizard.md` | **Modify** — set status to Passed |

## Wizard Field Schemas

### classifiers — critical
- `data.train_file` — Training CSV file path
- `data.target_column` — Column name containing labels
- `model.type` — Classifier algorithm
- `model.params.n_estimators` — Number of trees/estimators
- `data.test_size` — Test split ratio

### classifiers — full (adds)
- `data.test_file`, `model.params.max_depth`, `model.params.random_state`
- `training.cross_validation`, `training.cv_folds`

### transformers — critical
- `data.train_file`, `model.name`, `model.task`
- `training.num_train_epochs`, `training.learning_rate`

### transformers — full (adds)
- `data.eval_file`, `data.text_column`, `data.label_column`, `data.max_length`
- `training.per_device_train_batch_size`, `training.warmup_steps`, `training.weight_decay`

### nlp — critical
- `data.train_file`, `model.name`, `model.task`
- `training.n_iter`, `training.learning_rate`

### nlp — full (adds)
- `data.eval_file`, `training.batch_size`, `training.dropout`

## Verification Plan

1. Run `python train_cli.py new --interactive` and confirm wizard prompts appear
2. Run `python train_cli.py new --interactive --full` and confirm extended prompts
3. Verify `config.yaml` in scaffolded job reflects entered values
4. Run `python train_cli.py new classifiers my-job` and confirm no regression
5. Run `python train_cli.py new` (missing args, no --interactive) and confirm error
6. Simulate Ctrl+C mid-wizard and confirm keep/delete prompt appears

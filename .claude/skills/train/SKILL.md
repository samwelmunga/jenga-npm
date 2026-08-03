---
name: train
description: Scaffold and run ML training jobs. Use `new <type> <job-name>` to scaffold a job from a template, or `run <job-dir>` to execute the two-phase validate → train pipeline on an existing job.
keywords:
  - train
  - ml training
  - model training
  - machine learning
  - fine-tune
examples:
  - "scaffold a new training job"
  - "train a classifier model"
---

# Train — ML Training Job Orchestrator

## Usage

```
python skills/train/train_cli.py <subcommand> [args]

Subcommands:
  new <type> <job-name>   Scaffold a new training job from a template
  run <job-dir>           Execute validate → train pipeline on an existing job

Types: classifiers, transformers, nlp
```

If an unrecognised subcommand is given, argparse prints the usage message above and
exits with a non-zero code.

## Subcommands

### `/train new <type> <job-name>`
Scaffold a new training job from the appropriate template (positional / scriptable mode).

**Supported types:** `classifiers`, `transformers`, `nlp`

**Optional flags:**
- `--model <value>` — Override the model name/type in `config.yaml`
- `--epochs <n>` — Override the number of training epochs/iterations
- `--batch-size <n>` — Override the batch size

**Steps:**
1. Validate `<type>` is one of: `classifiers`, `transformers`, `nlp`
2. Copy the template directory from `.training/template/<type>/` to `jobs/<job-name>/`
   - If `jobs/<job-name>/` already exists, auto-suffix: `jobs/<job-name>-1/`, `jobs/<job-name>-2/`, etc.
3. Apply any CLI flag overrides to the scaffolded `config.yaml`
4. Generate `start.sh` in the job directory (executable)
5. Read the `workflow:` block from `config.yaml` and print next-step instructions
6. Print: `✅ Scaffolded job '<job-name>' from template '<type>' at jobs/<job-name>/`

### `/train new --interactive [--full]`
Launch a guided wizard that scaffolds the job **and** configures `config.yaml` interactively.

**Flags:**
- `--interactive` / `-i` — Enable the wizard. Job name and type are collected via prompts.
- `--full` — Expand the wizard to prompt for **every** configurable field (not just the critical ones).

**Wizard flow:**
1. Prompt for job name (freeform, used as directory name under `jobs/`)
2. Prompt for job type (`classifiers`, `transformers`, or `nlp`)
3. Scaffold the job directory from the template
4. Prompt for critical config fields (2–3 key model params + data path per type):
   - **classifiers**: train file, target column, model algorithm, n_estimators, test split
   - **transformers**: model name, task, train file, epochs, learning rate
   - **nlp**: model name, task, train file, iterations, learning rate
5. With `--full`: additionally prompt for every remaining field in `config.yaml`
6. Write user responses back into the scaffolded `config.yaml`

Each prompt shows the field name, its current default, and an inline description hint.

**Ctrl+C handling:**
Pressing `Ctrl+C` at any point during the wizard interrupts cleanly. If a scaffold directory has already been created, the user is asked:
```
Delete scaffolded directory '<path>'? [y/N]
```
Answering `y` removes the directory; `N` (or Enter) keeps it.

### `/train run <job-dir>`
Execute the two-phase pre-flight → smoke test pipeline on an existing job directory.

**Steps:**

#### Phase A — Pre-flight validation
1. Print: `[pre-flight] Running validate.py in <job-dir>...`
2. Run `validate.py` as a subprocess inside `<job-dir>`:
   ```bash
   cd <job-dir> && python validate.py
   ```
3. Stream all stdout/stderr output to the terminal in real time.
4. If `validate.py` exits non-zero:
   - Print: `❌ [pre-flight] FAILED — halting before smoke test.`
   - Surface the full error output.
   - **Stop here. Do not proceed to Phase B.**
5. If `validate.py` exits zero:
   - Print: `✅ [pre-flight] Passed.`

#### Phase B — Smoke test
1. Print: `[smoke test] Running train.py --smoke in <job-dir>...`
2. Run `train.py --smoke` as a subprocess inside `<job-dir>`:
   ```bash
   cd <job-dir> && python train.py --smoke
   ```
3. Stream all stdout/stderr output to the terminal in real time.
4. If `train.py` exits non-zero:
   - Print: `❌ [smoke test] FAILED.`
   - Surface the full error output.
5. If `train.py` exits zero:
   - Print: `✅ [smoke test] Passed. Job '<job-dir>' completed successfully.`

## Notes
- `train.py` and `validate.py` must have no awareness of each other — the `/train` skill owns the gate.
- Both subprocess calls must stream output (not buffer) so the user sees progress in real time.
- Phase B is **never** invoked if Phase A fails.
- The `--interactive` wizard requires `pyyaml` (`pip install pyyaml`) to patch `config.yaml`.

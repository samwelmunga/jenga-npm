# Transformer Fine-Tuning Template

Copy this directory when starting a new transformer fine-tuning job.

## Structure

```
transformers/
├── input/
│   ├── data/               # Place datasets here (.jsonl format)
│   └── config.yaml         # Model name, hyperparameters, paths
├── training/
│   └── main.py             # Fine-tuning script (HuggingFace Trainer)
├── checkpoints/            # Mid-training model snapshots (auto-generated)
├── training-results/       # Logs and eval metrics (auto-generated)
└── fine-tuned-models/      # Final model + tokenizer (auto-generated)
```

## Supported Tasks

Set `model.task` in `config.yaml`:

- `text-classification`
- `token-classification`
- `question-answering`
- `seq2seq`

## Input Format

Place `.jsonl` files in `input/data/`. Each line must be a JSON object with at minimum a text field and a label field (configurable in `config.yaml`).

```jsonl
{"text": "This is great!", "label": "positive"}
{"text": "Terrible experience.", "label": "negative"}
```

## How to Run

1. Copy this directory to your working location
2. Add datasets to `input/data/`
3. Edit `input/config.yaml` (model name, task, column names, hyperparams)
4. Install dependencies:

```bash
pip install transformers datasets evaluate
```

5. Run:

```bash
python training/main.py
```

## Output

| Path | Contents |
|---|---|
| `checkpoints/` | Intermediate model snapshots per epoch |
| `training-results/logs/eval_results.json` | Evaluation metrics |
| `fine-tuned-models/` | Final model weights, config, and tokenizer |

## Workflow Configuration

The `workflow:` block in `input/config.yaml` controls how the `/train` skill and `training_runner` MCP execute this job.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `auto_run` | bool | `false` | When `true`, training starts immediately when `/train` is invoked — no confirmation step. Keep `false` for safety. |
| `generate_start_sh` | bool | `true` | When `true`, a `start.sh` script is emitted alongside the job so you can run training manually outside the agent. |
| `confirm_before_run` | bool | `true` | When `true`, the `/train` skill prompts for confirmation before executing training. Ignored when `auto_run: true`. |
| `auto_summarize` | bool | `true` | When `true`, the skill parses evaluation metrics and surfaces a human-readable summary after training completes. |
| `auto_iterate` | bool | `false` | Reserved for future use. When `true`, the skill will re-run training with adjusted config based on result analysis. |


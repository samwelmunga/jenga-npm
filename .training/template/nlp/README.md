# NLP Pipeline Training Template

Copy this directory when starting a new NLP pipeline training job.

## Structure

```
nlp/
├── input/
│   ├── data/               # Place annotated data here (.spacy format)
│   └── config.yaml         # Model, task, hyperparameters, paths
├── training/
│   └── main.py             # NLP training script (spaCy-based)
├── checkpoints/            # Mid-training model snapshots (auto-generated)
├── training-results/       # Metrics and scores (auto-generated)
└── fine-tuned-models/      # Final trained pipeline (auto-generated)
```

## Supported Tasks

Set `model.task` in `config.yaml`:

- `ner` — Named Entity Recognition
- `text-classification` — Text categorisation
- `pos-tagging` — Part-of-speech tagging
- `dependency-parsing` — Dependency parsing

## Input Format

Data must be in spaCy's binary `.spacy` format (use `DocBin`). Place files in `input/data/`:

```
input/data/train.spacy
input/data/eval.spacy
```

To convert from other formats, use [spaCy's data conversion tools](https://spacy.io/api/cli#convert).

## How to Run

1. Copy this directory to your working location
2. Add annotated data to `input/data/`
3. Edit `input/config.yaml`
4. Install dependencies and base model:

```bash
pip install spacy
python -m spacy download en_core_web_sm
```

5. Run:

```bash
python training/main.py
```

## Output

| Path | Contents |
|---|---|
| `checkpoints/checkpoint_iter_N/` | Periodic model snapshots |
| `training-results/results.json` | Per-iteration losses and scores |
| `fine-tuned-models/` | Final trained spaCy pipeline |

## Workflow Configuration

The `workflow:` block in `input/config.yaml` controls how the `/train` skill and `training_runner` MCP execute this job.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `auto_run` | bool | `false` | When `true`, training starts immediately when `/train` is invoked — no confirmation step. Keep `false` for safety. |
| `generate_start_sh` | bool | `true` | When `true`, a `start.sh` script is emitted alongside the job so you can run training manually outside the agent. |
| `confirm_before_run` | bool | `true` | When `true`, the `/train` skill prompts for confirmation before executing training. Ignored when `auto_run: true`. |
| `auto_summarize` | bool | `true` | When `true`, the skill parses `training-results/results.json` and surfaces a human-readable summary after training completes. |
| `auto_iterate` | bool | `false` | Reserved for future use. When `true`, the skill will re-run training with adjusted config based on result analysis. |


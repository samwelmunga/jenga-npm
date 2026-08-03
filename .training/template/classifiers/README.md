# Classifier Training Template

Copy this directory when starting a new classifier training job.

## Structure

```
classifiers/
├── input/
│   ├── data/           # Place training data here (CSV format)
│   └── config.yaml     # Configure model type, hyperparameters, paths
├── training/
│   └── main.py         # Training script
├── training-results/   # Metrics and evaluation reports (auto-generated)
└── fine-tuned-models/  # Saved model files (auto-generated)
```

## Supported Models

- `random_forest` — sklearn RandomForestClassifier
- `gradient_boosting` — sklearn GradientBoostingClassifier
- `svm` — sklearn SVC
- `logistic_regression` — sklearn LogisticRegression
- `xgboost` — XGBoost (requires `pip install xgboost`)

## Input Format

Place CSV files in `input/data/`. The target column name must match `data.target_column` in `config.yaml`.

```
input/data/train.csv
input/data/test.csv   # optional
```

## How to Run

1. Copy this directory to your working location
2. Add training data to `input/data/`
3. Edit `input/config.yaml` to match your setup
4. Run:

```bash
python training/main.py
```

## Output

| Path | Contents |
|---|---|
| `training-results/results.json` | Accuracy + classification report |
| `fine-tuned-models/model.pkl` | Serialized model (joblib) |

## Workflow Configuration

The `workflow:` block in `input/config.yaml` controls how the `/train` skill and `training_runner` MCP execute this job.

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `auto_run` | bool | `false` | When `true`, training starts immediately when `/train` is invoked — no confirmation step. Keep `false` for safety. |
| `generate_start_sh` | bool | `true` | When `true`, a `start.sh` script is emitted alongside the job so you can run training manually outside the agent. |
| `confirm_before_run` | bool | `true` | When `true`, the `/train` skill prompts for confirmation before executing training. Ignored when `auto_run: true`. |
| `auto_summarize` | bool | `true` | When `true`, the skill parses `training-results/results.json` and surfaces a human-readable summary after training completes. |
| `auto_iterate` | bool | `false` | Reserved for future use. When `true`, the skill will re-run training with adjusted config based on result analysis. |


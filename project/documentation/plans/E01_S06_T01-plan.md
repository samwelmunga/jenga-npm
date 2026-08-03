# Plan: E01_S06_T01 — Scaffold classifiers template assets

## Objective
Create self-contained training assets for the `classifiers` template directory so jobs can be scaffolded, validated, and run without manual setup.

## Target Directory
`.training/template/classifiers/`

## Files to Create

| File | Purpose |
|------|---------|
| `data/train.csv` | Stub CSV with 10 rows: `feature1,feature2,feature3,label` |
| `validate.py` | Pre-flight checks: file exists, readable, correct columns |
| `train.py` | Training script with `--smoke` flag; writes `results.json` |
| `requirements.txt` | Pinned deps: scikit-learn, pandas, numpy |

## Implementation Approach

1. **data/train.csv** — 10 rows of float features + binary integer labels, hand-crafted to be deterministically parseable.
2. **validate.py** — uses stdlib `csv` module only (no heavy deps at validation time); exits 0 on pass, 1 on failure.
3. **train.py** — uses `argparse`, `pandas`, `sklearn.linear_model.LogisticRegression`; `--smoke` forces `max_iter=1`; writes `results.json` containing status, epochs, samples. Optional `--output-dir` for artifact placement.
4. **requirements.txt** — pinned lower bounds for scikit-learn, pandas, numpy.

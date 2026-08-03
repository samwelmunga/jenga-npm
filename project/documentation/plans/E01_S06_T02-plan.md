# Plan: E01_S06_T02 — Scaffold Transformers Template Assets

## Objective
Create the full self-contained asset set for the `transformers` training type template directory at `.training/template/transformers/`.

## Directory
`.training/template/transformers/` (sibling to `.training/template/classifiers/`)

## Assets to Create

### `data/train.txt`
- Newline-delimited token sequences (at least 10 lines)
- Space-separated tokens per line
- No preprocessing required

### `validate.py`
1. Check `data/train.txt` exists relative to script location
2. Open and read the file
3. Verify at least one non-empty line
4. Print success and exit 0; exit 1 with descriptive error otherwise

### `train.py`
1. Accept `--smoke` flag and optional `--output-dir`
2. Load `data/train.txt`
3. In smoke mode: simulate one epoch (iterate sequences, count tokens)
4. Write `results.json`: `{"status": "smoke_complete", "epochs": 1, "sequences": N, "total_tokens": M}`
5. No hard torch/transformers imports in smoke path

### `requirements.txt`
```
torch>=2.0.0
transformers>=4.30.0
numpy>=1.24.0
```

## Verification Steps
- `python validate.py` → exits 0
- `python train.py --smoke` → exits 0, produces `results.json`

## Constraints
- No references to shared lib or other template types
- Smoke mode must work without torch/transformers installed

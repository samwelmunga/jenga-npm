# Plan: E01_S06_T03 — Scaffold nlp template assets

## Objective
Create a fully self-contained NLP training type template directory at `.training/template/nlp/` with working `train.py`, `validate.py`, `data/train.txt`, and `requirements.txt`.

## Steps

1. **Append sender to `project/logs/events.json`**
2. **Create `data/train.txt`** — 20+ natural-language sentences across multiple topics
3. **Create `validate.py`** — checks file existence, readability, non-empty content; exits 0 on pass
4. **Create `train.py`** — accepts `--smoke` flag; reads data, counts words, writes `results.json`
5. **Create `requirements.txt`** — pinned NLP dependencies (nltk, numpy, scikit-learn)
6. **Verify** — run `validate.py` and `train.py --smoke` to confirm both pass
7. **Write summary** at `project/documentation/summaries/E01_S06_T03-summary.md`
8. **Commit** changes
9. **Update task board** — set status to Passed

## Constraints
- No references to shared lib or other template types
- All paths relative to script location
- `train.py --smoke` must produce `results.json` artifact

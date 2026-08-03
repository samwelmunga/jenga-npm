# Plan: E04_S01 — Core /convert Skill

## Objective
Implement `skills/convert/convert_cli.py` — a standalone CLI tool that converts JSON, JSONL, YAML, and YML dataset files into CSV format for consumption by `/train` jobs.

## Approach

### 1. Scaffold `skills/convert/`
- `convert_cli.py` — Python implementation
- `SKILL.md` — documentation

### 2. Core Logic in `convert_cli.py`

#### CLI entry point
`python convert_cli.py <path-to-file>`

#### Format detection
Determine format from file extension:
- `.json` → JSON (array or object)
- `.jsonl` → JSON Lines (one JSON object per line)
- `.yaml` / `.yml` → YAML
- `.csv` → pass-through (return as-is)
- other → error with clear message

#### Conversion pipeline
1. **Load** data from the detected format
2. **Sniff** top-level structure:
   - `[]` list → proceed directly
   - `{}` dict → warn user, ask for confirmation, then flatten dict values to rows or wrap keys as a single row
3. **Flatten** each record using dot-notation (recursive):
   - `{"user": {"age": 30}}` → `{"user.age": 30}`
   - Leaf arrays are JSON-serialised as strings
4. **Write** flattened records to CSV using `csv.DictWriter` with a unified fieldset (union of all keys across records)
5. Output path = same dir as input, `.csv` extension

#### Pass-through
If input is already `.csv`, print a message and return the path unchanged.

### 3. Dependencies
- Standard library only: `json`, `csv`, `pathlib`, `sys`, `argparse`
- Optional: `pyyaml` for YAML support (graceful error if unavailable)

### 4. Testing Plan
Create test fixtures in `skills/convert/tests/`:
- `sample.json` — JSON array with nested objects
- `sample.jsonl` — 3 JSONL lines, some with nested keys
- `sample.yaml` — YAML array of records
- `sample_obj.json` — top-level JSON object (object-sniff test)
- `sample.csv` — existing CSV (pass-through test)

Run each through `convert_cli.py` and verify output CSVs.

### 5. SKILL.md
Document: what it does, invocation syntax, supported formats, examples.

## Files to Create
- `skills/convert/convert_cli.py`
- `skills/convert/SKILL.md`
- `skills/convert/tests/sample.json`
- `skills/convert/tests/sample.jsonl`
- `skills/convert/tests/sample.yaml`
- `skills/convert/tests/sample_obj.json`
- `skills/convert/tests/sample.csv`

## Files to Update
- `project/logs/events.json` — append sender event
- `project/board/stories/E04_S01_core-convert-skill.md` — set status to Passed

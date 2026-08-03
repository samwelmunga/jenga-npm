# Summary: E04_S01 — Core /convert Skill

## Status: Passed

## What Was Implemented

### `skills/convert/convert_cli.py`
A standalone Python CLI tool that converts dataset files to CSV format.

**Supported inputs:**
- `.json` — JSON array (or object with user confirmation)
- `.jsonl` — JSON Lines (one record per line)
- `.yaml` / `.yml` — YAML array of records (or object with confirmation)
- `.csv` — pass-through (returned unchanged)

**Key features:**
- Auto-detects format from file extension
- Dot-notation flattening for nested dicts (e.g. `{"user": {"age": 30}}` → `user.age` column)
- Lists within records are serialised as JSON strings
- Top-level `{}` object triggers a warning + user confirmation before converting
- Output is written to the same directory as the input with a `.csv` extension
- `--help` / `-h` displays usage

### `skills/convert/SKILL.md`
Full documentation: purpose, invocation syntax, supported formats, dot-notation flattening rules, examples.

### Test Fixtures (`skills/convert/tests/`)
| File | Purpose |
|------|---------|
| `sample.json` | JSON array with nested objects and arrays |
| `sample.jsonl` | JSONL with nested dicts and sparse keys |
| `sample.yaml` | YAML array of records with nested meta |
| `sample_obj.json` | Top-level JSON object (confirms object-sniff flow) |
| `sample.csv` | Existing CSV for pass-through test |

## Test Results

All acceptance criteria verified:

| Test | Result |
|------|--------|
| `sample.json` → `sample.csv` (3 rows, `user.name`, `user.age`, `tags`) | ✅ |
| `sample.jsonl` → `sample.csv` (3 rows, `user.name`, `extra.source`) | ✅ |
| `sample.yaml` → `sample.csv` (3 rows, `meta.source`, `meta.lang`) | ✅ |
| `sample_obj.json` → `sample_obj.csv` (1 row, `address.city`, `address.zip`) | ✅ |
| `sample.csv` pass-through (no conversion, path returned) | ✅ |

## Acceptance Criteria Check

- [x] `convert <path>` auto-detects format from file extension
- [x] `.json` (array), `.jsonl`, `.yaml`, `.yml` all converted to `.csv`
- [x] Top-level `{}` object triggers warning + confirmation before proceeding
- [x] Nested structures flattened using dot-notation
- [x] `.csv` input returned as-is with no conversion
- [x] Output CSV written to same directory as input with `.csv` extension

## Definition of Done Check

- [x] `skills/convert/` scaffolded with `SKILL.md`
- [x] All four input formats handled and tested
- [x] Dot-notation flattening implemented
- [x] Pass-through behaviour implemented
- [x] Standalone invocation documented

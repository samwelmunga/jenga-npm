---
name: j:j-convert
description: Polyfill alias of the convert skill under a collision-safe directory name. Identical behavior to /convert — Convert JSON, JSONL, YAML, or YML dataset files to CSV format. Pass-through for files already in CSV. Flattens nested structures using dot-notation. Use when the bare /convert form is shadowed by another tool's own built-in command of the same name.
keywords:
  - convert
  - csv
  - json to csv
  - yaml to csv
  - dataset format
  - j-convert
  - polyfill
examples:
  - "convert this JSON file to CSV"
  - "convert my dataset to CSV format"
  - "j-convert"
---

# Convert — Dataset File Converter

This skill is a literal-directory-name duplicate of `skills/convert/`. It exists so that `/j-convert` (and `j:j-convert`) give a guaranteed-unshadowed way to reach the same flow as `/convert`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/convert` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh convert` from `skills/convert/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## What It Does

`/convert` takes a dataset file in JSON, JSONL, YAML, or YML format and outputs a clean CSV file ready for use in `/train` jobs.

- **Auto-detects** the input format from the file extension
- **Flattens** nested objects using dot-notation (e.g. `{"user": {"age": 30}}` → column `user.age`)
- **Pass-through**: if the input is already `.csv`, it is returned unchanged
- **Warns** if the top-level structure is an object `{}` instead of an array `[]`, and asks for confirmation before converting

Output is written to the **same directory** as the input file, with a `.csv` extension.

---

## Invocation

```bash
python skills/j-convert/convert_cli.py <path-to-file>
```

Or, when invoked through the Copilot CLI:

```
/convert <path-to-file>
```

---

## Supported Formats

| Extension     | Description                                      |
|---------------|--------------------------------------------------|
| `.json`       | JSON array `[{...}, ...]` or object `{...}`      |
| `.jsonl`      | JSON Lines — one JSON object per line            |
| `.yaml`/`.yml`| YAML array of records or mapping                 |
| `.csv`        | Already CSV — returned as-is (no conversion)     |

---

## Examples

### JSON array → CSV

```bash
python skills/j-convert/convert_cli.py data/train.json
# Output: data/train.csv
```

### JSONL with nested structures → CSV

Input `data/train.jsonl`:
```
{"id": 1, "user": {"name": "Alice", "age": 30}, "label": "pos"}
{"id": 2, "user": {"name": "Bob",   "age": 25}, "label": "neg"}
```

Output `data/train.csv`:
```
id,user.name,user.age,label
1,Alice,30,pos
2,Bob,25,neg
```

### YAML → CSV

```bash
python skills/j-convert/convert_cli.py data/train.yaml
# Output: data/train.csv
```

### CSV pass-through

```bash
python skills/j-convert/convert_cli.py data/train.csv
# ✅ Input is already CSV — no conversion needed: /path/to/data/train.csv
```

### JSON object (top-level `{}`)

When the file's top-level structure is an object rather than an array, the tool warns:

```
⚠️  Warning: 'config.json' has a top-level object ({...}), not an array ([...]).
   The tool will create a single-row CSV where each top-level key becomes a column.
   Proceed? [y/N]
```

---

## Dot-Notation Flattening

Nested dicts are flattened recursively:

| Input JSON                              | CSV column     | Value |
|-----------------------------------------|----------------|-------|
| `{"user": {"name": "Alice"}}`           | `user.name`    | Alice |
| `{"user": {"address": {"city": "NYC"}}}` | `user.address.city` | NYC |
| `{"tags": ["ml", "nlp"]}`               | `tags`         | `["ml", "nlp"]` (JSON string) |

Lists nested within records are preserved as JSON strings.

---

## Notes

- Requires `pyyaml` for YAML/YML support: `pip install pyyaml`
- Standard library only for JSON and JSONL (no extra dependencies)
- Columns are ordered by first appearance across all records
- Records missing a key will have an empty cell in that column

#!/usr/bin/env python3
"""
convert_cli.py — Dataset file converter for ML training jobs.

Usage:
    python convert_cli.py <path-to-file>

Supported input formats:
    .json   — JSON array of records (or object, with confirmation)
    .jsonl  — JSON Lines (one record per line)
    .yaml   — YAML array of records (or object, with confirmation)
    .yml    — same as .yaml
    .csv    — pass-through (returned as-is, no conversion)

Output:
    Written to the same directory as the input file with a .csv extension.
    e.g.  data/train.json  →  data/train.csv
"""
import csv
import json
import sys
from pathlib import Path

try:
    import yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

SUPPORTED_EXTENSIONS = {".json", ".jsonl", ".yaml", ".yml", ".csv"}


# ---------------------------------------------------------------------------
# Flattening
# ---------------------------------------------------------------------------

def _flatten(record, prefix=""):
    """
    Recursively flatten a nested dict using dot-notation keys.
    Non-dict values (including lists) are kept as-is (lists become JSON strings).
    """
    out = {}
    for k, v in record.items():
        full_key = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            out.update(_flatten(v, full_key))
        elif isinstance(v, list):
            out[full_key] = json.dumps(v)
        else:
            out[full_key] = v
    return out


def flatten_records(records):
    """Flatten a list of dicts. Returns a list of flat dicts."""
    return [_flatten(r) if isinstance(r, dict) else {"value": r} for r in records]


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------

def load_json(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return data


def load_jsonl(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(f"⚠️  Skipping line {lineno} — JSON parse error: {e}")
    return records


def load_yaml(path):
    if not _YAML_AVAILABLE:
        print("❌ PyYAML is not installed. Install it with: pip install pyyaml")
        sys.exit(1)
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data


# ---------------------------------------------------------------------------
# Top-level structure sniff + normalisation
# ---------------------------------------------------------------------------

def _confirm_object_conversion(path, yes=False):
    """
    Warn the user that the top-level structure is a dict (not a list),
    and ask whether to proceed by treating each top-level key as a column.
    Returns True to proceed, False to abort.
    When yes=True, auto-confirms without prompting (for non-interactive use).
    """
    print(f"\n⚠️  Warning: '{path.name}' has a top-level object ({{...}}), not an array ([...]).")
    print("   The tool will create a single-row CSV where each top-level key becomes a column.")
    if yes:
        print("   Auto-confirming (--yes flag set).")
        return True
    try:
        answer = input("   Proceed? [y/N] ").strip().lower()
    except EOFError:
        answer = "n"
    return answer in ("y", "yes")


def normalise_to_records(data, path, yes=False):
    """
    Ensure data is a list of dicts.
    - list  → used directly
    - dict  → warn + confirm, then wrap as [data]
    - other → error
    When yes=True, dict top-level is auto-confirmed.
    """
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        if not _confirm_object_conversion(path, yes=yes):
            print("❌ Conversion aborted by user.")
            sys.exit(0)
        return [data]
    print(f"❌ Unsupported top-level type '{type(data).__name__}'. Expected a list or dict.")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------

def write_csv(records, output_path):
    """Write a list of flat dicts to a CSV file."""
    if not records:
        print(f"⚠️  No records to write — creating empty CSV at {output_path}")
        output_path.write_text("")
        return

    # Build a unified ordered fieldset (preserving first-seen order)
    fieldnames = list(dict.fromkeys(k for r in records for k in r))

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)

    print(f"✅ Converted → {output_path}  ({len(records)} row{'s' if len(records) != 1 else ''})")


# ---------------------------------------------------------------------------
# Main conversion entry point
# ---------------------------------------------------------------------------

def convert(input_path_str, yes=False):
    """
    Convert the given file to CSV.
    Returns the output path (str), or the input path for .csv pass-through.
    When yes=True, object top-level confirmation is auto-accepted.
    """
    path = Path(input_path_str).resolve()

    if not path.exists():
        print(f"❌ File not found: {path}")
        sys.exit(1)

    ext = path.suffix.lower()

    if ext not in SUPPORTED_EXTENSIONS:
        print(f"❌ Unsupported file extension '{ext}'.")
        print(f"   Supported: {', '.join(sorted(SUPPORTED_EXTENSIONS))}")
        sys.exit(1)

    # Pass-through for CSV
    if ext == ".csv":
        print(f"✅ Input is already CSV — no conversion needed: {path}")
        return str(path)

    # Load data based on format
    if ext == ".json":
        data = load_json(path)
    elif ext == ".jsonl":
        data = load_jsonl(path)
        # JSONL is already a list of records
        records = flatten_records(normalise_to_records(data, path, yes=yes))
        output_path = path.with_suffix(".csv")
        write_csv(records, output_path)
        return str(output_path)
    elif ext in (".yaml", ".yml"):
        data = load_yaml(path)
    else:
        print(f"❌ Extension '{ext}' reached conversion without a handler — this is a bug.")
        sys.exit(1)

    records = flatten_records(normalise_to_records(data, path, yes=yes))
    output_path = path.with_suffix(".csv")
    write_csv(records, output_path)
    return str(output_path)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    args = [a for a in sys.argv[1:] if a not in ("-h", "--help")]
    help_requested = "-h" in sys.argv or "--help" in sys.argv
    yes = "--yes" in args or "--no-confirm" in args
    file_args = [a for a in args if not a.startswith("--")]

    if help_requested or len(file_args) != 1:
        print("Usage: python convert_cli.py <path-to-file> [--yes]")
        print()
        print("Supported formats: .json, .jsonl, .yaml, .yml, .csv")
        print()
        print("Options:")
        print("  --yes, --no-confirm   Auto-confirm object-to-CSV conversion (non-interactive)")
        print()
        print("Examples:")
        print("  python convert_cli.py data/train.json")
        print("  python convert_cli.py data/train.jsonl --yes")
        print("  python convert_cli.py data/train.yaml")
        print("  python convert_cli.py data/train.csv   # pass-through")
        sys.exit(0 if help_requested else 1)

    convert(file_args[0], yes=yes)


if __name__ == "__main__":
    main()

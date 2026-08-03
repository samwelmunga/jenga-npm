#!/usr/bin/env python3
"""Pre-flight validation script for classifiers template data."""
import csv
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_FILE = SCRIPT_DIR / "data" / "train.csv"
EXPECTED_COLUMNS = {"feature1", "feature2", "feature3", "label"}


def main():
    if not DATA_FILE.exists():
        print(f"❌ Validation failed: {DATA_FILE} does not exist.", file=sys.stderr)
        sys.exit(1)

    try:
        with DATA_FILE.open(newline="") as f:
            reader = csv.DictReader(f)
            first_row = next(reader, None)
    except Exception as e:
        print(f"❌ Validation failed: could not read {DATA_FILE}: {e}", file=sys.stderr)
        sys.exit(1)

    if first_row is None:
        print(f"❌ Validation failed: {DATA_FILE} is empty.", file=sys.stderr)
        sys.exit(1)

    actual_columns = set(first_row.keys())
    missing = EXPECTED_COLUMNS - actual_columns
    if missing:
        print(
            f"❌ Validation failed: missing columns {sorted(missing)} in {DATA_FILE}.",
            file=sys.stderr,
        )
        sys.exit(1)

    print("✅ Validation passed: data/train.csv is valid.")
    sys.exit(0)


if __name__ == "__main__":
    main()

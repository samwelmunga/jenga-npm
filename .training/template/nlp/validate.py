#!/usr/bin/env python3
"""
validate.py — Pre-flight validation for the NLP training template.

Checks that data/train.txt exists, is readable, and contains non-empty text.
Exits 0 on pass; exits 1 with a descriptive error on failure.
"""

import sys
from pathlib import Path

DATA_FILE = Path(__file__).parent / "data" / "train.txt"


def validate():
    if not DATA_FILE.exists():
        print(f"❌ Validation failed: {DATA_FILE} does not exist.", file=sys.stderr)
        sys.exit(1)

    try:
        content = DATA_FILE.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"❌ Validation failed: could not read {DATA_FILE}: {exc}", file=sys.stderr)
        sys.exit(1)

    non_blank_lines = [line for line in content.splitlines() if line.strip()]
    if not non_blank_lines:
        print(
            f"❌ Validation failed: {DATA_FILE} is empty or contains only blank lines.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"✅ Validation passed: data/train.txt is valid.")


if __name__ == "__main__":
    validate()

#!/usr/bin/env python3
"""
validate.py — Pre-flight validation for the transformers training template.

Checks:
  1. data/train.txt exists relative to this script
  2. The file can be read
  3. At least one non-empty line (token sequence) is present

Exits 0 on success, 1 on failure with a descriptive error message.
"""

import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(SCRIPT_DIR, "data", "train.txt")


def main():
    # Check existence
    if not os.path.isfile(DATA_FILE):
        print(f"❌ Validation failed: data/train.txt not found at {DATA_FILE}", file=sys.stderr)
        sys.exit(1)

    # Read file
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Verify at least one non-empty sequence
    sequences = [line.strip() for line in lines if line.strip()]
    if not sequences:
        print("❌ Validation failed: data/train.txt is empty or contains only blank lines.", file=sys.stderr)
        sys.exit(1)

    # Verify sequences have tokens (non-trivial content)
    for i, seq in enumerate(sequences):
        tokens = seq.split()
        if len(tokens) == 0:
            print(f"❌ Validation failed: line {i + 1} produced no tokens after splitting.", file=sys.stderr)
            sys.exit(1)

    print(f"✅ Validation passed: data/train.txt is valid. ({len(sequences)} sequences found)")
    sys.exit(0)


if __name__ == "__main__":
    main()

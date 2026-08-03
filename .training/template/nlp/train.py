#!/usr/bin/env python3
"""
train.py — Training script for the NLP template.

Usage:
    python train.py --smoke [--output-dir <dir>]

In smoke mode, runs a single simulated epoch: reads data/train.txt,
counts words per line, records totals, and writes results.json.
"""

import argparse
import json
import sys
from pathlib import Path

DATA_FILE = Path(__file__).parent / "data" / "train.txt"


def parse_args():
    parser = argparse.ArgumentParser(description="NLP template training script")
    parser.add_argument("--smoke", action="store_true", help="Run a single smoke-test epoch")
    parser.add_argument("--output-dir", default=None, help="Directory to write results.json")
    return parser.parse_args()


def load_data():
    if not DATA_FILE.exists():
        print(f"❌ Data file not found: {DATA_FILE}", file=sys.stderr)
        sys.exit(1)
    lines = [line.strip() for line in DATA_FILE.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not lines:
        print(f"❌ Data file is empty: {DATA_FILE}", file=sys.stderr)
        sys.exit(1)
    return lines


def run_smoke(lines, output_dir: Path):
    total_words = sum(len(line.split()) for line in lines)
    result = {
        "status": "smoke_complete",
        "epochs": 1,
        "lines": len(lines),
        "total_words": total_words,
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / "results.json"
    output_path.write_text(json.dumps(result, indent=2), encoding="utf-8")

    print(f"✅ Smoke run complete — {len(lines)} lines, {total_words} words. Results: {output_path}")
    return result


def main():
    args = parse_args()

    if not args.smoke:
        print("ℹ️  No mode specified. Use --smoke to run a smoke test.")
        sys.exit(0)

    output_dir = Path(args.output_dir) if args.output_dir else Path(__file__).parent

    lines = load_data()
    run_smoke(lines, output_dir)


if __name__ == "__main__":
    main()

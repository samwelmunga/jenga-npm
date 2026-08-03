#!/usr/bin/env python3
"""
train.py — Training script for the transformers template.

Usage:
    python train.py --smoke [--output-dir <path>]

Flags:
    --smoke        Run a single-epoch simulation using stub data. Does not
                   require torch or transformers to be installed.
    --output-dir   Directory to write results.json (default: current directory)

In smoke mode this script reads data/train.txt, iterates through all sequences
once (one simulated epoch), counts tokens, and writes results.json.
"""

import argparse
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_FILE = os.path.join(SCRIPT_DIR, "data", "train.txt")


def load_sequences():
    if not os.path.isfile(DATA_FILE):
        print(f"❌ data/train.txt not found at {DATA_FILE}", file=sys.stderr)
        sys.exit(1)
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        sequences = [line.strip() for line in f if line.strip()]
    return sequences


def run_smoke(output_dir):
    sequences = load_sequences()

    total_tokens = 0
    for seq in sequences:
        total_tokens += len(seq.split())

    result = {
        "status": "smoke_complete",
        "epochs": 1,
        "sequences": len(sequences),
        "total_tokens": total_tokens,
    }

    os.makedirs(output_dir, exist_ok=True)
    out_path = os.path.join(output_dir, "results.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    print(f"✅ Smoke run complete: {len(sequences)} sequences, {total_tokens} tokens.")
    print(f"   Results written to: {out_path}")


def run_full():
    try:
        import torch  # noqa: F401
        from transformers import AutoTokenizer  # noqa: F401
    except ImportError as e:
        print(f"❌ Full training requires torch and transformers: {e}", file=sys.stderr)
        sys.exit(1)

    print("Full training mode is not implemented in this stub template.")
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(description="Transformer training script (template)")
    parser.add_argument("--smoke", action="store_true", help="Run a one-epoch smoke test")
    parser.add_argument("--output-dir", default=".", help="Directory to write results.json")
    args = parser.parse_args()

    if args.smoke:
        run_smoke(args.output_dir)
    else:
        run_full()


if __name__ == "__main__":
    main()

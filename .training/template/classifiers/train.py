#!/usr/bin/env python3
"""Classifier training script with --smoke mode."""
import argparse
import json
import sys
from pathlib import Path

import pandas as pd
from sklearn.linear_model import LogisticRegression

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_FILE = SCRIPT_DIR / "data" / "train.csv"


def parse_args():
    parser = argparse.ArgumentParser(description="Train a classifier.")
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Run a single-epoch smoke test and exit.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory to write output artifacts (default: script directory).",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    output_dir = Path(args.output_dir) if args.output_dir else SCRIPT_DIR
    output_dir.mkdir(parents=True, exist_ok=True)

    if not DATA_FILE.exists():
        print(f"❌ Data file not found: {DATA_FILE}", file=sys.stderr)
        sys.exit(1)

    df = pd.read_csv(DATA_FILE)
    X = df[["feature1", "feature2", "feature3"]].values
    y = df["label"].values
    n_samples = len(df)

    max_iter = 1 if args.smoke else 100
    model = LogisticRegression(max_iter=max_iter, solver="lbfgs")
    model.fit(X, y)

    epochs = 1 if args.smoke else max_iter
    status = "smoke_complete" if args.smoke else "complete"
    results = {"status": status, "epochs": epochs, "samples": n_samples}

    results_path = output_dir / "results.json"
    with results_path.open("w") as f:
        json.dump(results, f, indent=2)

    print(f"✅ Training {status}. Results written to {results_path}")
    sys.exit(0)


if __name__ == "__main__":
    main()

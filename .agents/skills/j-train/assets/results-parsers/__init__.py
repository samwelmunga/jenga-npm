"""
results-parsers — ML training result extraction utilities.

Each submodule exposes:  parse(job_dir: Path) -> dict
Each submodule extracts type-specific metrics from job output artifacts.
"""
from pathlib import Path

PARSERS = ["classifiers", "transformers", "nlp"]

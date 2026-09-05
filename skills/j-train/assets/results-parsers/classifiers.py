"""
classifiers.py — Results parser for sklearn-based classifier jobs.

Extracts: accuracy, precision, recall, f1_score, model_type.
Reads from results.json or scans training-results/ for JSON files.
"""
import json
from pathlib import Path


def parse(job_dir: Path) -> dict:
    """
    Parse training results for a classifiers job.

    Returns a dict with keys:
        accuracy, precision, recall, f1_score, model_type
    Returns empty dict if no results can be found; never raises.
    """
    job_dir = Path(job_dir)
    metrics = {}

    # 1. Try results.json at root
    results_json = job_dir / "results.json"
    if results_json.exists():
        try:
            data = json.loads(results_json.read_text())
            metrics = _extract_from_dict(data)
            if metrics:
                return metrics
        except Exception:
            pass

    # 2. Scan training-results/ for any JSON files
    training_results_dir = job_dir / "training-results"
    if training_results_dir.exists():
        for json_file in sorted(training_results_dir.rglob("*.json")):
            try:
                data = json.loads(json_file.read_text())
                metrics = _extract_from_dict(data)
                if metrics:
                    return metrics
            except Exception:
                continue

    return metrics


def _extract_from_dict(data: dict) -> dict:
    """Extract classifier-relevant keys from a parsed dict."""
    metrics = {}
    if not isinstance(data, dict):
        return metrics

    # Common field names produced by sklearn classification_report / custom scripts
    field_map = {
        "accuracy": ["accuracy", "test_accuracy", "val_accuracy", "acc"],
        "precision": ["precision", "weighted avg.precision", "macro avg.precision"],
        "recall": ["recall", "weighted avg.recall", "macro avg.recall"],
        "f1_score": ["f1_score", "f1", "weighted avg.f1-score", "macro avg.f1-score"],
        "model_type": ["model_type", "model", "algorithm", "classifier"],
    }

    for target_key, candidates in field_map.items():
        for candidate in candidates:
            # Support dot-path lookup (e.g. "weighted avg.precision")
            value = _deep_get(data, candidate)
            if value is not None:
                metrics[target_key] = value
                break

    return metrics


def _deep_get(data: dict, dotted_key: str):
    """Retrieve a value from a nested dict using a dot-separated key path."""
    keys = dotted_key.split(".")
    current = data
    for k in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(k)
        if current is None:
            return None
    return current

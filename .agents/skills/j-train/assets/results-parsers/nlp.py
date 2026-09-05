"""
nlp.py — Results parser for spaCy / NLP pipeline training jobs.

Extracts: f1, precision, recall, model_name, task, iterations.
Reads from results.json or scans training-results/ for JSON files.
"""
import json
from pathlib import Path


def parse(job_dir: Path) -> dict:
    """
    Parse training results for an nlp job.

    Returns a dict with keys:
        f1, precision, recall, model_name, task, iterations
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

    # 2. Scan training-results/ for JSON files
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

    # 3. Try spaCy training output (scores.json or metrics.json)
    for scores_file in sorted(job_dir.rglob("scores.json")) + sorted(job_dir.rglob("metrics.json")):
        try:
            data = json.loads(scores_file.read_text())
            metrics = _extract_from_dict(data)
            if metrics:
                return metrics
        except Exception:
            continue

    return metrics


def _extract_from_dict(data: dict) -> dict:
    """Extract NLP-relevant keys from a parsed dict."""
    metrics = {}
    if not isinstance(data, dict):
        return metrics

    field_map = {
        "f1": ["f1", "f1_score", "ents_f", "token_f", "tag_f", "sents_f", "score"],
        "precision": ["precision", "ents_p", "token_p", "tag_p"],
        "recall": ["recall", "ents_r", "token_r", "tag_r"],
        "model_name": ["model_name", "model", "base_model"],
        "task": ["task", "pipeline_component", "component"],
        "iterations": ["iterations", "n_iter", "steps", "batches_trained"],
    }

    for target_key, candidates in field_map.items():
        for candidate in candidates:
            value = data.get(candidate)
            if value is None:
                # Try nested under "scores" or "results" key
                for wrapper in ("scores", "results", "metrics"):
                    nested = data.get(wrapper, {})
                    if isinstance(nested, dict):
                        value = nested.get(candidate)
                    if value is not None:
                        break
            if value is not None:
                metrics[target_key] = value
                break

    return metrics

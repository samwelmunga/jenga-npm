"""
transformers.py — Results parser for HuggingFace Transformers fine-tuning jobs.

Extracts: perplexity, eval_loss, train_loss, epochs, model_name.
Reads from results.json or scans training-results/ and trainer_state.json.
"""
import json
import math
from pathlib import Path


def parse(job_dir: Path) -> dict:
    """
    Parse training results for a transformers job.

    Returns a dict with keys:
        perplexity, eval_loss, train_loss, epochs, model_name
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

    # 2. Try trainer_state.json (HuggingFace Trainer output)
    for trainer_state in sorted(job_dir.rglob("trainer_state.json")):
        try:
            data = json.loads(trainer_state.read_text())
            metrics = _extract_from_trainer_state(data)
            if metrics:
                return metrics
        except Exception:
            continue

    # 3. Scan training-results/ for JSON files
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
    """Extract transformer-relevant keys from a parsed dict."""
    metrics = {}
    if not isinstance(data, dict):
        return metrics

    field_map = {
        "eval_loss": ["eval_loss", "validation_loss", "val_loss"],
        "train_loss": ["train_loss", "training_loss", "loss"],
        "epochs": ["epochs", "num_train_epochs", "epoch"],
        "model_name": ["model_name", "model", "base_model", "pretrained_model_name_or_path"],
        "perplexity": ["perplexity", "eval_perplexity"],
    }

    for target_key, candidates in field_map.items():
        for candidate in candidates:
            value = data.get(candidate)
            if value is not None:
                metrics[target_key] = value
                break

    # Derive perplexity from eval_loss if not already present
    if "perplexity" not in metrics and "eval_loss" in metrics:
        try:
            metrics["perplexity"] = round(math.exp(float(metrics["eval_loss"])), 4)
        except (ValueError, OverflowError):
            pass

    return metrics


def _extract_from_trainer_state(data: dict) -> dict:
    """Extract metrics from HuggingFace Trainer's trainer_state.json."""
    metrics = {}
    if not isinstance(data, dict):
        return metrics

    # Best metrics
    best_metric = data.get("best_metric")
    if best_metric is not None:
        metrics["eval_loss"] = best_metric

    # Epoch count
    epoch = data.get("epoch")
    if epoch is not None:
        metrics["epochs"] = epoch

    # Last eval from log history
    log_history = data.get("log_history", [])
    for entry in reversed(log_history):
        if "eval_loss" in entry:
            metrics["eval_loss"] = entry["eval_loss"]
            break

    # Derive perplexity
    if "perplexity" not in metrics and "eval_loss" in metrics:
        try:
            metrics["perplexity"] = round(math.exp(float(metrics["eval_loss"])), 4)
        except (ValueError, OverflowError):
            pass

    return metrics

"""
reporter.py — Surface training results to terminal, summary.md, and results.json.

Usage:
    from skills.train.assets.results_parsers.reporter import surface_results
    surface_results(job_dir, job_type)
"""
import importlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_PARSER_PKG = Path(__file__).resolve().parent
sys.path.insert(0, str(_PARSER_PKG.parent.parent.parent))  # ensure skills/ is on path


def _load_parser(job_type: str):
    """Dynamically import the type-specific parser module."""
    try:
        spec_path = _PARSER_PKG / f"{job_type}.py"
        import importlib.util
        spec = importlib.util.spec_from_file_location(job_type, spec_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception as e:
        return None


def _format_value(v) -> str:
    if isinstance(v, float):
        return f"{v:.4f}"
    return str(v)


def _print_terminal_summary(job_dir: Path, job_type: str, metrics: dict):
    """Print a box-formatted summary to stdout."""
    job_name = job_dir.name
    width = 54
    border = "─" * width
    print(f"\n┌{border}┐")
    print(f"│  📊 Training Summary — {job_name:<{width - 25}}│")
    print(f"│  Type: {job_type:<{width - 9}}│")
    print(f"├{border}┤")
    if metrics:
        for k, v in metrics.items():
            label = k.replace("_", " ").title()
            value = _format_value(v)
            line = f"  {label}: {value}"
            print(f"│{line:<{width + 1}}│")
    else:
        print(f"│  (no metrics found — check training-results/ or results.json)  │")
    print(f"└{border}┘\n")


def _write_summary_md(job_dir: Path, job_type: str, metrics: dict):
    """Write a Markdown summary file to the job directory."""
    job_name = job_dir.name
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        f"# Training Summary — {job_name}",
        f"",
        f"**Type:** {job_type}  ",
        f"**Generated:** {timestamp}  ",
        f"",
        f"## Metrics",
        f"",
        f"| Metric | Value |",
        f"|--------|-------|",
    ]
    if metrics:
        for k, v in metrics.items():
            label = k.replace("_", " ").title()
            lines.append(f"| {label} | {_format_value(v)} |")
    else:
        lines.append("| — | No metrics found |")

    summary_path = job_dir / "summary.md"
    summary_path.write_text("\n".join(lines) + "\n")
    return summary_path


def _write_results_json(job_dir: Path, job_type: str, metrics: dict):
    """Write or update results.json in the job directory."""
    results_path = job_dir / "results.json"

    # Merge with existing results.json if present
    existing = {}
    if results_path.exists():
        try:
            existing = json.loads(results_path.read_text())
        except Exception:
            pass

    existing.update({
        "job_name": job_dir.name,
        "job_type": job_type,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "metrics": metrics,
    })

    results_path.write_text(json.dumps(existing, indent=2))
    return results_path


def surface_results(job_dir, job_type: str):
    """
    Parse training results for the given job and surface them:
    1. Print terminal summary
    2. Write summary.md to job directory
    3. Write/update results.json in job directory

    Args:
        job_dir: Path (or str) to the job directory
        job_type: One of 'classifiers', 'transformers', 'nlp'
    """
    job_dir = Path(job_dir)

    parser = _load_parser(job_type)
    if parser is None:
        print(f"⚠️  No parser found for type '{job_type}' — skipping result surfacing.")
        return {}

    try:
        metrics = parser.parse(job_dir) or {}
    except Exception as e:
        print(f"⚠️  Parser error for '{job_type}': {e}")
        metrics = {}

    _print_terminal_summary(job_dir, job_type, metrics)

    try:
        summary_path = _write_summary_md(job_dir, job_type, metrics)
        print(f"📄 summary.md written to {summary_path}")
    except Exception as e:
        print(f"⚠️  Could not write summary.md: {e}")

    try:
        results_path = _write_results_json(job_dir, job_type, metrics)
        print(f"📄 results.json written to {results_path}")
    except Exception as e:
        print(f"⚠️  Could not write results.json: {e}")

    return metrics


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="Surface training results for a job directory.")
    p.add_argument("job_dir", help="Path to the job directory")
    p.add_argument("job_type", choices=["classifiers", "transformers", "nlp"])
    ns = p.parse_args()
    surface_results(ns.job_dir, ns.job_type)

#!/usr/bin/env python3
"""
train_cli.py — Two-phase ML training job orchestrator.

Subcommands:
  new <type> <job-name>            Scaffold a job from a template
  new --interactive [--full]       Launch wizard to scaffold and configure interactively
  run <job-dir>                    Execute validate.py -> train.py --smoke pipeline
"""
import argparse
import shutil
import signal
import subprocess
import sys
from pathlib import Path

try:
    import yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

VALID_TYPES = ["classifiers", "transformers", "nlp"]
REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ---------------------------------------------------------------------------
# Wizard field schemas
# Each entry: {"key": "dot.notation.path", "prompt": "...", "hint": "...", "default": "..."}
# Fields listed under "critical" are shown with --interactive.
# Fields under "full" are ADDITIONAL fields shown when --full is also passed.
# ---------------------------------------------------------------------------
WIZARD_FIELDS = {
    "classifiers": {
        "critical": [
            {
                "key": "data.train_file",
                "prompt": "Training data file path",
                "hint": "Path to CSV file with training samples",
                "default": "input/data/train.csv",
            },
            {
                "key": "data.target_column",
                "prompt": "Target column name",
                "hint": "Column in the CSV that contains class labels",
                "default": "label",
            },
            {
                "key": "model.type",
                "prompt": "Classifier algorithm",
                "hint": "One of: random_forest, gradient_boosting, svm, logistic_regression, xgboost",
                "default": "random_forest",
            },
            {
                "key": "model.params.n_estimators",
                "prompt": "Number of estimators",
                "hint": "Trees for random_forest / gradient_boosting (ignored for svm / logistic_regression)",
                "default": "100",
            },
            {
                "key": "data.test_size",
                "prompt": "Test split ratio",
                "hint": "Fraction of data held out for testing, e.g. 0.2 = 20%",
                "default": "0.2",
            },
        ],
        "full": [
            {
                "key": "data.test_file",
                "prompt": "Test data file path",
                "hint": "Separate test CSV; leave blank to auto-split from train_file",
                "default": "input/data/test.csv",
            },
            {
                "key": "model.params.max_depth",
                "prompt": "Max tree depth",
                "hint": "Maximum depth of trees; leave blank for unlimited",
                "default": "",
            },
            {
                "key": "model.params.random_state",
                "prompt": "Random state seed",
                "hint": "Integer seed for reproducibility",
                "default": "42",
            },
            {
                "key": "training.cross_validation",
                "prompt": "Enable cross-validation?",
                "hint": "true or false",
                "default": "true",
            },
            {
                "key": "training.cv_folds",
                "prompt": "Cross-validation folds",
                "hint": "Number of folds (e.g. 5)",
                "default": "5",
            },
        ],
    },
    "transformers": {
        "critical": [
            {
                "key": "model.name",
                "prompt": "HuggingFace model ID",
                "hint": "Model hub identifier, e.g. bert-base-uncased or roberta-base",
                "default": "bert-base-uncased",
            },
            {
                "key": "model.task",
                "prompt": "Fine-tuning task",
                "hint": "One of: text-classification, token-classification, question-answering, seq2seq",
                "default": "text-classification",
            },
            {
                "key": "data.train_file",
                "prompt": "Training data file path",
                "hint": "Path to .jsonl file with training samples",
                "default": "input/data/train.jsonl",
            },
            {
                "key": "training.num_train_epochs",
                "prompt": "Number of training epochs",
                "hint": "How many full passes over the training data",
                "default": "3",
            },
            {
                "key": "training.learning_rate",
                "prompt": "Learning rate",
                "hint": "AdamW learning rate, e.g. 2e-5",
                "default": "2e-5",
            },
        ],
        "full": [
            {
                "key": "data.eval_file",
                "prompt": "Evaluation data file path",
                "hint": "Path to .jsonl evaluation set",
                "default": "input/data/eval.jsonl",
            },
            {
                "key": "data.text_column",
                "prompt": "Text column name",
                "hint": "Key in each JSON record that holds the input text",
                "default": "text",
            },
            {
                "key": "data.label_column",
                "prompt": "Label column name",
                "hint": "Key in each JSON record that holds the label",
                "default": "label",
            },
            {
                "key": "data.max_length",
                "prompt": "Max token sequence length",
                "hint": "Sequences are truncated / padded to this length",
                "default": "128",
            },
            {
                "key": "training.per_device_train_batch_size",
                "prompt": "Train batch size (per device)",
                "hint": "Number of samples per GPU/CPU per step",
                "default": "16",
            },
            {
                "key": "training.warmup_steps",
                "prompt": "Warmup steps",
                "hint": "Linear LR warmup before reaching the target learning rate",
                "default": "500",
            },
            {
                "key": "training.weight_decay",
                "prompt": "Weight decay",
                "hint": "L2 regularisation coefficient",
                "default": "0.01",
            },
        ],
    },
    "nlp": {
        "critical": [
            {
                "key": "model.name",
                "prompt": "Base model name",
                "hint": "spaCy model (e.g. en_core_web_sm) or HuggingFace model ID",
                "default": "en_core_web_sm",
            },
            {
                "key": "model.task",
                "prompt": "NLP task",
                "hint": "One of: ner, text-classification, pos-tagging, dependency-parsing",
                "default": "ner",
            },
            {
                "key": "data.train_file",
                "prompt": "Training data file path",
                "hint": "Path to training data (.spacy, .jsonl, or .conll)",
                "default": "input/data/train.spacy",
            },
            {
                "key": "training.n_iter",
                "prompt": "Training iterations",
                "hint": "Number of passes over the training data",
                "default": "30",
            },
            {
                "key": "training.learning_rate",
                "prompt": "Learning rate",
                "hint": "Optimiser learning rate, e.g. 1e-3",
                "default": "1e-3",
            },
        ],
        "full": [
            {
                "key": "data.eval_file",
                "prompt": "Evaluation data file path",
                "hint": "Path to evaluation data file",
                "default": "input/data/eval.spacy",
            },
            {
                "key": "training.batch_size",
                "prompt": "Batch size",
                "hint": "Number of examples per training batch",
                "default": "32",
            },
            {
                "key": "training.dropout",
                "prompt": "Dropout rate",
                "hint": "Fraction of activations to randomly zero during training",
                "default": "0.2",
            },
        ],
    },
}


CONVERT_EXTENSIONS = {".json", ".jsonl", ".yaml", ".yml"}


def _auto_convert_data_file(file_path_str):
    """
    If file_path_str points to a non-CSV file supported by /convert, invoke convert_cli.py
    automatically and return the resulting CSV path.  Returns file_path_str unchanged when:
      - the extension is already .csv
      - the file does not exist (defer the error to the training job itself)
    Aborts the wizard (sys.exit) if conversion fails.
    """
    path = Path(file_path_str)
    ext = path.suffix.lower()

    if ext not in CONVERT_EXTENSIONS:
        return file_path_str  # .csv or unknown — pass-through

    if not path.exists():
        print(f"  ⚠️  File not found: {file_path_str} — skipping auto-conversion.")
        return file_path_str

    convert_script = REPO_ROOT / "skills" / "convert" / "convert_cli.py"
    print(f"\n  🔄 Non-CSV file detected ({ext}). Auto-converting with /convert…")

    result = subprocess.run(
        [sys.executable, str(convert_script), str(path.resolve()), "--yes"],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print("\n❌ Auto-conversion failed. Aborting wizard.")
        # Show the most relevant line from stderr (last non-empty line = the actual error)
        stderr_lines = [l for l in result.stderr.strip().splitlines() if l.strip()]
        stdout_lines = [l for l in result.stdout.strip().splitlines() if l.strip()]
        for line in stdout_lines:
            print(f"   {line}")
        if stderr_lines:
            print(f"   Error: {stderr_lines[-1].strip()}")
        print("   Fix the data file and run the wizard again.")
        sys.exit(1)

    csv_path = str(path.resolve().with_suffix(".csv"))
    print(f"  ✓ Converted to CSV: {csv_path}")
    return csv_path


def _set_nested(d, dotted_key, value):
    """Set a value in a nested dict using a dot-separated key path."""
    keys = dotted_key.split(".")
    for k in keys[:-1]:
        d = d.setdefault(k, {})
    leaf = keys[-1]
    # Coerce type based on existing value when possible
    existing = d.get(leaf)
    if existing is not None:
        try:
            if isinstance(existing, bool):
                value = value.lower() in ("true", "yes", "1")
            elif isinstance(existing, int):
                value = int(value) if value != "" else None
            elif isinstance(existing, float):
                value = float(value) if value != "" else None
        except (ValueError, AttributeError):
            pass
    else:
        # Coerce from string when no existing type context
        if isinstance(value, str):
            if value.lower() in ("true", "false"):
                value = value.lower() == "true"
            else:
                for coerce in (int, float):
                    try:
                        value = coerce(value)
                        break
                    except ValueError:
                        pass
    d[leaf] = value if value != "" else None


def _prompt(field):
    """Display a single prompt with hint and return the user's answer (or default)."""
    hint = field["hint"]
    default = field["default"]
    default_display = f" [{default}]" if default else ""
    line = f"  {field['prompt']}{default_display}\n    ↳ {hint}\n  > "
    try:
        answer = input(line).strip()
    except EOFError:
        answer = ""
    return answer if answer else default


def _scaffold_job(job_type, job_name):
    """Copy the template into jobs/<job_name>. Returns the destination Path."""
    template_dir = REPO_ROOT / ".training" / "template" / job_type
    if not template_dir.exists():
        print(f"❌ Template directory not found: {template_dir}")
        sys.exit(1)

    jobs_dir = REPO_ROOT / "jobs"
    jobs_dir.mkdir(exist_ok=True)

    dest = jobs_dir / job_name
    if dest.exists():
        suffix = 1
        while (jobs_dir / f"{job_name}-{suffix}").exists():
            suffix += 1
        dest = jobs_dir / f"{job_name}-{suffix}"

    shutil.copytree(str(template_dir), str(dest))
    _stamp_template_version(dest, job_type)
    return dest


def _stamp_template_version(dest, job_type):
    """Stamp the scaffolded job's config.yaml with the current manifest version."""
    if not _YAML_AVAILABLE:
        return
    manifest_path = REPO_ROOT / ".training" / "template" / "manifest.json"
    try:
        import json
        with open(manifest_path) as f:
            manifest = json.load(f)
        version = manifest["templates"][job_type]["version"]
    except Exception as e:
        print(f"⚠️  Could not read template manifest — template_version not stamped: {e}")
        return

    config_path = dest / "input" / "config.yaml"
    if not config_path.exists():
        return
    try:
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        config["template_version"] = version
        with open(config_path, "w") as f:
            yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    except Exception as e:
        print(f"⚠️  Could not stamp template_version in config.yaml: {e}")


def _patch_config(dest, job_type, responses):
    """Apply wizard responses to the scaffolded config.yaml."""
    if not _YAML_AVAILABLE:
        print("⚠️  PyYAML not available — skipping config.yaml update. Install with: pip install pyyaml")
        return

    config_path = dest / "input" / "config.yaml"
    if not config_path.exists():
        print(f"⚠️  config.yaml not found at {config_path} — skipping patch.")
        return

    with open(config_path) as f:
        config = yaml.safe_load(f) or {}

    for key, value in responses.items():
        _set_nested(config, key, value)

    with open(config_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)


def run_wizard(full=False):
    """Interactive wizard for `train new`. Returns after scaffolding + patching config."""
    scaffold_dir = None  # set after scaffolding so SIGINT handler can reference it

    def _sigint_cleanup(signum, frame):
        print("\n\n⚠️  Wizard interrupted.")
        if scaffold_dir and scaffold_dir.exists():
            try:
                answer = input(f"  Delete scaffolded directory '{scaffold_dir}'? [y/N] ").strip().lower()
            except (EOFError, OSError):
                answer = "n"
            if answer in ("y", "yes"):
                shutil.rmtree(str(scaffold_dir))
                print(f"🗑️  Deleted {scaffold_dir}")
            else:
                print(f"📁 Kept {scaffold_dir}")
        sys.exit(0)

    original_sigint = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGINT, _sigint_cleanup)

    try:
        print("\n🧙 Train New — Interactive Wizard")
        print("  Press Enter to accept defaults  |  Ctrl+C to cancel\n")

        # --- Step 1: Job name ---
        job_name = ""
        while not job_name:
            job_name = input("  Job name  [e.g. my-classifier]\n    ↳ Unique name for the new job directory under jobs/\n  > ").strip()
            if not job_name:
                print("  ⚠️  Job name cannot be empty.\n")

        # --- Step 2: Job type ---
        job_type = ""
        while job_type not in VALID_TYPES:
            raw = input(
                f"  Job type  [{'/'.join(VALID_TYPES)}]\n"
                "    ↳ Template to scaffold: classifiers (sklearn), transformers (HuggingFace), nlp (spaCy)\n"
                "  > "
            ).strip().lower()
            if raw in VALID_TYPES:
                job_type = raw
            else:
                print(f"  ⚠️  Must be one of: {', '.join(VALID_TYPES)}\n")

        # --- Step 3: Scaffold ---
        scaffold_dir = _scaffold_job(job_type, job_name)
        print(f"\n✅ Scaffolded → {scaffold_dir.relative_to(REPO_ROOT)}/\n")
        print("  Now configuring key fields in config.yaml…\n")

        # --- Step 4: Collect config field responses ---
        schema = WIZARD_FIELDS[job_type]
        fields_to_prompt = list(schema["critical"])
        if full:
            fields_to_prompt += schema["full"]

        responses = {}
        for field in fields_to_prompt:
            value = _prompt(field)
            if value:  # only update if non-empty
                # Auto-convert non-CSV data files before writing config
                if field["key"] == "data.train_file":
                    value = _auto_convert_data_file(value)
                responses[field["key"]] = value

        # --- Step 5: Patch config.yaml ---
        _patch_config(scaffold_dir, job_type, responses)

        print(f"\n✅ Job '{scaffold_dir.name}' is ready at {scaffold_dir.relative_to(REPO_ROOT)}/")
        print(f"   config.yaml has been updated with your choices.")
        print(f"   Run: python skills/train/train_cli.py run jobs/{scaffold_dir.name}\n")

    except KeyboardInterrupt:
        # Fallback in case signal handler wasn't triggered (e.g. within input())
        _sigint_cleanup(None, None)
    finally:
        signal.signal(signal.SIGINT, original_sigint)


# ---------------------------------------------------------------------------
# CLI flag → config.yaml key mapping by job type
# ---------------------------------------------------------------------------
_FLAG_KEY_MAP = {
    "classifiers": {
        "model":      "model.type",
        "epochs":     None,   # no epochs concept for sklearn classifiers
        "batch_size": None,
    },
    "transformers": {
        "model":      "model.name",
        "epochs":     "training.num_train_epochs",
        "batch_size": "training.per_device_train_batch_size",
    },
    "nlp": {
        "model":      "model.name",
        "epochs":     "training.n_iter",
        "batch_size": "training.batch_size",
    },
}


def _apply_cli_flags(dest, job_type, args):
    """Merge --model / --epochs / --batch-size into config.yaml. Warns on no-op flags."""
    flag_map = _FLAG_KEY_MAP.get(job_type, {})
    overrides = {}

    for flag_attr, flag_label in [("model", "--model"), ("epochs", "--epochs"), ("batch_size", "--batch-size")]:
        value = getattr(args, flag_attr, None)
        if value is None:
            continue
        config_key = flag_map.get(flag_attr)
        if config_key is None:
            print(f"  ⚠️  {flag_label} has no applicable config key for type '{job_type}' — skipped.")
        else:
            overrides[config_key] = value

    if overrides:
        if not _YAML_AVAILABLE:
            print("  ⚠️  PyYAML not available — cannot apply flag overrides. Install with: pip install pyyaml")
            return
        _patch_config(dest, job_type, overrides)
        for k, v in overrides.items():
            print(f"  ✏️  config.yaml: {k} = {v}")


def _print_next_steps(dest, job_name):
    """Read the workflow: block from config.yaml and print actionable next-step hints."""
    workflow = {}
    if _YAML_AVAILABLE:
        config_path = dest / "input" / "config.yaml"
        if config_path.exists():
            try:
                with open(config_path) as f:
                    config = yaml.safe_load(f) or {}
                workflow = config.get("workflow", {})
            except Exception:
                pass

    print(f"\n📋 Next steps for '{job_name}':")
    print(f"   1. Add your training data to {dest.relative_to(REPO_ROOT)}/input/data/")
    print(f"   2. Review {dest.relative_to(REPO_ROOT)}/input/config.yaml")
    if workflow.get("generate_start_sh", True):
        print(f"   3. Run:  bash {dest.relative_to(REPO_ROOT)}/start.sh")
        print(f"      or:  python skills/train/train_cli.py run {dest.relative_to(REPO_ROOT)}")
    else:
        print(f"   3. Run:  python skills/train/train_cli.py run {dest.relative_to(REPO_ROOT)}")
    if workflow.get("confirm_before_run", False):
        print(f"   ℹ️  confirm_before_run is enabled — you will be prompted before training starts.")
    if workflow.get("auto_summarize", False):
        print(f"   ℹ️  Training results will be summarised automatically after the run.")
    print()


def _generate_start_sh(dest, job_type):
    """Write an executable start.sh into the scaffolded job directory."""
    start_sh = dest / "start.sh"
    content = f"""#!/usr/bin/env bash
# start.sh — Generated by /train skill for job type: {job_type}
# Run this script from the project root or from inside the job directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[start.sh] Preparing environment..."

# Activate virtual environment if present
if [ -f "venv/bin/activate" ]; then
    echo "[start.sh] Activating venv..."
    # shellcheck disable=SC1091
    source venv/bin/activate
fi

# Install dependencies
if [ -f "requirements.txt" ]; then
    echo "[start.sh] Installing dependencies from requirements.txt..."
    pip install -q -r requirements.txt
fi

echo "[start.sh] Starting training ({job_type})..."
python train.py

echo "[start.sh] Training complete."
"""
    start_sh.write_text(content)
    start_sh.chmod(0o755)


def cmd_new(args):
    # Interactive wizard mode
    if args.interactive:
        run_wizard(full=args.full)
        return

    # Positional (scriptable) mode — both type and job_name must be supplied
    job_type = args.type
    job_name = args.job_name

    if not job_type or not job_name:
        print("❌ Positional mode requires both <type> and <job-name>.")
        print("   Usage: train new <type> <job-name>")
        print(f"   Types: {', '.join(VALID_TYPES)}")
        print("   Or use: train new --interactive")
        sys.exit(1)

    if job_type not in VALID_TYPES:
        print(f"❌ Invalid type '{job_type}'. Must be one of: {', '.join(VALID_TYPES)}")
        sys.exit(1)

    dest = _scaffold_job(job_type, job_name)
    print(f"✅ Scaffolded job '{dest.name}' from template '{job_type}' at {dest.relative_to(REPO_ROOT)}/")

    # Apply CLI flag overrides to config.yaml (T03)
    _apply_cli_flags(dest, job_type, args)

    # Generate start.sh (E01_S04_T01)
    _generate_start_sh(dest, job_type)

    # Print workflow next-steps (T04)
    _print_next_steps(dest, dest.name)


def stream_subprocess(cmd, cwd, label):
    """Run a command, stream output line-by-line with a label prefix. Returns exit code."""
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    for line in proc.stdout:
        print(f"  {line}", end="")
    proc.wait()
    return proc.returncode


def _check_template_version_drift(job_dir):
    """Warn if the job's template_version is behind the current manifest version."""
    if not _YAML_AVAILABLE:
        return
    config_path = job_dir / "input" / "config.yaml"
    if not config_path.exists():
        return
    try:
        import json
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        job_version = config.get("template_version")
        if not job_version:
            return

        manifest_path = REPO_ROOT / ".training" / "template" / "manifest.json"
        if not manifest_path.exists():
            return
        with open(manifest_path) as f:
            manifest = json.load(f)

        # Detect job type from parent template dir match or by searching all types
        current_version = None
        for ttype, tdata in manifest.get("templates", {}).items():
            # Match by checking if the job was scaffolded from this type (best-effort: check model keys)
            current_version = tdata.get("version")
            break  # Use first match; jobs carry their own template_version for comparison

        if not current_version:
            return

        def _parse_semver(v):
            try:
                return tuple(int(x) for x in str(v).split("."))
            except Exception:
                return (0, 0, 0)

        if _parse_semver(job_version) < _parse_semver(current_version):
            print(
                f"⚠  Template version mismatch: job uses {job_version}, "
                f"current template is {current_version}. "
                f"Consider re-scaffolding or manually updating assets."
            )
    except Exception:
        pass  # drift check is non-blocking; never fail the run


def cmd_run(args):
    job_dir = Path(args.job_dir)
    if not job_dir.is_absolute():
        job_dir = Path.cwd() / job_dir
    job_dir = job_dir.resolve()

    if not job_dir.exists():
        print(f"❌ Job directory not found: {job_dir}")
        sys.exit(1)

    _check_template_version_drift(job_dir)

    validate_script = job_dir / "validate.py"
    train_script = job_dir / "train.py"

    if not validate_script.exists():
        print(f"❌ validate.py not found in {job_dir}")
        sys.exit(1)
    if not train_script.exists():
        print(f"❌ train.py not found in {job_dir}")
        sys.exit(1)

    # Phase A — Pre-flight
    print(f"\n[pre-flight] Running validate.py in {job_dir}...")
    rc_a = stream_subprocess([sys.executable, "validate.py"], job_dir, "[pre-flight]")
    if rc_a != 0:
        print(f"❌ [pre-flight] FAILED — halting before smoke test.")
        sys.exit(rc_a)
    print("✅ [pre-flight] Passed.")

    # Phase B — Smoke test
    print(f"\n[smoke test] Running train.py --smoke in {job_dir}...")
    rc_b = stream_subprocess([sys.executable, "train.py", "--smoke"], job_dir, "[smoke test]")
    if rc_b != 0:
        print("❌ [smoke test] FAILED.")
        sys.exit(rc_b)
    print(f"✅ [smoke test] Passed. Job '{job_dir.name}' completed successfully.")


def main():
    parser = argparse.ArgumentParser(
        description="ML training job orchestrator — scaffold and run jobs."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # new subcommand
    new_parser = subparsers.add_parser("new", help="Scaffold a new training job from a template")
    new_parser.add_argument(
        "type",
        nargs="?",
        choices=VALID_TYPES,
        default=None,
        help="Template type (required in positional mode)",
    )
    new_parser.add_argument(
        "job_name",
        nargs="?",
        default=None,
        help="Name for the new job directory (required in positional mode)",
    )
    new_parser.add_argument(
        "--interactive", "-i",
        action="store_true",
        help="Launch guided wizard to configure the job interactively",
    )
    new_parser.add_argument(
        "--full",
        action="store_true",
        help="Expand wizard to prompt for every configurable field (requires --interactive)",
    )
    new_parser.add_argument(
        "--model",
        default=None,
        metavar="VALUE",
        help="Override model name/type in config.yaml (e.g. bert-base-uncased, random_forest)",
    )
    new_parser.add_argument(
        "--epochs",
        default=None,
        metavar="N",
        help="Override training epochs / iterations in config.yaml",
    )
    new_parser.add_argument(
        "--batch-size",
        dest="batch_size",
        default=None,
        metavar="N",
        help="Override batch size in config.yaml",
    )

    # run subcommand
    run_parser = subparsers.add_parser("run", help="Run validate -> train pipeline on a job directory")
    run_parser.add_argument("job_dir", help="Path to the job directory")

    args = parser.parse_args()

    if args.command == "new":
        cmd_new(args)
    elif args.command == "run":
        cmd_run(args)


if __name__ == "__main__":
    main()

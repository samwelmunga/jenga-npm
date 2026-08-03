# Summary: E01_S06_T07 — Two-Phase CLI Orchestration in /train Skill

## What Was Created

### `skills/train/SKILL.md`
AI-agent instruction definition for the `/train` skill with two subcommands:
- `new <type> <job-name>`: scaffolds a job from a template
- `run <job-dir>`: executes the two-phase validate → train pipeline

### `skills/train/train_cli.py`
Concrete Python CLI script implementing the orchestration:
- Uses `argparse` with `new` and `run` subcommands
- `run` Phase A: invokes `validate.py` via `subprocess.Popen`, streams output line-by-line, halts on non-zero exit
- `run` Phase B: invokes `train.py --smoke` the same way, only reached if Phase A passes
- Clear `[pre-flight]` / `[smoke test]` labels on all output

## Test Run Results

All six commands succeeded:

| Command | Result |
|---|---|
| `new classifiers test-job-classifiers` | ✅ Scaffolded |
| `run jobs/test-job-classifiers` | ✅ Phase A + B passed |
| `new transformers test-job-transformers` | ✅ Scaffolded |
| `run jobs/test-job-transformers` | ✅ Phase A + B passed |
| `new nlp test-job-nlp` | ✅ Scaffolded |
| `run jobs/test-job-nlp` | ✅ Phase A + B passed |

Test job directories were cleaned up after testing.

## Notes
- `train.py` and `validate.py` have no references to each other — `/train` skill owns the gate
- Output streaming uses `subprocess.Popen` with `stdout=PIPE, stderr=STDOUT, bufsize=1` (line-buffered)
- `sys.executable` is used to ensure the same Python interpreter is used for subprocesses

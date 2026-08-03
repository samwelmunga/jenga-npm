# Summary: E01_S04_T01 — start.sh template and generation logic

## What was done
`_generate_start_sh(dest, job_type)` was added to `skills/train/train_cli.py` and called
from `cmd_new()` after scaffolding. The generated `start.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# activate venv if present
# install requirements.txt if present
python train.py
```

- Written to `<job_dir>/start.sh`
- Made executable via `chmod(0o755)`
- Job type is stamped in the header comment

## Acceptance criteria
- [x] `start.sh` is generated in the job directory during scaffolding
- [x] Script is executable (chmod +x)
- [x] Script structure: activate venv → install deps → run training

#!/usr/bin/env bash
# detect-tests.sh — test-coverage detection for the /uncharted investigative engine
#
# Usage: detect-tests.sh <target-path>
#        detect-tests.sh --help
#
# Reports, as JSON on stdout, whether test coverage exists for <target-path>, using
# conventional signals only (no test execution, no coverage instrumentation):
#
#   - test directories        test/ tests/ spec/ specs/ __tests__/ e2e/ testing/
#   - test filenames          *_test.*  *.test.*  test_*.*  *_spec.*  *.spec.*
#                             *Test.java  *Tests.kt  *.bats  conftest.py
#   - test-runner config      pytest.ini, tox.ini, jest.config.*, vitest.config.*,
#                             .mocharc*, phpunit.xml, playwright.config.*,
#                             cypress.config.*, .rspec, Cargo.toml, go.mod,
#                             package.json with a scripts.test entry, and this
#                             framework's own project/configs/test-config.json
#
# The distinguishing feature of this script is that it separates two very different
# situations that a naive "does the repo have tests?" grep conflates:
#
#   "covered"           — tests exist FOR THIS TARGET (test files live inside the
#                         target, or test files elsewhere reference it by name/path)
#   "repo_tests_only"   — the repo HAS tests, but none of them touch this target
#   "no_tests_in_repo"  — no test files were found anywhere in the repo
#
# This script is STRICTLY READ-ONLY. It creates no files, no temp files, and mutates
# no git state. Its only outputs are JSON on stdout and diagnostics on stderr.
#
# ---------------------------------------------------------------------------
# Output contract (stdout, JSON) — consumed by skills/j-uncharted/scripts/run-engine.sh
# ---------------------------------------------------------------------------
# {
#   "script": "detect-tests.sh",
#   "version": 1,
#   "target":          "<repo-relative path to the target>",
#   "target_absolute": "<absolute path to the target>",
#   "target_type":     "file" | "directory",
#   "repo_root":       "<absolute path to the repository root>",
#
#   "coverage_status":  "covered" | "repo_tests_only" | "no_tests_in_repo",
#   "coverage_summary": "<one-sentence human-readable verdict>",
#   "repo_has_tests":   <bool>,
#
#   "target_test_files":      [ "<repo-relative test file located inside the target>" ],
#   "referencing_test_files": [
#     {
#       "path":    "<repo-relative test file outside the target>",
#       "matched": [ "<reference name(s) that test file mentions>" ]
#     }
#   ],
#   "test_directories":   [ "<repo-relative directory>" ],
#   "test_runner_configs": [
#     {
#       "name":   "package.json",
#       "path":   "<repo-relative path>",
#       "runner": "<inferred runner, e.g. npm test / pytest / jest>",
#       "detail": "<extra context, or null>"
#     }
#   ],
#
#   "reference_names":         [ "<name/path used to match test files against the target>" ],
#   "repo_test_file_count":    <int>,
#   "repo_test_files_read":    <int>,   // capped; see notices when the cap is hit
#   "target_files_considered": <int>,
#   "files_walked":            <int>,
#   "walk_truncated":          <bool>,
#   "notices":                 [ "<non-fatal diagnostic>", ... ]
# }
#
# ---------------------------------------------------------------------------
# Behaviour notes
# ---------------------------------------------------------------------------
#   - Reference-name matching drops generic/short tokens (index, main, utils, run,
#     config, __init__, anything under 4 characters) to keep "covered" meaningful
#     rather than generic. Every referencing entry reports WHICH names it matched so
#     the calling agent can judge the strength of the signal itself.
#   - Unrecognised language / no test conventions present: NOT an error. The script
#     exits 0 with "coverage_status": "no_tests_in_repo" and an explanatory notice.
#   - Target outside a git repository: NOT an error. repo_root falls back to the
#     target's own directory and a notice is emitted.
#   - .claude/worktrees is never descended into: it holds full copies of the repo and
#     would multiply every count.
#
# Exit codes:
#   0 — success (including every graceful-degradation path above)
#   1 — usage error (wrong number of arguments)
#   2 — target path does not exist

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <target-path>

Prints a JSON report describing whether test coverage exists for a file or
directory, distinguishing "tests exist for this target" from "the repo has
tests, but none reference this target".

Arguments:
  <target-path>   File or directory to analyse.

Options:
  -h, --help      Show this help and exit.

Examples:
  $(basename "$0") skills/reconcile/
  $(basename "$0") scripts/board_resolver.sh
EOF
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if [[ $# -ne 1 ]]; then
  echo "Error: expected exactly 1 argument, got $#" >&2
  usage >&2
  exit 1
fi

TARGET="$1"

if [[ ! -e "$TARGET" ]]; then
  echo "Error: target path does not exist: $TARGET" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve absolute target path and repository root
# ---------------------------------------------------------------------------

if [[ -d "$TARGET" ]]; then
  TARGET_ABS=$(cd "$TARGET" && pwd)
  TARGET_DIR="$TARGET_ABS"
else
  TARGET_DIR=$(cd "$(dirname "$TARGET")" && pwd)
  TARGET_ABS="$TARGET_DIR/$(basename "$TARGET")"
fi

REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Scan and emit
# ---------------------------------------------------------------------------

python3 - "$TARGET_ABS" "$REPO_ROOT" <<'PY'
import json
import os
import re
import sys

TARGET = sys.argv[1]
REPO_ROOT = sys.argv[2]

notices = []

if not REPO_ROOT:
    REPO_ROOT = TARGET if os.path.isdir(TARGET) else os.path.dirname(TARGET)
    notices.append(
        "Target is not inside a git repository; repo root fell back to '%s'. "
        "The repo-wide test sweep is limited to that directory." % REPO_ROOT
    )

MAX_WALK_FILES = 20000
MAX_TEST_FILES_READ = 500
MAX_REFERENCE_NAMES = 300
MAX_BYTES = 512 * 1024
MAX_MATCHES_PER_FILE = 8

SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build",
    ".next", "coverage", "vendor", "target", ".mypy_cache", ".pytest_cache",
    ".tox", ".gradle", ".idea", ".svn", ".hg", "bower_components", ".terraform",
}

TEST_DIR_NAMES = {"test", "tests", "spec", "specs", "__tests__", "e2e", "testing"}

TEST_FILE_PATTERNS = [
    re.compile(r".+_test\.[A-Za-z0-9]+$"),
    re.compile(r".+\.test\.[A-Za-z0-9]+$"),
    re.compile(r"^test_.+\.[A-Za-z0-9]+$"),
    re.compile(r".+_spec\.[A-Za-z0-9]+$"),
    re.compile(r".+\.spec\.[A-Za-z0-9]+$"),
    re.compile(r".+Tests?\.(?:java|kt|kts|cs|scala)$"),
    re.compile(r".+\.bats$"),
    re.compile(r"^conftest\.py$"),
]

# A file inside a test directory only counts as a test file when it looks like source.
SOURCE_EXTS = {
    ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".py", ".go", ".rs", ".rb",
    ".sh", ".bash", ".bats", ".c", ".h", ".cc", ".cpp", ".java", ".kt", ".kts",
    ".php", ".scala", ".cs", ".swift", ".exs",
}

RUNNER_EXACT = {
    "pytest.ini": "pytest",
    "conftest.py": "pytest",
    "tox.ini": "tox",
    "noxfile.py": "nox",
    "phpunit.xml": "phpunit",
    "phpunit.xml.dist": "phpunit",
    ".rspec": "rspec",
    "Rakefile": "rake",
    "Cargo.toml": "cargo test",
    "go.mod": "go test",
    "karma.conf.js": "karma",
    "vitest.workspace.ts": "vitest",
}

RUNNER_PATTERNS = [
    (re.compile(r"^jest\.config\.[A-Za-z]+$"), "jest"),
    (re.compile(r"^vitest\.config\.[A-Za-z]+$"), "vitest"),
    (re.compile(r"^\.mocharc(\..+)?$"), "mocha"),
    (re.compile(r"^playwright\.config\.[A-Za-z]+$"), "playwright"),
    (re.compile(r"^cypress\.config\.[A-Za-z]+$"), "cypress"),
    (re.compile(r"^karma\.conf\.[A-Za-z]+$"), "karma"),
]

MAX_RUNNER_CONFIGS = 30

# Tokens too generic to prove a test references THIS target.
GENERIC_NAMES = {
    "index", "main", "util", "utils", "run", "test", "tests", "spec", "setup",
    "config", "configs", "types", "const", "consts", "constants", "helper",
    "helpers", "common", "core", "app", "cli", "api", "data", "init", "__init__",
    "package", "readme", "license", "makefile", "base", "lib", "src", "docs",
    "script", "scripts", "assets", "template", "templates", "schema", "server",
    "client", "model", "models", "view", "views", "style", "styles", "build",
}
MIN_NAME_LENGTH = 4


def rel(path):
    """Repo-relative POSIX path, falling back to the absolute path when outside the repo."""
    try:
        r = os.path.relpath(path, REPO_ROOT)
    except ValueError:
        return path
    if r.startswith(".."):
        return path
    return r.replace(os.sep, "/")


def prune(dirpath, dirnames):
    """In-place SKIP_DIRS pruning; .claude/worktrees holds full repo copies."""
    keep = []
    for d in sorted(dirnames):
        if d in SKIP_DIRS:
            continue
        if d == "worktrees" and os.path.basename(dirpath) == ".claude":
            continue
        keep.append(d)
    dirnames[:] = keep


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def looks_like_test_file(filename, in_test_dir):
    for pattern in TEST_FILE_PATTERNS:
        if pattern.match(filename):
            return True
    if in_test_dir and os.path.splitext(filename)[1].lower() in SOURCE_EXTS:
        return True
    return False


def classify_runner(filename):
    if filename in RUNNER_EXACT:
        return RUNNER_EXACT[filename]
    for pattern, runner in RUNNER_PATTERNS:
        if pattern.match(filename):
            return runner
    return None


# ---------------------------------------------------------------------------
# Step 1 — collect the target's own files and derive reference names
# ---------------------------------------------------------------------------

is_dir = os.path.isdir(TARGET)
target_rel = rel(TARGET)

target_files = []
if is_dir:
    for dirpath, dirnames, filenames in os.walk(TARGET):
        prune(dirpath, dirnames)
        for fn in sorted(filenames):
            target_files.append(os.path.join(dirpath, fn))
            if len(target_files) >= MAX_WALK_FILES:
                break
        if len(target_files) >= MAX_WALK_FILES:
            notices.append("Target file enumeration stopped at the %d-file cap." % MAX_WALK_FILES)
            break
else:
    target_files.append(TARGET)



def keep_name(name):
    """Path-like names are always specific enough; bare names must clear the generic filter."""
    if "/" in name:
        return True
    return len(name) >= MIN_NAME_LENGTH and name.lower() not in GENERIC_NAMES


reference_names = set()
if keep_name(target_rel):
    reference_names.add(target_rel)
if is_dir:
    base = os.path.basename(TARGET.rstrip(os.sep))
    if keep_name(base):
        reference_names.add(base)

for file_path in target_files:
    file_rel = rel(file_path)
    reference_names.add(file_rel)
    basename = os.path.basename(file_path)
    stem = os.path.splitext(basename)[0]
    for candidate in (basename, stem):
        if keep_name(candidate):
            reference_names.add(candidate)

reference_names = sorted(reference_names)
if len(reference_names) > MAX_REFERENCE_NAMES:
    notices.append(
        "Target yielded %d reference names; truncated to the first %d for matching."
        % (len(reference_names), MAX_REFERENCE_NAMES)
    )
    reference_names = reference_names[:MAX_REFERENCE_NAMES]

path_names = [n for n in reference_names if "/" in n]
word_names = [n for n in reference_names if "/" not in n]
word_re = None
if word_names:
    alternation = "|".join(re.escape(n) for n in sorted(word_names, key=len, reverse=True))
    word_re = re.compile(r"(?<![\w-])(" + alternation + r")(?![\w-])")

# ---------------------------------------------------------------------------
# Step 2 — sweep the repository for test signals
# ---------------------------------------------------------------------------

target_prefix = TARGET.rstrip(os.sep) + os.sep

hidden_pruned = []


def on_target_path(path):
    """True when path is the target, contains it, or lives inside it."""
    return path == TARGET or TARGET.startswith(path + os.sep) or path.startswith(target_prefix)


def prune_repo(dirpath, dirnames):
    """Repo-sweep pruning: SKIP_DIRS plus hidden directories.

    Hidden directories are skipped because they overwhelmingly hold tooling and
    generated mirrors rather than a project's real tests -- in this framework,
    .agents/ and .claude/ are build outputs that duplicate every skill under
    skills/, which would triple every count here. A hidden directory is still
    descended into when the target itself lives on that path, and anything pruned
    is reported in "notices" rather than dropped silently.
    """
    prune(dirpath, dirnames)
    keep = []
    for d in dirnames:
        full = os.path.join(dirpath, d)
        if d.startswith(".") and not on_target_path(full):
            hidden_pruned.append(rel(full))
            continue
        keep.append(d)
    dirnames[:] = keep


test_directories = []
repo_test_files = []
runner_configs = []
files_walked = 0
walk_truncated = False

for dirpath, dirnames, filenames in os.walk(REPO_ROOT):
    prune_repo(dirpath, dirnames)
    for d in dirnames:
        if d.lower() in TEST_DIR_NAMES:
            test_directories.append(rel(os.path.join(dirpath, d)))
    in_test_dir = any(part.lower() in TEST_DIR_NAMES for part in rel(dirpath).split("/"))
    for fn in sorted(filenames):
        files_walked += 1
        if files_walked > MAX_WALK_FILES:
            walk_truncated = True
            break
        full = os.path.join(dirpath, fn)
        if looks_like_test_file(fn, in_test_dir):
            repo_test_files.append(full)
        if len(runner_configs) < MAX_RUNNER_CONFIGS:
            runner = classify_runner(fn)
            detail = None
            if fn == "package.json":
                text = read_text(full)
                try:
                    scripts = (json.loads(text) or {}).get("scripts") or {}
                except Exception:
                    scripts = {}
                if isinstance(scripts, dict) and scripts.get("test"):
                    runner = "npm test"
                    detail = str(scripts["test"])[:200]
            elif fn == "test-config.json" and rel(dirpath).endswith("project/configs"):
                runner = "jenga test-config"
                text = read_text(full)
                try:
                    tools = (json.loads(text) or {}).get("tools") or []
                    named = [t.get("tool_name") for t in tools if isinstance(t, dict)]
                    detail = "declares: " + ", ".join(n for n in named if n and n != "-")
                except Exception:
                    detail = None
            if runner:
                runner_configs.append({
                    "name": fn,
                    "path": rel(full),
                    "runner": runner,
                    "detail": detail,
                })
    if walk_truncated:
        break

if walk_truncated:
    notices.append(
        "Repository sweep stopped at the %d-file cap; test discovery is partial rather than "
        "silently complete." % MAX_WALK_FILES
    )

if hidden_pruned:
    shown = sorted(set(hidden_pruned))
    notices.append(
        "Skipped %d hidden director%s during the repository sweep (generated mirrors and tooling "
        "directories duplicate real source trees): %s%s"
        % (
            len(shown),
            "y" if len(shown) == 1 else "ies",
            ", ".join(shown[:10]),
            "" if len(shown) <= 10 else ", ...",
        )
    )

test_directories = sorted(set(test_directories))
repo_test_files = sorted(set(repo_test_files))

# ---------------------------------------------------------------------------
# Step 3 — split target-local tests from tests elsewhere that reference the target
# ---------------------------------------------------------------------------

target_test_files = []
other_test_files = []
for path in repo_test_files:
    if path == TARGET or path.startswith(target_prefix):
        target_test_files.append(path)
    else:
        other_test_files.append(path)

referencing = []
read_count = 0
for path in other_test_files:
    if read_count >= MAX_TEST_FILES_READ:
        notices.append(
            "Stopped reading test files at the %d-file cap; %d test files were left unexamined "
            "for references to the target." % (MAX_TEST_FILES_READ, len(other_test_files) - read_count)
        )
        break
    text = read_text(path)
    if text is None:
        continue
    read_count += 1
    matched = [n for n in path_names if n in text]
    if word_re:
        matched.extend(word_re.findall(text))
    if matched:
        ordered = sorted(set(matched), key=lambda n: (-len(n), n))[:MAX_MATCHES_PER_FILE]
        referencing.append({"path": rel(path), "matched": ordered})

referencing.sort(key=lambda e: e["path"])

# ---------------------------------------------------------------------------
# Step 4 — derive the coverage verdict
# ---------------------------------------------------------------------------

repo_has_tests = bool(repo_test_files)

if target_test_files or referencing:
    coverage_status = "covered"
    parts = []
    if target_test_files:
        parts.append("%d test file(s) inside the target" % len(target_test_files))
    if referencing:
        parts.append("%d test file(s) elsewhere referencing it" % len(referencing))
    coverage_summary = "Tests were found for this target: " + " and ".join(parts) + "."
elif repo_has_tests:
    coverage_status = "repo_tests_only"
    coverage_summary = (
        "The repository has %d test file(s), but none of them are inside '%s' or reference it. "
        "This target appears untested." % (len(repo_test_files), target_rel)
    )
else:
    coverage_status = "no_tests_in_repo"
    coverage_summary = (
        "No test files were found anywhere in the repository, so no coverage exists for '%s'."
        % target_rel
    )
    notices.append(
        "No files matched any test-file or test-directory convention in this repository. "
        "This is reported as an explicit empty result, not an error — the project may use an "
        "unrecognised testing convention, or may have no tests at all."
    )

result = {
    "script": "detect-tests.sh",
    "version": 1,
    "target": target_rel,
    "target_absolute": TARGET,
    "target_type": "directory" if is_dir else "file",
    "repo_root": REPO_ROOT,
    "coverage_status": coverage_status,
    "coverage_summary": coverage_summary,
    "repo_has_tests": repo_has_tests,
    "target_test_files": [rel(p) for p in target_test_files],
    "referencing_test_files": referencing,
    "test_directories": test_directories,
    "test_runner_configs": runner_configs,
    "reference_names": reference_names,
    "repo_test_file_count": len(repo_test_files),
    "repo_test_files_read": read_count,
    "target_files_considered": len(target_files),
    "files_walked": files_walked,
    "walk_truncated": walk_truncated,
    "notices": notices,
}

print(json.dumps(result, indent=2))
PY

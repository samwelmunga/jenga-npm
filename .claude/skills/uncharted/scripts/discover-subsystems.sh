#!/usr/bin/env bash
# discover-subsystems.sh — bounded, coarse-grained subsystem discovery for /uncharted onboard
#
# Usage: discover-subsystems.sh [options] <root>
#        discover-subsystems.sh --help
#
# Given the root of an existing codebase, emits a ranked JSON list of candidate SUBSYSTEMS on
# stdout: the major modules/packages a human would name when asked "what are the main parts of
# this project?". It is deliberately COARSE. `onboard` mode backfills a board for a codebase
# that was never built through Jenga, and a per-file investigation of such a codebase is both
# useless as a board and prohibitively expensive. Boundedness is the point of this script, not
# a limitation of it:
#
#   - discovery depth is capped (default 2 levels below the root, --max-depth)
#   - build outputs, vendored dependencies and .gitignore'd paths are never candidates
#   - Jenga's own scaffolding is never a candidate — it is the framework, not the application
#   - the directory tree is partitioned, never double-counted (see CANDIDATES VS CONTAINERS)
#
# This script is STRICTLY READ-ONLY. It creates no files, no temp files, and mutates no git
# state. It never writes into the codebase being analysed — `onboard` mode must never modify,
# move, or restructure a consumer's application code, and this script is the analysis half of
# that guarantee. Its only outputs are JSON on stdout and diagnostics on stderr.
#
# Enumeration is DELEGATED, not reimplemented: every file count, line count and directory
# listing comes from `enumerate-target.sh` in this same directory. This script contributes the
# clustering, bounding and scoring on top of it.
#
# Determinism: the output is a pure function of the tree and the flags. No timestamps, no
# hostnames, no unsorted collections — two runs against an unchanged tree produce byte-identical
# output and can be diffed directly.
#
# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
#   --max-depth N        How many levels below <root> a candidate may sit. Default 2.
#                        Must be >= 1; there is deliberately no "unlimited" value, because an
#                        unbounded walk is exactly what this script exists to prevent.
#   --min-files N        Noise floor: a directory holding fewer than N files (recursively) is
#                        not a candidate. Default 1 (i.e. off).
#   --max-candidates N   Runtime safety bound on how many directories receive a second,
#                        per-candidate enumeration pass. Default 200. When the bound is hit the
#                        largest candidates are kept and the remainder are reported under
#                        "excluded" with a notice.
#                        THIS IS NOT THE `onboard` EPIC CAP. It is a cost guard on the analysis
#                        itself. The epic cap — and the surfacing of anything it drops — is
#                        applied by a separate layer on top of this script's output.
#   --include-framework  Do not exclude Jenga scaffolding. Needed to point the script at the
#                        JengaAgent repo itself, where the scaffolding IS the application.
#   --include-training-scaffolding
#                        Do not exclude .training/ job-template scaffolding. Needed to point the
#                        script at JengaAgent's own /train subsystem, or at a project that
#                        genuinely wants job templates catalogued as a candidate.
#   --with-dependencies  Additionally compute the "cohesion" signal by calling
#                        detect-dependencies.sh once per candidate. Off by default: it is an
#                        extra full-text scan per candidate and the default pass must stay
#                        coarse. Degrades to a notice if that script is unavailable.
#   -h, --help           Show help and exit.
#   --                   End of options; the next argument is <root>.
#
# ---------------------------------------------------------------------------
# Exclusions
# ---------------------------------------------------------------------------
# Four independent layers, and every exclusion is REPORTED in the "excluded" array with its
# reason — nothing is silently dropped:
#
#   1. .gitignore'd paths. Free, and by construction: enumerate-target.sh lists via
#      `git ls-files --cached --others --exclude-standard`, so ignored content never reaches
#      this script. When it reports "gitignore_respected": false (the root is not in a git work
#      tree, or its content is itself ignored) a notice says so, because layer 2 is then the
#      only guard left.
#   2. Build/vendor/VCS directory NAMES at any depth: node_modules, vendor, dist, build, .git,
#      target, out, coverage, .venv, venv, __pycache__, .next, bower_components, .terraform,
#      .gradle, .tox, .mypy_cache, .pytest_cache, .idea, .svn, .hg, .cache, .claude/worktrees.
#      This layer applies BOTH when selecting candidates AND inside a candidate that has already
#      been selected. The second half matters for committed (non-gitignored) vendor content —
#      common in Go and PHP projects, which is exactly the kind of codebase `onboard` targets.
#      Without it a candidate's own totals and score would silently absorb its vendored tree.
#      enumerate-target.sh has no name-exclusion concept — .gitignore is its only filter — so
#      each nested match is measured by enumerate-target.sh in its own right and SUBTRACTED from
#      the candidate, keeping enumeration delegated rather than recounted here. Gitignored
#      directories never reach this step (layer 1 already removed them from the listing), so the
#      subtraction cannot double-count. Every discount is reported twice: on the candidate as
#      "nested_excluded", and in the top-level "excluded" array.
#   3. Jenga scaffolding: project/, skills/, agents/, hooks/, templates/, .claude/, .agents/.
#      Matched as ROOT-RELATIVE PATHS, not as bare names at any depth — a consumer's own
#      src/agents/ or app/templates/ is a real subsystem and must not be swallowed by a rule
#      about Jenga's top-level layout. Disable with --include-framework.
#   4. Training-job scaffolding: .training/. Matched as a ROOT-RELATIVE PATH at depth 1, same
#      discipline as layer 3 and for the same reason — a consumer's own src/.training/ (unlikely,
#      but the rule should not assume) would need the same protection a bare-name match at any
#      depth would remove. This is deliberately its own layer rather than folded into
#      FRAMEWORK_PATHS: .training/ is job-template scaffolding for the /train skill, not Jenga's
#      own runtime scaffolding, and the two can be disabled independently. Content under it
#      (e.g. .training/template/{transformers,nlp,classifiers}/train.py) describes how to run a
#      training job, not application code an `onboard` backfill should reason about. Disable with
#      --include-training-scaffolding.
#
# ---------------------------------------------------------------------------
# Candidates vs containers
# ---------------------------------------------------------------------------
# Ranking packages/ alongside packages/api and packages/web would count the same files two or
# three times and bury real subsystems under their own parents. So the tree is PARTITIONED:
# walking down from the root, each directory becomes exactly one of
#
#   candidate — a subsystem. It is scored and ranked, and its subtree is NOT descended further.
#   container — a folder OF subsystems (the classic packages/ or apps/ case). It is expanded
#               into its children, is not itself ranked, and is reported in "containers" with
#               the reason it was expanded and what it expanded into.
#
# A directory is expanded into its children only when ALL of these hold:
#   - it sits above --max-depth (a directory at the depth bound is always a candidate),
#   - it has at least 2 child directories that would themselves be viable candidates,
#   - its own direct files are incidental (<= 3 of them, or <= 20% of its recursive file count),
#   - it does NOT carry its own manifest.
# The manifest rule is what makes monorepos work: a directory with its own package.json /
# go.mod / pyproject.toml is a unit by definition and is never split apart, whatever its shape.
#
# Files sitting loose at the root belong to no subsystem, so they are reported under
# "root_files" rather than being invented as a candidate.
#
# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
# Each candidate carries every signal that scored it — name, normalised 0..1 value, weight,
# contribution and a human-readable detail — so a ranking can be audited rather than trusted.
#
#   size            30   log-scaled line count relative to the largest candidate. Log-scaled so
#                        one enormous module does not flatten everything else to zero.
#   manifest        20   own dependency manifest — the strongest "this is a unit" signal there is
#   own_tests       15   own test directory or test-named files
#   source_density  15   share of files with recognised source extensions, which separates a
#                        code module from an assets/fixtures/docs folder of the same size
#   structure       10   has internal sub-structure rather than being a flat bag of files
#   docs            10   own README / docs/ — somebody thought this was worth describing
#   cohesion        20   --with-dependencies only: internal vs external dependency ratio
#
# score = 100 * sum(value * weight) / sum(weight), renormalised over whichever weights were in
# play, so enabling --with-dependencies changes the ranking but never the 0-100 scale. Ranks are
# assigned by score descending, then path ascending.
#
# ---------------------------------------------------------------------------
# Output contract (stdout, JSON)
# ---------------------------------------------------------------------------
# Additive by design — consumers should ignore keys they do not need, and new keys may be added
# without notice.
#
# {
#   "script": "discover-subsystems.sh",
#   "version": 1,
#   "root":          "<repo-relative path to the analysed root>",
#   "root_absolute": "<absolute path>",
#   "repo_root":     "<absolute path to the git root, or null when not in a work tree>",
#   "max_depth":           <int>,     // the depth bound in effect
#   "min_files":           <int>,
#   "max_candidates":      <int>,     // runtime bound, NOT the onboard epic cap
#   "framework_excluded":  <bool>,
#   "gitignore_respected": <bool>,    // false => layer-1 exclusions did not apply
#   "with_dependencies":   <bool>,
#   "totals": { "files": <int>, "lines": <int>, "bytes": <int> },   // whole analysed root
#   "candidate_count": <int>,
#   "candidates": [
#     {
#       "rank":           <int>,      // 1 = strongest
#       "path":           "<path relative to root>",
#       "absolute_path":  "<absolute path>",
#       "depth":          <int>,      // levels below root
#       "parent":         "<path relative to root, or null at depth 1>",
#       "score":          <float 0-100>,
#       "files":          <int>,      // recursive, from enumerate-target.sh, net of
#       "lines":          <int>,      // anything listed in "nested_excluded" below
#       "bytes":          <int>,
#       "direct_files":   <int>,      // files sitting directly in it, not in subdirectories
#       "subdirectories": <int>,
#       "manifests":      [ "<name>", ... ],
#       "test_paths":     [ "<path relative to the candidate>", ... ],   // capped at 5
#       "doc_paths":      [ "<path relative to the candidate>", ... ],   // capped at 5
#       "top_extensions": [ { "extension", "files", "lines" }, ... ],    // capped at 5
#       "largest_files":  [ { "path", "lines" }, ... ],                  // capped at 5
#       "nested_excluded": [   // vendored/build dirs found inside it and discounted from its
#                              // totals above; empty in the common (gitignored) case
#         { "path", "reason", "files", "lines" }
#       ],
#       "signals": [
#         { "name", "value": <0..1>, "weight": <int>, "contribution": <float>, "detail": "<why>" }
#       ]
#     }
#   ],
#   "containers": [
#     { "path", "depth", "reason", "expanded_into": [ "<child path>", ... ] }
#   ],
#   "excluded": [
#     { "path", "reason" }
#   ],
#   "root_files": { "count": <int>, "paths": [ "<name>", ... ] },   // paths capped at 25
#   "notices": [ "<non-fatal diagnostic>", ... ]
# }
#
# ---------------------------------------------------------------------------
# Behaviour notes
# ---------------------------------------------------------------------------
#   - No candidates found: NOT an error. Exits 0 with an empty "candidates" array and a notice
#     explaining why (empty root, everything excluded, or everything below --min-files).
#   - Root outside a git repository: NOT an error. "repo_root" is null, "gitignore_respected"
#     is false, and a notice says only name-based exclusions applied.
#   - Cost: the tree is read roughly twice — once for the repo-wide sweep that finds the
#     candidates, then once per candidate for its statistics. That is acceptable for a one-shot
#     onboarding pass and is bounded by --max-candidates.
#   - Nested vendored/build content is hunted 4 levels into a candidate, not indefinitely. A
#     node_modules/ buried deeper than that is still counted in its candidate's totals. The bound
#     is stated rather than silently assumed: real vendor directories sit at a module's root, and
#     an unbounded per-candidate walk would contradict the whole point of this script.
#   - The candidate/container split is a heuristic and will sometimes disagree with a human's
#     mental model of a codebase. That is why every decision is emitted with its reason: a wrong
#     call is inspectable and overridable, not hidden.
#
# Exit codes:
#   0 — success (including every graceful-degradation path above)
#   1 — usage error (unknown flag, missing/extra root, bad numeric value)
#   2 — root missing, unreadable, or not a directory
#   3 — enumerate-target.sh is missing, not executable, or failed on the root
#
# Examples:
#   discover-subsystems.sh .
#   discover-subsystems.sh --max-depth 3 --min-files 5 /path/to/project
#   discover-subsystems.sh --include-framework --with-dependencies .
#   discover-subsystems.sh . | jq -r '.candidates[] | "\(.rank)\t\(.score)\t\(.path)"'
#
# Requires: bash, git, python3. jq is NOT required — JSON is emitted by python3.

set -euo pipefail

MAX_DEPTH=2
MIN_FILES=1
MAX_CANDIDATES=200
INCLUDE_FRAMEWORK=0
INCLUDE_TRAINING=0
WITH_DEPENDENCIES=0
ROOT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <root>

Print a ranked JSON list of the major subsystems of an existing codebase. Coarse by design:
depth-bounded, build/vendor/ignored paths excluded, Jenga scaffolding excluded.
Read-only: nothing is written to disk, and the analysed codebase is never modified.

Arguments:
  <root>               Root directory of the codebase to analyse.

Options:
  --max-depth N        Levels below <root> a candidate may sit (default: 2, minimum: 1)
  --min-files N        Ignore directories holding fewer than N files (default: 1)
  --max-candidates N   Runtime bound on candidates enumerated (default: 200).
                       Not the onboard epic cap — that is applied by a separate layer.
  --include-framework  Do not exclude project/ skills/ agents/ hooks/ templates/ .claude/ .agents/
  --include-training-scaffolding
                       Do not exclude .training/ job-template scaffolding
  --with-dependencies  Also compute the cohesion signal via detect-dependencies.sh (slower)
  -h, --help           Show this help and exit

Exit codes: 0 success, 1 usage error, 2 root missing/unreadable/not a directory,
            3 enumerate-target.sh unavailable or failed.

Examples:
  $(basename "$0") .
  $(basename "$0") --max-depth 3 --min-files 5 /path/to/project
EOF
}

die_usage() {
  echo "Error: $1" >&2
  echo >&2
  usage >&2
  exit 1
}

require_int() {
  # require_int <flag> <value> <minimum>
  case "$2" in
    ''|*[!0-9]*) die_usage "$1 requires a non-negative integer, got \"$2\"" ;;
  esac
  if [ "$2" -lt "$3" ]; then
    die_usage "$1 must be >= $3, got \"$2\""
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-depth)
      [ "$#" -ge 2 ] || die_usage "--max-depth requires a value"
      require_int "--max-depth" "$2" 1
      MAX_DEPTH="$2"; shift 2 ;;
    --max-depth=*)
      require_int "--max-depth" "${1#*=}" 1
      MAX_DEPTH="${1#*=}"; shift ;;
    --min-files)
      [ "$#" -ge 2 ] || die_usage "--min-files requires a value"
      require_int "--min-files" "$2" 1
      MIN_FILES="$2"; shift 2 ;;
    --min-files=*)
      require_int "--min-files" "${1#*=}" 1
      MIN_FILES="${1#*=}"; shift ;;
    --max-candidates)
      [ "$#" -ge 2 ] || die_usage "--max-candidates requires a value"
      require_int "--max-candidates" "$2" 1
      MAX_CANDIDATES="$2"; shift 2 ;;
    --max-candidates=*)
      require_int "--max-candidates" "${1#*=}" 1
      MAX_CANDIDATES="${1#*=}"; shift ;;
    --include-framework)
      INCLUDE_FRAMEWORK=1; shift ;;
    --include-training-scaffolding)
      INCLUDE_TRAINING=1; shift ;;
    --with-dependencies)
      WITH_DEPENDENCIES=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      [ "$#" -eq 1 ] || die_usage "exactly one root is required"
      ROOT="$1"; shift ;;
    -*)
      die_usage "unknown option \"$1\"" ;;
    *)
      [ -z "$ROOT" ] || die_usage "exactly one root is required (got \"$ROOT\" and \"$1\")"
      ROOT="$1"; shift ;;
  esac
done

[ -n "$ROOT" ] || die_usage "a root directory is required"

# ---------------------------------------------------------------------------
# Root resolution
# ---------------------------------------------------------------------------

if [ ! -e "$ROOT" ]; then
  echo "Error: root does not exist: $ROOT" >&2
  exit 2
fi
if [ ! -d "$ROOT" ]; then
  echo "Error: root is not a directory: $ROOT" >&2
  exit 2
fi
if [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then
  echo "Error: root is not readable/traversable: $ROOT" >&2
  exit 2
fi

# `readlink -f` is GNU-only and absent from older macOS/BSD userland; cd + `pwd -P` is portable.
ROOT_ABS=$(cd -- "$ROOT" && pwd -P)
REPO_ROOT=$(git -C "$ROOT_ABS" rev-parse --show-toplevel 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Sibling scripts
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ENUMERATE="$SCRIPT_DIR/enumerate-target.sh"
DETECT_DEPS="$SCRIPT_DIR/detect-dependencies.sh"

if [ ! -x "$ENUMERATE" ]; then
  echo "Error: required helper is missing or not executable: $ENUMERATE" >&2
  echo "       discover-subsystems.sh delegates all enumeration to it rather than duplicating it." >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Discover and emit
# ---------------------------------------------------------------------------

python3 - \
  "$ROOT_ABS" "$REPO_ROOT" "$ENUMERATE" "$DETECT_DEPS" \
  "$MAX_DEPTH" "$MIN_FILES" "$MAX_CANDIDATES" "$INCLUDE_FRAMEWORK" "$INCLUDE_TRAINING" \
  "$WITH_DEPENDENCIES" <<'PY'
import json
import math
import os
import re
import subprocess
import sys

(ROOT_ABS, REPO_ROOT, ENUMERATE, DETECT_DEPS,
 MAX_DEPTH_S, MIN_FILES_S, MAX_CANDIDATES_S,
 INCLUDE_FRAMEWORK_S, INCLUDE_TRAINING_S, WITH_DEPENDENCIES_S) = sys.argv[1:11]

MAX_DEPTH = int(MAX_DEPTH_S)
MIN_FILES = int(MIN_FILES_S)
MAX_CANDIDATES = int(MAX_CANDIDATES_S)
INCLUDE_FRAMEWORK = INCLUDE_FRAMEWORK_S == "1"
INCLUDE_TRAINING = INCLUDE_TRAINING_S == "1"
WITH_DEPENDENCIES = WITH_DEPENDENCIES_S == "1"

notices = []

# ---------------------------------------------------------------------------
# Exclusion vocabulary
# ---------------------------------------------------------------------------

# Build outputs, vendored dependencies and VCS/tooling metadata. Excluded by NAME at any depth,
# because they mean the same thing wherever they appear. Baseline kept in step with
# detect-tests.sh / detect-dependencies.sh so the three scripts agree on what "not code" means.
SKIP_DIRS = {
    ".git", ".svn", ".hg",
    "node_modules", "bower_components", "vendor",
    "dist", "build", "out", "target",
    ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", ".tox",
    ".next", ".nuxt", ".output", ".parcel-cache", ".turbo", ".cache",
    "coverage", ".nyc_output",
    ".gradle", ".idea", ".vscode", ".terraform", ".serverless", ".dart_tool",
    "Pods", "DerivedData",
}

# Jenga's own scaffolding. Excluded by ROOT-RELATIVE PATH, never by bare name: a consumer's
# src/agents/ or app/templates/ is a real subsystem of their application and must survive.
FRAMEWORK_PATHS = {
    "project", "skills", "agents", "hooks", "templates", ".claude", ".agents",
}

# Training-job template scaffolding for the /train skill (e.g. .training/template/{transformers,
# nlp,classifiers}/train.py). Kept separate from FRAMEWORK_PATHS — same root-relative-path
# discipline, but a distinct concept with its own opt-out, since a caller may want Jenga
# scaffolding excluded while still wanting job templates as a candidate, or vice versa.
TRAINING_SCAFFOLD_PATHS = {
    ".training",
}

# Own-manifest = "this directory is a unit". Strong enough to veto splitting it apart.
MANIFEST_NAMES = {
    "package.json", "deno.json", "deno.jsonc",
    "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile",
    "go.mod", "Cargo.toml", "Gemfile", "composer.json",
    "pom.xml", "build.gradle", "build.gradle.kts", "build.sbt",
    "mix.exs", "pubspec.yaml", "Package.swift", "CMakeLists.txt",
    "Chart.yaml", "terraform.tf",
}
MANIFEST_SUFFIXES = (".csproj", ".fsproj", ".gemspec", ".podspec", ".cabal")

TEST_DIR_NAMES = {"test", "tests", "spec", "specs", "__tests__", "e2e", "testing", "it"}
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

DOC_DIR_NAMES = {"docs", "doc"}
DOC_FILE_PATTERN = re.compile(r"^(README|readme|Readme)(\..+)?$")

SOURCE_EXTS = {
    ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".vue", ".svelte",
    ".py", ".pyi", ".go", ".rs", ".rb", ".php", ".java", ".kt", ".kts",
    ".scala", ".swift", ".m", ".mm", ".cs", ".fs", ".c", ".h", ".cc",
    ".cpp", ".hpp", ".hh", ".ex", ".exs", ".erl", ".dart", ".lua", ".pl",
    ".r", ".jl", ".sh", ".bash", ".zsh", ".sql", ".proto", ".tf", ".hcl",
}

# Reporting caps — these bound the SIZE OF THE OUTPUT, not the analysis.
CAP_TEST_PATHS = 5
CAP_DOC_PATHS = 5
CAP_EXTENSIONS = 5
CAP_LARGEST = 5

# Pass-2 depth windows, deliberately separate:
#   CANDIDATE_TREE_DEPTH  how deep a candidate's own tree is walked when hunting for nested
#                         vendored/build content to discount. Deeper than the signal window
#                         because vendor directories are not always at a module's root
#                         (packages/api/src/deep/node_modules is unusual but real). Costs only
#                         JSON size: enumerate-target.sh counts the whole subtree either way.
#   CANDIDATE_SIGNAL_DEPTH how deep manifests, tests and docs are looked for. Stays shallow on
#                         purpose -- a manifest or test directory that far from a module's root
#                         is not evidence about the module itself.
CANDIDATE_TREE_DEPTH = 4
CANDIDATE_SIGNAL_DEPTH = 2
CAP_ROOT_FILES = 25

WEIGHTS = {
    "size": 30,
    "manifest": 20,
    "own_tests": 15,
    "source_density": 15,
    "structure": 10,
    "docs": 10,
    "cohesion": 20,   # only in play under --with-dependencies
}

# ---------------------------------------------------------------------------
# enumerate-target.sh delegation
# ---------------------------------------------------------------------------


def enumerate_target(path, depth, top):
    """Run enumerate-target.sh and return its parsed JSON, or (None, reason)."""
    cmd = [ENUMERATE, "--max-depth", str(depth), "--top", str(top), "--", path]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        return None, "could not execute enumerate-target.sh: %s" % exc
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, "enumerate-target.sh exited %d%s" % (
            proc.returncode, (": " + detail[0]) if detail else "")
    try:
        return json.loads(proc.stdout.decode("utf-8", "replace")), None
    except ValueError as exc:
        return None, "enumerate-target.sh emitted unparseable JSON: %s" % exc


def parent_of(rel):
    return rel.rsplit("/", 1)[0] if "/" in rel else ""


def basename_of(rel):
    return rel.rsplit("/", 1)[-1]


def is_manifest(name):
    return name in MANIFEST_NAMES or name.endswith(MANIFEST_SUFFIXES)


def looks_like_test_file(name):
    return any(p.match(name) for p in TEST_FILE_PATTERNS)


# ---------------------------------------------------------------------------
# Pass 1 — a single repo-wide enumeration builds the directory graph
# ---------------------------------------------------------------------------
# MAX_DEPTH + 1 is required, not generous: deciding whether a directory AT the depth bound is a
# candidate needs to see the files sitting directly inside it, which live one level deeper.

survey, err = enumerate_target(ROOT_ABS, MAX_DEPTH + 1, 1)
if survey is None:
    sys.stderr.write("Error: %s\n" % err)
    sys.stderr.write("       root: %s\n" % ROOT_ABS)
    sys.exit(3)

gitignore_respected = bool(survey.get("gitignore_respected"))
if not gitignore_respected:
    if survey.get("ignored_target"):
        notices.append(
            "The analysed root is itself .gitignore'd, so enumerate-target.sh fell back to a "
            "filesystem walk. .gitignore exclusions did not apply; only the build/vendor name "
            "list did."
        )
    else:
        notices.append(
            "The analysed root is not inside a git work tree, so .gitignore could not be "
            "honoured. Only the build/vendor name list and the framework exclusions applied — "
            "ignored-but-present paths may appear as candidates."
        )

dir_files = {}      # rel dir path -> recursive file count
dir_depth = {}
file_paths = set()  # rel file paths within MAX_DEPTH + 1

for entry in survey.get("tree", []):
    if entry.get("type") == "directory":
        dir_files[entry["path"]] = entry.get("file_count", 0)
        dir_depth[entry["path"]] = entry.get("depth", entry["path"].count("/") + 1)
    elif entry.get("type") == "file":
        file_paths.add(entry["path"])

children_by_dir = {}
for d in dir_files:
    children_by_dir.setdefault(parent_of(d), []).append(d)
for key in children_by_dir:
    children_by_dir[key].sort()

files_by_dir = {}
for f in file_paths:
    files_by_dir.setdefault(parent_of(f), []).append(f)
for key in files_by_dir:
    files_by_dir[key].sort()

# ---------------------------------------------------------------------------
# Exclusion, viability, and the candidate/container partition
# ---------------------------------------------------------------------------

excluded = []
containers = []
candidate_paths = []


def exclusion_reason(rel, depth):
    name = basename_of(rel)
    if name in SKIP_DIRS:
        return "build output, vendored dependency, or tooling directory (%s/)" % name
    if name == "worktrees" and parent_of(rel).endswith(".claude"):
        return "worktree directory (.claude/worktrees holds full copies of the repo)"
    if not INCLUDE_FRAMEWORK and depth == 1 and rel in FRAMEWORK_PATHS:
        return ("Jenga framework scaffolding, not consumer application code "
                "(use --include-framework to keep it)")
    if not INCLUDE_TRAINING and depth == 1 and rel in TRAINING_SCAFFOLD_PATHS:
        return ("training-job template scaffolding, not consumer application code "
                "(use --include-training-scaffolding to keep it)")
    return None


def viable_children(dirpath, depth):
    """Child directories of dirpath that survive exclusion and the --min-files floor."""
    out = []
    for child in children_by_dir.get(dirpath, []):
        if exclusion_reason(child, depth + 1):
            continue
        if dir_files.get(child, 0) < MIN_FILES:
            continue
        out.append(child)
    return out


def has_own_manifest(dirpath):
    return any(is_manifest(basename_of(f)) for f in files_by_dir.get(dirpath, []))


def descend(dirpath, depth):
    """Classify every child of dirpath as candidate, container, or excluded."""
    for child in children_by_dir.get(dirpath, []):
        reason = exclusion_reason(child, depth + 1)
        if reason:
            excluded.append({"path": child, "reason": reason})
            continue
        count = dir_files.get(child, 0)
        if count < MIN_FILES:
            excluded.append({
                "path": child,
                "reason": "below the --min-files floor of %d (%d file%s)" % (
                    MIN_FILES, count, "" if count == 1 else "s"),
            })
            continue
        classify(child, depth + 1)


def classify(dirpath, depth):
    """Decide whether dirpath is a subsystem or a folder of subsystems."""
    if depth >= MAX_DEPTH:
        candidate_paths.append(dirpath)
        return
    if has_own_manifest(dirpath):
        # A directory with its own manifest is a unit by definition. This is the rule that keeps
        # monorepo workspace packages intact regardless of their internal shape.
        candidate_paths.append(dirpath)
        return

    kids = viable_children(dirpath, depth)
    if len(kids) < 2:
        candidate_paths.append(dirpath)
        return

    direct = len(files_by_dir.get(dirpath, []))
    total = dir_files.get(dirpath, 0)
    incidental = direct <= 3 or (total > 0 and (float(direct) / total) <= 0.20)
    if not incidental:
        # It holds substantial code of its own, so it is a subsystem in its own right rather
        # than a wrapper around its children.
        candidate_paths.append(dirpath)
        return

    containers.append({
        "path": dirpath,
        "depth": depth,
        "reason": ("holds %d viable child directories and only %d file%s of its own, so it "
                   "reads as a folder of subsystems rather than a subsystem" % (
                       len(kids), direct, "" if direct == 1 else "s")),
        "expanded_into": kids,
    })
    descend(dirpath, depth)


descend("", 0)
candidate_paths.sort()

# --- runtime bound (NOT the onboard epic cap) --------------------------------------------------
if len(candidate_paths) > MAX_CANDIDATES:
    ordered = sorted(candidate_paths, key=lambda p: (-dir_files.get(p, 0), p))
    kept, dropped = ordered[:MAX_CANDIDATES], ordered[MAX_CANDIDATES:]
    for p in sorted(dropped):
        excluded.append({
            "path": p,
            "reason": "beyond the --max-candidates runtime bound of %d (analysis cost guard, "
                      "not the onboard epic cap)" % MAX_CANDIDATES,
        })
    notices.append(
        "%d candidate directories were found but only the %d largest were enumerated "
        "(--max-candidates). The remainder are listed under \"excluded\". This is a cost guard "
        "on the analysis, not the onboard epic cap." % (len(candidate_paths), MAX_CANDIDATES)
    )
    candidate_paths = sorted(kept)

# ---------------------------------------------------------------------------
# Pass 2 — per-candidate statistics, delegated to enumerate-target.sh
# ---------------------------------------------------------------------------

deps_available = WITH_DEPENDENCIES and os.access(DETECT_DEPS, os.X_OK)
if WITH_DEPENDENCIES and not deps_available:
    notices.append(
        "--with-dependencies was requested but detect-dependencies.sh is missing or not "
        "executable at %s; the cohesion signal was dropped and the remaining weights were "
        "renormalised." % DETECT_DEPS
    )


def cohesion_for(abs_path):
    """internal / (internal + external) dependency ratio, or None when unavailable."""
    try:
        proc = subprocess.run([DETECT_DEPS, abs_path],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    try:
        report = json.loads(proc.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None
    counts = report.get("counts") or {}
    internal = counts.get("internal", 0)
    external = counts.get("external", 0)
    if internal + external == 0:
        return None
    return float(internal) / (internal + external), internal, external


def skip_dir_reason(rel_in_candidate):
    """Layer-2 exclusion, evaluated INSIDE an already-selected candidate."""
    name = basename_of(rel_in_candidate)
    if name in SKIP_DIRS:
        return "build output, vendored dependency, or tooling directory (%s/)" % name
    if name == "worktrees" and parent_of(rel_in_candidate).endswith(".claude"):
        return "worktree directory (.claude/worktrees holds full copies of the repo)"
    return None


def nested_skip_roots(stats, candidate_rel):
    """Outermost SKIP_DIRS directories sitting inside a candidate's own subtree.

    enumerate-target.sh has no name-exclusion concept -- .gitignore is its only filter -- so a
    COMMITTED node_modules/vendor/dist/build inside a candidate would otherwise be folded into
    that candidate's own totals and score. Gitignored ones never reach here: they are absent from
    the parent's listing entirely, which is also why subtracting the ones that ARE here can never
    double-subtract. Only outermost matches are returned; the tree is path-sorted, so a parent
    always precedes its children.

    Paths are re-qualified against candidate_rel before being tested. The tree is relative to the
    candidate, but skip_dir_reason() reasons about a path's PARENT (that is how .claude/worktrees
    is recognised), and a candidate-relative path has no parent to inspect at its top level. Test
    "worktrees" alone and the .claude/worktrees rule silently never fires for a candidate that IS
    .claude -- returning paths still candidate-relative, since that is what the caller subtracts
    against.
    """
    roots = []
    for entry in stats.get("tree", []):
        if entry.get("type") != "directory":
            continue
        path = entry["path"]
        if any(path == r or path.startswith(r + "/") for r, _ in roots):
            continue
        qualified = (candidate_rel + "/" + path) if candidate_rel else path
        reason = skip_dir_reason(qualified)
        if reason:
            roots.append((path, reason))
    return roots


measured = []
for rel in candidate_paths:
    abs_path = os.path.join(ROOT_ABS, rel)
    stats, err = enumerate_target(abs_path, CANDIDATE_TREE_DEPTH, CAP_LARGEST)
    if stats is None:
        excluded.append({"path": rel, "reason": "enumeration failed (%s)" % err})
        notices.append("Skipped candidate %s: %s" % (rel, err))
        continue

    # --- discount any vendored/build content nested inside this candidate ---------------------
    # Enumeration stays delegated: each nested directory's weight is measured by
    # enumerate-target.sh in its own right and then subtracted, rather than recounted here.
    skip_roots = nested_skip_roots(stats, rel)
    nested_excluded = []
    discount_files = discount_lines = discount_bytes = 0
    discount_ext_files = {}
    discount_ext_lines = {}

    for skip_path, skip_reason in skip_roots:
        sub, sub_err = enumerate_target(os.path.join(abs_path, skip_path), 1, 1)
        if sub is None:
            notices.append(
                "Could not measure %s nested inside candidate %s (%s); its content remains "
                "counted in that candidate's statistics." % (skip_path, rel, sub_err))
            continue
        discount_files += sub.get("total_files", 0)
        discount_lines += sub.get("total_lines", 0)
        discount_bytes += sub.get("total_bytes", 0)
        for e in sub.get("extensions", []):
            ext = e.get("extension")
            discount_ext_files[ext] = discount_ext_files.get(ext, 0) + e.get("files", 0)
            discount_ext_lines[ext] = discount_ext_lines.get(ext, 0) + e.get("lines", 0)
        nested_excluded.append({
            "path": skip_path,
            "reason": skip_reason,
            "files": sub.get("total_files", 0),
            "lines": sub.get("total_lines", 0),
        })
        excluded.append({
            "path": (rel + "/" + skip_path),
            "reason": skip_reason + ", discounted from its parent candidate's statistics",
        })

    def under_skip_root(path):
        return any(path == r or path.startswith(r + "/") for r, _ in skip_roots)

    direct_files = []
    subdirs = []
    manifests = []
    test_paths = []
    doc_paths = []

    for entry in stats.get("tree", []):
        path = entry["path"]
        if under_skip_root(path):
            continue
        depth = entry.get("depth", path.count("/") + 1)
        name = basename_of(path)
        if entry.get("type") == "directory":
            if depth == 1:
                subdirs.append(path)
                if name.lower() in TEST_DIR_NAMES:
                    test_paths.append(path + "/")
                if name.lower() in DOC_DIR_NAMES:
                    doc_paths.append(path + "/")
        else:
            if depth == 1:
                direct_files.append(path)
                if is_manifest(name):
                    manifests.append(name)
                if DOC_FILE_PATTERN.match(name):
                    doc_paths.append(path)
            if depth <= CANDIDATE_SIGNAL_DEPTH and looks_like_test_file(name):
                test_paths.append(path)

    # Clamped at zero: the subtraction is exact by construction, but a candidate's stats must
    # never be able to go negative on the back of an enumeration disagreement.
    total_files = max(0, stats.get("total_files", 0) - discount_files)
    total_lines = max(0, stats.get("total_lines", 0) - discount_lines)
    total_bytes = max(0, stats.get("total_bytes", 0) - discount_bytes)

    extensions = []
    for e in stats.get("extensions", []):
        ext = e.get("extension")
        files_left = e.get("files", 0) - discount_ext_files.get(ext, 0)
        if files_left <= 0:
            continue
        extensions.append({
            "extension": ext,
            "files": files_left,
            "lines": max(0, e.get("lines", 0) - discount_ext_lines.get(ext, 0)),
        })
    extensions.sort(key=lambda e: (-e["files"], e["extension"]))

    source_files = sum(e["files"] for e in extensions if e["extension"] in SOURCE_EXTS)

    measured.append({
        "path": rel,
        "absolute_path": abs_path,
        "depth": dir_depth.get(rel, rel.count("/") + 1),
        "parent": parent_of(rel) or None,
        "files": total_files,
        "lines": total_lines,
        "bytes": total_bytes,
        "direct_files": len(direct_files),
        "subdirectories": len(subdirs),
        "manifests": sorted(set(manifests)),
        "test_paths": sorted(set(test_paths))[:CAP_TEST_PATHS],
        "doc_paths": sorted(set(doc_paths))[:CAP_DOC_PATHS],
        "top_extensions": extensions[:CAP_EXTENSIONS],
        "largest_files": [{"path": f["path"], "lines": f["lines"]}
                          for f in stats.get("largest_files", [])
                          if not under_skip_root(f["path"])][:CAP_LARGEST],
        "nested_excluded": sorted(nested_excluded, key=lambda n: n["path"]),
        "_source_files": source_files,
    })

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

max_lines = max([c["lines"] for c in measured], default=0)

for c in measured:
    signals = []

    def add(name, value, detail):
        value = max(0.0, min(1.0, float(value)))
        weight = WEIGHTS[name]
        signals.append({
            "name": name,
            "value": round(value, 4),
            "weight": weight,
            "contribution": round(value * weight, 2),
            "detail": detail,
        })

    if max_lines > 0:
        size_value = math.log1p(c["lines"]) / math.log1p(max_lines)
    else:
        size_value = 0.0
    add("size", size_value,
        "%d line%s across %d file%s (log-scaled against the largest candidate, %d lines)" % (
            c["lines"], "" if c["lines"] == 1 else "s",
            c["files"], "" if c["files"] == 1 else "s", max_lines))

    add("manifest", 1.0 if c["manifests"] else 0.0,
        ("declares its own %s" % ", ".join(c["manifests"])) if c["manifests"]
        else "no dependency manifest of its own")

    add("own_tests", 1.0 if c["test_paths"] else 0.0,
        ("carries its own tests (%s)" % ", ".join(c["test_paths"][:3])) if c["test_paths"]
        else "no test directory or test-named files of its own")

    density = (float(c["_source_files"]) / c["files"]) if c["files"] else 0.0
    add("source_density", density,
        "%d of %d file%s have a recognised source extension" % (
            c["_source_files"], c["files"], "" if c["files"] == 1 else "s"))

    add("structure", min(c["subdirectories"], 4) / 4.0,
        "%d immediate subdirector%s" % (
            c["subdirectories"], "y" if c["subdirectories"] == 1 else "ies"))

    add("docs", 1.0 if c["doc_paths"] else 0.0,
        ("documented by %s" % ", ".join(c["doc_paths"][:3])) if c["doc_paths"]
        else "no README or docs/ of its own")

    if deps_available:
        result = cohesion_for(c["absolute_path"])
        if result is None:
            add("cohesion", 0.0, "no import/require statements could be resolved")
        else:
            ratio, internal, external = result
            add("cohesion", ratio,
                "%d internal vs %d external dependencies" % (internal, external))

    total_weight = sum(s["weight"] for s in signals)
    raw = sum(s["contribution"] for s in signals)
    c["score"] = round(100.0 * raw / total_weight, 2) if total_weight else 0.0
    c["signals"] = signals
    del c["_source_files"]

measured.sort(key=lambda c: (-c["score"], c["path"]))

candidates = []
for i, c in enumerate(measured, start=1):
    candidates.append({
        "rank": i,
        "path": c["path"],
        "absolute_path": c["absolute_path"],
        "depth": c["depth"],
        "parent": c["parent"],
        "score": c["score"],
        "files": c["files"],
        "lines": c["lines"],
        "bytes": c["bytes"],
        "direct_files": c["direct_files"],
        "subdirectories": c["subdirectories"],
        "manifests": c["manifests"],
        "test_paths": c["test_paths"],
        "doc_paths": c["doc_paths"],
        "top_extensions": c["top_extensions"],
        "largest_files": c["largest_files"],
        "nested_excluded": c["nested_excluded"],
        "signals": c["signals"],
    })

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------

if not candidates:
    if not dir_files and not file_paths:
        notices.append("No files were found under the analysed root — nothing to discover.")
    elif excluded:
        notices.append(
            "No candidate subsystems survived filtering: all %d directory candidate(s) were "
            "excluded. See \"excluded\" for the reason on each." % len(excluded)
        )
    else:
        notices.append(
            "No candidate subsystems were found. The root appears to hold only loose files — "
            "see \"root_files\"."
        )

root_file_names = files_by_dir.get("", [])

result = {
    "script": "discover-subsystems.sh",
    "version": 1,
    "root": os.path.relpath(ROOT_ABS, REPO_ROOT) if REPO_ROOT else ROOT_ABS,
    "root_absolute": ROOT_ABS,
    "repo_root": REPO_ROOT or None,
    "max_depth": MAX_DEPTH,
    "min_files": MIN_FILES,
    "max_candidates": MAX_CANDIDATES,
    "framework_excluded": not INCLUDE_FRAMEWORK,
    "gitignore_respected": gitignore_respected,
    "with_dependencies": deps_available,
    "totals": {
        "files": survey.get("total_files", 0),
        "lines": survey.get("total_lines", 0),
        "bytes": survey.get("total_bytes", 0),
    },
    "candidate_count": len(candidates),
    "candidates": candidates,
    "containers": sorted(containers, key=lambda c: c["path"]),
    "excluded": sorted(excluded, key=lambda e: e["path"]),
    "root_files": {
        "count": len(root_file_names),
        "paths": sorted(root_file_names)[:CAP_ROOT_FILES],
    },
    "notices": notices,
}

json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY

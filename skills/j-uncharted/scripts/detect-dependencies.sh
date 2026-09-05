#!/usr/bin/env bash
# detect-dependencies.sh — dependency detection for the /uncharted investigative engine
#
# Usage: detect-dependencies.sh <target-path>
#        detect-dependencies.sh --help
#
# Scans <target-path> (a file or a directory) for import/require/include statements
# and reports two buckets on stdout as JSON:
#
#   internal — dependencies that resolve to a path inside the target's own repository
#   external — third-party packages, stdlib modules, and notable external commands
#
# It additionally lists every dependency manifest found in, or in any directory above,
# the target (package.json, pyproject.toml, requirements.txt, go.mod, Cargo.toml,
# Gemfile, and friends) with a best-effort parse of the dependency names they declare,
# so the calling agent can reconcile grepped imports against declared dependencies.
#
# This script is STRICTLY READ-ONLY. It creates no files, no temp files, and mutates
# no git state. Its only outputs are JSON on stdout and diagnostics on stderr.
#
# ---------------------------------------------------------------------------
# Output contract (stdout, JSON) — consumed by skills/j-uncharted/scripts/run-engine.sh
# ---------------------------------------------------------------------------
# {
#   "script": "detect-dependencies.sh",
#   "version": 1,
#   "target":            "<repo-relative path to the target>",
#   "target_absolute":   "<absolute path to the target>",
#   "target_type":       "file" | "directory",
#   "repo_root":         "<absolute path to the repository root>",
#   "files_scanned":     <int>,
#   "files_truncated":   <bool>,          // true when the walk cap was hit
#   "unrecognised":      <bool>,          // true when no source language was recognised
#   "languages":         [ { "language": "shell", "files": 12 }, ... ],
#   "unrecognised_extensions": [ { "extension": ".md", "files": 4 }, ... ],
#   "counts":            { "internal": <int>, "external": <int> },
#   "internal": [
#     {
#       "raw":         "<the specifier exactly as written in source>",
#       "language":    "<language of the referencing file>",
#       "resolved":    "<repo-relative path it resolves to, or null>",
#       "occurrences": <int>,
#       "sources":     [ "<up to 3 repo-relative referencing files>" ]
#     }
#   ],
#   "external": [
#     {
#       "name":        "<package / module / command name>",
#       "language":    "<language of the referencing file>",
#       "kind":        "package" | "stdlib" | "command" | "unknown",
#       "occurrences": <int>,
#       "sources":     [ "<up to 3 repo-relative referencing files>" ]
#     }
#   ],
#   "manifests": [
#     {
#       "name":     "package.json",
#       "path":     "<repo-relative path>",
#       "location": "target" | "ancestor",
#       "distance": <int>,                 // directory levels above the target (0 = in it)
#       "declared_dependencies": [ "<name>", ... ] | null   // null = not parsed / parse failed
#     }
#   ],
#   "notices": [ "<non-fatal diagnostic>", ... ]
# }
#
# ---------------------------------------------------------------------------
# Behaviour notes
# ---------------------------------------------------------------------------
#   - Unrecognised language: NOT an error. The script exits 0 with empty internal/external
#     arrays, "unrecognised": true, and an explanatory entry in "notices".
#   - Target outside a git repository: NOT an error. repo_root falls back to the target's
#     own directory and a notice is emitted.
#   - Regex-based extraction is deliberately approximate — this output feeds an agent's
#     understanding document, not a build system. Every entry carries its raw specifier
#     and example source files so the reader can verify.
#
# Exit codes:
#   0 — success (including every graceful-degradation path above)
#   1 — usage error (wrong number of arguments)
#   2 — target path does not exist

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <target-path>

Scans a file or directory for imports/requires/includes and prints a JSON report
separating internal (in-repo) from external (third-party/stdlib) dependencies,
plus any dependency manifests found in or above the target.

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
        "Internal/external classification may be less accurate." % REPO_ROOT
    )

MAX_FILES = 4000
MAX_BYTES = 1024 * 1024

SKIP_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build",
    ".next", "coverage", "vendor", "target", ".mypy_cache", ".pytest_cache",
    ".tox", ".gradle", ".idea", ".svn", ".hg", "bower_components", ".terraform",
}

EXT_LANG = {
    ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript", ".jsx": "javascript",
    ".ts": "typescript", ".tsx": "typescript", ".mts": "typescript", ".cts": "typescript",
    ".py": "python", ".pyi": "python",
    ".go": "go",
    ".rs": "rust",
    ".rb": "ruby",
    ".sh": "shell", ".bash": "shell", ".zsh": "shell",
    ".c": "c", ".h": "c",
    ".cc": "cpp", ".cpp": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hh": "cpp",
    ".java": "java", ".kt": "kotlin", ".kts": "kotlin",
    ".php": "php",
}

SHEBANG_LANG = [
    (re.compile(r"^#!.*\b(?:bash|sh|zsh|dash)\b"), "shell"),
    (re.compile(r"^#!.*\bpython[0-9.]*\b"), "python"),
    (re.compile(r"^#!.*\bnode\b"), "javascript"),
    (re.compile(r"^#!.*\bruby\b"), "ruby"),
]


def rel(path):
    """Repo-relative POSIX path, falling back to the absolute path when outside the repo."""
    try:
        r = os.path.relpath(path, REPO_ROOT)
    except ValueError:
        return path
    if r.startswith(".."):
        return path
    return r.replace(os.sep, "/")


def walk_files(root):
    """Enumerate files under root (or [root] when root is a file), honouring SKIP_DIRS."""
    if os.path.isfile(root):
        return [root], False
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        keep = []
        for d in sorted(dirnames):
            if d in SKIP_DIRS:
                continue
            # .claude/worktrees holds full copies of the repo — never descend into it.
            if d == "worktrees" and os.path.basename(dirpath) == ".claude":
                continue
            keep.append(d)
        dirnames[:] = keep
        for fn in sorted(filenames):
            out.append(os.path.join(dirpath, fn))
            if len(out) >= MAX_FILES:
                return out, True
    return out, False


def read_text(path):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def detect_language(path, text):
    ext = os.path.splitext(path)[1].lower()
    if ext in EXT_LANG:
        return EXT_LANG[ext], ext
    if not ext and text:
        first = text.split("\n", 1)[0]
        for pattern, lang in SHEBANG_LANG:
            if pattern.match(first):
                return lang, ext
    return None, ext


def find_upwards(start_dir, names):
    """Yield (directory, distance) from start_dir up to and including REPO_ROOT."""
    cur = os.path.abspath(start_dir)
    root = os.path.abspath(REPO_ROOT)
    distance = 0
    while True:
        yield cur, distance
        if cur == root or os.path.dirname(cur) == cur:
            return
        if not cur.startswith(root + os.sep):
            return
        cur = os.path.dirname(cur)
        distance += 1


# ---------------------------------------------------------------------------
# Dependency accumulators
# ---------------------------------------------------------------------------

internal = {}
external = {}


def add_internal(raw, language, resolved, source):
    key = (raw, language)
    entry = internal.setdefault(key, {
        "raw": raw, "language": language, "resolved": resolved,
        "occurrences": 0, "sources": [],
    })
    entry["occurrences"] += 1
    if resolved and not entry["resolved"]:
        entry["resolved"] = resolved
    if source not in entry["sources"] and len(entry["sources"]) < 3:
        entry["sources"].append(source)


def add_external(name, language, kind, source):
    key = (name, language)
    entry = external.setdefault(key, {
        "name": name, "language": language, "kind": kind,
        "occurrences": 0, "sources": [],
    })
    entry["occurrences"] += 1
    if kind != "unknown" and entry["kind"] == "unknown":
        entry["kind"] = kind
    if source not in entry["sources"] and len(entry["sources"]) < 3:
        entry["sources"].append(source)


def resolve_path(base_dir, spec, suffixes):
    """Resolve spec against base_dir (then REPO_ROOT), trying each suffix. Returns rel path or None."""
    candidates = []
    if spec.startswith("/"):
        candidates.append(os.path.join(REPO_ROOT, spec.lstrip("/")))
    else:
        candidates.append(os.path.normpath(os.path.join(base_dir, spec)))
        candidates.append(os.path.normpath(os.path.join(REPO_ROOT, spec)))
    for cand in candidates:
        for suffix in suffixes:
            probe = cand + suffix
            if os.path.isfile(probe):
                return rel(probe)
        if not suffixes and os.path.exists(cand):
            return rel(cand)
    return None


# ---------------------------------------------------------------------------
# Per-language extractors
# ---------------------------------------------------------------------------

JS_PATTERNS = [
    re.compile(r"""\bfrom\s+['"]([^'"\n]+)['"]"""),
    re.compile(r"""\brequire\s*\(\s*['"]([^'"\n]+)['"]\s*\)"""),
    re.compile(r"""\bimport\s*\(\s*['"]([^'"\n]+)['"]\s*\)"""),
    re.compile(r"""^\s*import\s+['"]([^'"\n]+)['"]""", re.M),
]
JS_SUFFIXES = ["", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".json",
               "/index.js", "/index.ts", "/index.mjs"]
# Node.js built-in modules — reported as stdlib so the caller does not flag them as
# undeclared when reconciling against package.json.
NODE_BUILTINS = {
    "assert", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
    "crypto", "dgram", "diagnostics_channel", "dns", "domain", "events", "fs", "http",
    "http2", "https", "inspector", "module", "net", "os", "path", "perf_hooks", "process",
    "punycode", "querystring", "readline", "repl", "stream", "string_decoder", "timers",
    "tls", "trace_events", "tty", "url", "util", "v8", "vm", "wasi", "worker_threads", "zlib",
}


def scan_js(text, path, base_dir, language, source):
    for pattern in JS_PATTERNS:
        for spec in pattern.findall(text):
            if spec.startswith((".", "/", "~/", "@/", "#")):
                add_internal(spec, language, resolve_path(base_dir, spec.lstrip("~@#"), JS_SUFFIXES), source)
                continue
            parts = spec.split("/")
            name = "/".join(parts[:2]) if spec.startswith("@") else parts[0]
            resolved = resolve_path(base_dir, spec, JS_SUFFIXES)
            if resolved:
                add_internal(spec, language, resolved, source)
            elif name.startswith("node:") or name in NODE_BUILTINS:
                add_external(name.replace("node:", "", 1), language, "stdlib", source)
            else:
                add_external(name, language, "package", source)


PY_IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][\w.]*(?:\s*,\s*[A-Za-z_][\w.]*)*)", re.M)
PY_FROM = re.compile(r"^\s*from\s+(\.*[A-Za-z_][\w.]*|\.+)\s+import\s", re.M)
PY_STDLIB = set(getattr(sys, "stdlib_module_names", ()))


def _py_resolve(dotted, base_dir):
    parts = dotted.split(".")
    for root in (base_dir, REPO_ROOT):
        stem = os.path.join(root, *parts)
        if os.path.isfile(stem + ".py"):
            return rel(stem + ".py")
        if os.path.isfile(os.path.join(stem, "__init__.py")):
            return rel(os.path.join(stem, "__init__.py"))
    return None


def scan_python(text, path, base_dir, language, source):
    specs = []
    for group in PY_IMPORT.findall(text):
        specs.extend(s.strip() for s in group.split(","))
    specs.extend(PY_FROM.findall(text))
    for spec in specs:
        if not spec:
            continue
        if spec.startswith("."):
            up = len(spec) - len(spec.lstrip("."))
            tail = spec.lstrip(".")
            anchor = base_dir
            for _ in range(up - 1):
                anchor = os.path.dirname(anchor)
            add_internal(spec, language, _py_resolve(tail, anchor) if tail else rel(anchor), source)
            continue
        top = spec.split(".")[0]
        resolved = _py_resolve(spec, base_dir)
        if resolved:
            add_internal(spec, language, resolved, source)
        elif top in PY_STDLIB:
            add_external(top, language, "stdlib", source)
        else:
            add_external(top, language, "package", source)


GO_BLOCK = re.compile(r"^\s*import\s*\(([^)]*)\)", re.M)
GO_SINGLE = re.compile(r"""^\s*import\s+(?:[\w.]+\s+)?"([^"]+)\"""", re.M)
GO_QUOTED = re.compile(r'"([^"]+)"')


def _go_module_path(base_dir):
    for directory, _ in find_upwards(base_dir, None):
        gomod = os.path.join(directory, "go.mod")
        if os.path.isfile(gomod):
            text = read_text(gomod) or ""
            match = re.search(r"^\s*module\s+(\S+)", text, re.M)
            if match:
                return match.group(1)
    return None


def scan_go(text, path, base_dir, language, source):
    module = _go_module_path(base_dir)
    specs = []
    for block in GO_BLOCK.findall(text):
        specs.extend(GO_QUOTED.findall(block))
    specs.extend(GO_SINGLE.findall(text))
    for spec in specs:
        if module and (spec == module or spec.startswith(module + "/")):
            sub = spec[len(module):].lstrip("/")
            add_internal(spec, language, rel(os.path.join(REPO_ROOT, sub)) if sub else rel(REPO_ROOT), source)
        elif "." not in spec.split("/")[0]:
            add_external(spec, language, "stdlib", source)
        else:
            add_external("/".join(spec.split("/")[:3]), language, "package", source)


RUST_USE = re.compile(r"^\s*(?:pub\s+)?use\s+([A-Za-z_][\w:]*)", re.M)
RUST_MOD = re.compile(r"^\s*(?:pub\s+)?mod\s+([A-Za-z_]\w*)\s*;", re.M)


def scan_rust(text, path, base_dir, language, source):
    for spec in RUST_USE.findall(text):
        root = spec.split("::")[0]
        if root in ("crate", "super", "self"):
            add_internal(spec, language, None, source)
        else:
            add_external(root, language, "package", source)
    for name in RUST_MOD.findall(text):
        add_internal("mod " + name, language, resolve_path(base_dir, name, [".rs", "/mod.rs"]), source)


RB_RELATIVE = re.compile(r"""\brequire_relative\s+['"]([^'"\n]+)['"]""")
RB_REQUIRE = re.compile(r"""\brequire\s+['"]([^'"\n]+)['"]""")


def scan_ruby(text, path, base_dir, language, source):
    for spec in RB_RELATIVE.findall(text):
        add_internal(spec, language, resolve_path(base_dir, spec, [".rb", ""]), source)
    for spec in RB_REQUIRE.findall(text):
        resolved = resolve_path(base_dir, spec, [".rb"])
        if resolved:
            add_internal(spec, language, resolved, source)
        else:
            add_external(spec.split("/")[0], language, "package", source)


SH_SOURCE = re.compile(r"""^\s*(?:\.|source)\s+["']?([^"'\s;&|]+)""", re.M)
SH_PATHLIKE = re.compile(r"""[A-Za-z0-9_./-]+\.(?:sh|bash|py|js|mjs|cjs|json|jsonl|md|tpl)\b""")
SH_COMMANDS = (
    "jq", "git", "gh", "npm", "npx", "node", "python3", "pip", "pip3", "curl", "wget",
    "docker", "rsync", "shellcheck", "pytest", "bats", "cargo", "go", "make", "ssh",
    "openssl", "aws", "gcloud", "terraform", "sqlite3", "yq", "tar", "zip", "unzip",
)
SH_COMMAND_RE = re.compile(
    r"(?:^|[|;&({!]|\$\(|&&|\|\|)\s*(?:!\s*)?(?:sudo\s+)?(" + "|".join(SH_COMMANDS) + r")\b", re.M
)
SH_MAX_PATHS = 40


def scan_shell(text, path, base_dir, language, source):
    for spec in SH_SOURCE.findall(text):
        if "$" in spec:
            # Contains a variable reference — record it, but do not pretend to resolve it.
            add_internal(spec, language, None, source)
        else:
            add_internal(spec, language, resolve_path(base_dir, spec, [""]), source)
    seen = set()
    for spec in SH_PATHLIKE.findall(text):
        if spec in seen:
            continue
        seen.add(spec)
        if len(seen) > SH_MAX_PATHS:
            break
        resolved = resolve_path(base_dir, spec, [""])
        if resolved and resolved != rel(path):
            add_internal(spec, language, resolved, source)
    for name in SH_COMMAND_RE.findall(text):
        add_external(name, language, "command", source)


C_LOCAL = re.compile(r"""^\s*#\s*include\s+"([^"\n]+)\"""", re.M)
C_SYSTEM = re.compile(r"^\s*#\s*include\s+<([^>\n]+)>", re.M)


def scan_c(text, path, base_dir, language, source):
    for spec in C_LOCAL.findall(text):
        add_internal(spec, language, resolve_path(base_dir, spec, [""]), source)
    for spec in C_SYSTEM.findall(text):
        add_external(spec, language, "stdlib", source)


JVM_IMPORT = re.compile(r"^\s*import\s+(?:static\s+)?([\w.]+)", re.M)
JVM_STDLIB_PREFIXES = ("java.", "javax.", "jakarta.", "kotlin.", "kotlinx.", "scala.")
JVM_SRC_ROOTS = ("", "src", "src/main/java", "src/main/kotlin", "app/src/main/java")


def scan_jvm(text, path, base_dir, language, source):
    for spec in JVM_IMPORT.findall(text):
        if spec.startswith(JVM_STDLIB_PREFIXES):
            add_external(spec, language, "stdlib", source)
            continue
        as_path = spec.replace(".", "/")
        resolved = None
        for src_root in JVM_SRC_ROOTS:
            resolved = resolve_path(os.path.join(REPO_ROOT, src_root), as_path, [".java", ".kt"])
            if resolved:
                break
        if resolved:
            add_internal(spec, language, resolved, source)
        else:
            add_external(spec, language, "package", source)


PHP_INCLUDE = re.compile(
    r"""^\s*(?:require|require_once|include|include_once)\s*\(?\s*['"]([^'"\n]+)['"]""", re.M
)
PHP_USE = re.compile(r"^\s*use\s+([\w\\]+)", re.M)


def scan_php(text, path, base_dir, language, source):
    for spec in PHP_INCLUDE.findall(text):
        add_internal(spec, language, resolve_path(base_dir, spec, ["", ".php"]), source)
    for spec in PHP_USE.findall(text):
        add_external(spec.lstrip("\\").split("\\")[0], language, "package", source)


SCANNERS = {
    "javascript": scan_js, "typescript": scan_js,
    "python": scan_python,
    "go": scan_go,
    "rust": scan_rust,
    "ruby": scan_ruby,
    "shell": scan_shell,
    "c": scan_c, "cpp": scan_c,
    "java": scan_jvm, "kotlin": scan_jvm,
    "php": scan_php,
}

# ---------------------------------------------------------------------------
# Manifest discovery
# ---------------------------------------------------------------------------

MANIFEST_NAMES = [
    "package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile",
    "setup.py", "setup.cfg", "Pipfile", "composer.json", "pom.xml",
    "build.gradle", "build.gradle.kts", "Package.swift", "mix.exs", "pubspec.yaml",
]


def _declared_package_json(text):
    data = json.loads(text)
    names = []
    for key in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        block = data.get(key)
        if isinstance(block, dict):
            names.extend(block.keys())
    return sorted(set(names))


def _declared_requirements(text):
    names = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or line.startswith("-"):
            continue
        names.append(re.split(r"[\s=<>!~;\[]", line, maxsplit=1)[0])
    return sorted({n for n in names if n})


def _declared_go_mod(text):
    names = []
    for block in re.findall(r"^\s*require\s*\(([^)]*)\)", text, re.M):
        for line in block.splitlines():
            line = line.split("//", 1)[0].strip()
            if line:
                names.append(line.split()[0])
    for match in re.findall(r"^\s*require\s+(\S+)\s+\S+", text, re.M):
        if not match.startswith("("):
            names.append(match)
    return sorted(set(names))


def _declared_toml_sections(text, sections):
    names = []
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped.strip("[]").strip()
            continue
        if current in sections and "=" in stripped and not stripped.startswith("#"):
            names.append(stripped.split("=", 1)[0].strip().split(".")[0].strip('"'))
    return sorted({n for n in names if n})


def _declared_cargo(text):
    return _declared_toml_sections(text, {"dependencies", "dev-dependencies", "build-dependencies"})


def _declared_pyproject(text):
    names = _declared_toml_sections(text, {"tool.poetry.dependencies", "tool.poetry.dev-dependencies"})
    for block in re.findall(r"^\s*dependencies\s*=\s*\[([^\]]*)\]", text, re.M):
        for item in re.findall(r"""['"]([^'"]+)['"]""", block):
            names.append(re.split(r"[\s=<>!~;\[]", item, maxsplit=1)[0])
    return sorted({n for n in names if n})


DECLARED_PARSERS = {
    "package.json": _declared_package_json,
    "requirements.txt": _declared_requirements,
    "go.mod": _declared_go_mod,
    "Cargo.toml": _declared_cargo,
    "pyproject.toml": _declared_pyproject,
}


def collect_manifests(start_dir):
    found = []
    for directory, distance in find_upwards(start_dir, None):
        for name in MANIFEST_NAMES:
            candidate = os.path.join(directory, name)
            if not os.path.isfile(candidate):
                continue
            declared = None
            parser = DECLARED_PARSERS.get(name)
            if parser:
                text = read_text(candidate)
                if text is not None:
                    try:
                        declared = parser(text)
                    except Exception:
                        notices.append(
                            "Could not parse declared dependencies from %s; manifest is listed "
                            "but declared_dependencies is null." % rel(candidate)
                        )
            found.append({
                "name": name,
                "path": rel(candidate),
                "location": "target" if distance == 0 else "ancestor",
                "distance": distance,
                "declared_dependencies": declared,
            })
    return found


# ---------------------------------------------------------------------------
# Main scan
# ---------------------------------------------------------------------------

is_dir = os.path.isdir(TARGET)
start_dir = TARGET if is_dir else os.path.dirname(TARGET)

files, truncated = walk_files(TARGET)
if truncated:
    notices.append(
        "File walk stopped at the %d-file cap; results are partial. Narrow the target for full coverage."
        % MAX_FILES
    )

language_counts = {}
unknown_ext_counts = {}
scanned = 0

for file_path in files:
    text = read_text(file_path)
    if text is None:
        continue
    language, ext = detect_language(file_path, text)
    if language is None:
        unknown_ext_counts[ext or "<no extension>"] = unknown_ext_counts.get(ext or "<no extension>", 0) + 1
        continue
    language_counts[language] = language_counts.get(language, 0) + 1
    scanned += 1
    scanner = SCANNERS.get(language)
    if scanner:
        scanner(text, file_path, os.path.dirname(file_path), language, rel(file_path))

unrecognised = scanned == 0
if unrecognised:
    notices.append(
        "No recognised source language was found under the target; the dependency result is "
        "explicitly empty rather than an error. Recognised languages: %s."
        % ", ".join(sorted(set(EXT_LANG.values())))
    )

manifests = collect_manifests(start_dir)

internal_list = sorted(internal.values(), key=lambda e: (e["resolved"] or e["raw"], e["language"]))
external_list = sorted(external.values(), key=lambda e: (e["language"], e["name"]))

result = {
    "script": "detect-dependencies.sh",
    "version": 1,
    "target": rel(TARGET),
    "target_absolute": TARGET,
    "target_type": "directory" if is_dir else "file",
    "repo_root": REPO_ROOT,
    "files_scanned": scanned,
    "files_truncated": truncated,
    "unrecognised": unrecognised,
    "languages": [
        {"language": k, "files": v}
        for k, v in sorted(language_counts.items(), key=lambda kv: (-kv[1], kv[0]))
    ],
    "unrecognised_extensions": [
        {"extension": k, "files": v}
        for k, v in sorted(unknown_ext_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
    ],
    "counts": {"internal": len(internal_list), "external": len(external_list)},
    "internal": internal_list,
    "external": external_list,
    "manifests": manifests,
    "notices": notices,
}

print(json.dumps(result, indent=2))
PY

#!/usr/bin/env bash
# distribute-changes.sh — Copy JengaAgent framework files into a consuming project
#
# Usage:
#   distribute-changes.sh <project_path> [--dry-run]
#
# Arguments:
#   project_path   Absolute or relative path to the consuming project root.
#   --dry-run      Print each planned action without writing any files.
#
# Behaviour:
#   1. Reads distribute.config.json from the monorepo root for the include list.
#   2. Reads <project_path>/jenga.config.json for target_dir and project_name.
#   3. Loads per-project exclusions from <project_path>/.jenga_ignore (warn, not error).
#   4. Rsyncs each included item to both <target_dir>/ and .claude/ in the project.
#   5. Copies AGENT.md, CLAUDE.md, WARP.md to the project root.
#   6. Writes jenga.config.json atomically (temp + mv).
#
# Exit codes:
#   0   Success
#   1   Bad argument / missing prerequisite
#   2   Missing or unreadable config file
#   3   rsync or copy failure
#   4   jenga.config.json write failure

# Do NOT use set -e globally — each step handles its own errors.
set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $(basename "$0") <project_path> [--dry-run]" >&2
  echo "" >&2
  echo "  project_path   Path to the consuming project root." >&2
  echo "  --dry-run      Print planned actions without writing files." >&2
  exit 1
}

info()    { echo "[distribute] $*"; }
warn()    { echo "[distribute] WARNING: $*"; }
err()     { echo "[distribute] ERROR: $*" >&2; }
dry_run() { echo "[DRY RUN] $*"; }

# ---------------------------------------------------------------------------
# Resolve monorepo root from this script's location.
# Script lives at: skills/distribute/scripts/distribute-changes.sh
# Repo root is three levels up.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Check runtime dependencies
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not found on PATH. Install jq and retry."
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  err "rsync is required but not found on PATH. Install rsync and retry."
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

PROJECT_PATH=""
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    -*)
      err "Unknown option: $arg"
      usage
      ;;
    *)
      if [ -z "$PROJECT_PATH" ]; then
        PROJECT_PATH="$arg"
      else
        err "Unexpected extra argument: $arg"
        usage
      fi
      ;;
  esac
done

if [ -z "$PROJECT_PATH" ]; then
  err "Missing required argument: project_path"
  usage
fi

# Resolve to absolute path — must already exist
if ! _resolved="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)"; then
  err "Target project path does not exist or is not a directory: $PROJECT_PATH"
  exit 1
fi
PROJECT_PATH="$_resolved"

if [ ! -d "$PROJECT_PATH" ]; then
  err "Target project path does not exist or is not a directory: $PROJECT_PATH"
  exit 1
fi

info "Monorepo root : $REPO_ROOT"
info "Target project: $PROJECT_PATH"
[ "$DRY_RUN" -eq 1 ] && info "Dry-run mode enabled — no files will be written."

# ---------------------------------------------------------------------------
# Step 1: Read distribute.config.json for the include list
# ---------------------------------------------------------------------------

DIST_CONFIG="$REPO_ROOT/distribute.config.json"

if [ ! -f "$DIST_CONFIG" ]; then
  err "distribute.config.json not found at $DIST_CONFIG"
  exit 2
fi

# Read include list into a newline-delimited variable (Bash 3 compatible)
INCLUDE_RAW="$(jq -r '.distribute.include[]' "$DIST_CONFIG" 2>/dev/null)"

if [ -z "$INCLUDE_RAW" ]; then
  err "distribute.config.json has an empty or missing distribute.include array: $DIST_CONFIG"
  exit 2
fi

# Build an array from the newline-delimited output
INCLUDE_LIST=()
while IFS= read -r item; do
  [ -n "$item" ] && INCLUDE_LIST+=("$item")
done <<< "$INCLUDE_RAW"

info "Include list (${#INCLUDE_LIST[@]} items): ${INCLUDE_LIST[*]}"

# ---------------------------------------------------------------------------
# Step 2: Read <project_path>/jenga.config.json for target_dir and project_name
# ---------------------------------------------------------------------------

JENGA_CONFIG="$PROJECT_PATH/jenga.config.json"
TARGET_DIR=".agents"
PROJECT_NAME=""
FIRST_DISTRIBUTION=0

if [ -f "$JENGA_CONFIG" ]; then
  _target_dir="$(jq -r '.target_dir // empty' "$JENGA_CONFIG" 2>/dev/null)"
  if [ -n "$_target_dir" ]; then
    TARGET_DIR="$_target_dir"
  fi

  _project_name="$(jq -r '.project_name // empty' "$JENGA_CONFIG" 2>/dev/null)"
  if [ -n "$_project_name" ]; then
    PROJECT_NAME="$_project_name"
  fi
else
  FIRST_DISTRIBUTION=1
  info "No jenga.config.json found — treating as first distribution."
fi

# Derive project_name from directory basename if not set
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$PROJECT_PATH")"
fi

info "Target directory : $TARGET_DIR"
info "Project name     : $PROJECT_NAME"
[ "$FIRST_DISTRIBUTION" -eq 1 ] && info "First distribution — no version comparison performed."

# ---------------------------------------------------------------------------
# Step 3: Load per-project exclusions from .jenga_ignore
# ---------------------------------------------------------------------------

JENGA_IGNORE="$PROJECT_PATH/.jenga_ignore"

# Store exclusions as a newline-delimited string for Bash 3 compatibility
IGNORE_LIST=""
IGNORE_COUNT=0

if [ -f "$JENGA_IGNORE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comment lines
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    IGNORE_LIST="${IGNORE_LIST}${line}"$'\n'
    IGNORE_COUNT=$((IGNORE_COUNT + 1))
  done < "$JENGA_IGNORE"
  info "Loaded $IGNORE_COUNT exclusion(s) from .jenga_ignore."
else
  warn ".jenga_ignore not found at $JENGA_IGNORE — no per-project exclusions applied."
fi

# Helper: returns 0 if the given item is in the ignore list, 1 otherwise.
is_ignored() {
  local needle="$1"
  local entry
  while IFS= read -r entry; do
    [ "$entry" = "$needle" ] && return 0
  done <<< "$IGNORE_LIST"
  return 1
}

# ---------------------------------------------------------------------------
# Step 4: Compute effective include list (exclude items in .jenga_ignore)
# ---------------------------------------------------------------------------

EFFECTIVE_INCLUDE=()
for item in "${INCLUDE_LIST[@]}"; do
  if is_ignored "$item"; then
    info "Skipping '$item' (excluded by .jenga_ignore)."
  else
    EFFECTIVE_INCLUDE+=("$item")
  fi
done

info "Effective include list (${#EFFECTIVE_INCLUDE[@]} items): ${EFFECTIVE_INCLUDE[*]}"

# ---------------------------------------------------------------------------
# Step 5: Copy items to both <target_dir>/ and .claude/ via rsync
# ---------------------------------------------------------------------------

_rsync_item() {
  local src="$1"
  local dst_parent="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    dry_run "rsync -a --delete \"$src\" \"$dst_parent/\""
    return 0
  fi

  if ! mkdir -p "$dst_parent"; then
    err "Failed to create destination directory: $dst_parent"
    return 3
  fi

  if ! rsync -a --delete "$src" "$dst_parent/"; then
    err "rsync failed: $src -> $dst_parent/"
    return 3
  fi
  return 0
}

for item in "${EFFECTIVE_INCLUDE[@]}"; do
  src="$REPO_ROOT/$item"

  if [ ! -e "$src" ]; then
    warn "Source item does not exist, skipping: $src"
    continue
  fi

  # Determine destination parent directories
  # rsync trailing slash copies the item itself into the parent,
  # so we pass the containing dir as the destination.
  dst_agents_parent="$PROJECT_PATH/$TARGET_DIR/$(dirname "$item")"
  dst_claude_parent="$PROJECT_PATH/.claude/$(dirname "$item")"

  # Normalise: dirname returns "." for a top-level item
  if [ "$(dirname "$item")" = "." ]; then
    dst_agents_parent="$PROJECT_PATH/$TARGET_DIR"
    dst_claude_parent="$PROJECT_PATH/.claude"
  fi

  if ! _rsync_item "$src" "$dst_agents_parent"; then
    exit 3
  fi
  [ "$DRY_RUN" -eq 0 ] && info "Copied $item -> $TARGET_DIR/$item"

  if ! _rsync_item "$src" "$dst_claude_parent"; then
    exit 3
  fi
  [ "$DRY_RUN" -eq 0 ] && info "Copied $item -> .claude/$item"
done

# ---------------------------------------------------------------------------
# Step 6: Copy root-level docs to the consuming project root
# ---------------------------------------------------------------------------

ROOT_DOCS="AGENT.md CLAUDE.md WARP.md"

for doc in $ROOT_DOCS; do
  src="$REPO_ROOT/$doc"
  dst="$PROJECT_PATH/$doc"

  if [ ! -f "$src" ]; then
    warn "Root doc not found in monorepo, skipping: $src"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    dry_run "cp \"$src\" \"$dst\""
  else
    if ! cp "$src" "$dst"; then
      err "Failed to copy $doc to project root: $dst"
      exit 3
    fi
    info "Copied $doc -> project root"
  fi
done

# ---------------------------------------------------------------------------
# Step 7: Write jenga.config.json atomically
# ---------------------------------------------------------------------------

PKG_JSON="$REPO_ROOT/package.json"
if [ ! -f "$PKG_JSON" ]; then
  err "package.json not found at $PKG_JSON — cannot determine version."
  exit 2
fi

MONOREPO_VERSION="$(jq -r '.version // empty' "$PKG_JSON" 2>/dev/null)"
if [ -z "$MONOREPO_VERSION" ]; then
  err "Could not read version from $PKG_JSON"
  exit 2
fi

UPDATED_AT="$(date -u +"%Y-%m-%d")"
LAST_DISTRIBUTED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build JSON using jq to ensure correct escaping of all values
JENGA_CONFIG_CONTENT="$(jq -n \
  --arg project_name    "$PROJECT_NAME" \
  --arg target_dir      "$TARGET_DIR" \
  --arg version         "$MONOREPO_VERSION" \
  --arg updated_at      "$UPDATED_AT" \
  --arg last_distributed "$LAST_DISTRIBUTED" \
  --arg source          "private" \
  '{
    project_name:    $project_name,
    target_dir:      $target_dir,
    version:         $version,
    updated_at:      $updated_at,
    last_distributed: $last_distributed,
    source:          $source
  }')"

if [ -z "$JENGA_CONFIG_CONTENT" ]; then
  err "Failed to construct jenga.config.json content."
  exit 4
fi

if [ "$DRY_RUN" -eq 1 ]; then
  dry_run "Write jenga.config.json to $JENGA_CONFIG"
  dry_run "Content:"
  while IFS= read -r line; do
    dry_run "  $line"
  done <<< "$JENGA_CONFIG_CONTENT"
else
  TEMP_CONFIG="${JENGA_CONFIG}.tmp"

  if ! printf '%s\n' "$JENGA_CONFIG_CONTENT" > "$TEMP_CONFIG"; then
    err "Failed to write temporary config file: $TEMP_CONFIG"
    exit 4
  fi

  if ! mv "$TEMP_CONFIG" "$JENGA_CONFIG"; then
    err "Failed to atomically move $TEMP_CONFIG to $JENGA_CONFIG"
    rm -f "$TEMP_CONFIG"
    exit 4
  fi

  info "Wrote jenga.config.json (version $MONOREPO_VERSION)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  info "Dry run complete — no files were written."
else
  info "Distribution complete for: $PROJECT_NAME ($PROJECT_PATH)"
fi

exit 0

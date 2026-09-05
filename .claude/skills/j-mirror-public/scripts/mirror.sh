#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-mirror-public/scripts/mirror.sh
#
# One-way sync engine for /mirror-public.
#
# Reads: skills/j-mirror-public/assets/config.json
#          - publicRepoUrl   : URL of the public downstream repo
#          - defaultBranch   : branch to sync (typically "main")
#          - worktreePath    : scratch worktree path (relative to repo root)
#        .publicignore       : rsync blocklist (single source of truth for
#                              private-only paths — see T01)
#
# Flow:
#   1. Prepare a scratch clone of <publicRepoUrl> at <worktreePath>, checked
#      out to <defaultBranch> at the tip of origin/<defaultBranch>.
#   2. Safety-check origin/<defaultBranch> against the local `last-mirror-sync`
#      tag in the scratch clone. Abort if the public branch has diverged
#      unless --force is passed. On a confirmed --force run (T05), push a
#      `pre-force-<short-sha>` rescue tag at the pre-overwrite public tip to
#      the remote before anything else, so the state about to be overwritten
#      stays recoverable from the remote itself, independent of this
#      gitignored/blocklisted scratch clone. Aborts if the tag push fails.
#   3. Publish-config invariant (T04): compute the ship set (compute_ship_list)
#      and verify package.json's name agrees with every publish.json target's
#      npm.package_name, and that publish.json's workflow_path/history_file
#      are both present in that ship set. Runs on EVERY push path (forced or
#      not — --dry-run/--inventory already exited above this point and never
#      reach it). Aborts non-zero before any mutation. No-op if publish.json
#      does not exist.
#   4. rsync the private repo root into the worktree, respecting
#      .publicignore and explicitly excluding .git/.
#   5. If nothing changed, exit 0 idempotently.
#   6. Otherwise squash everything into a single "chore(mirror): sync from
#      private at <short-sha> <UTC-timestamp>" commit with a
#      `Source-Commit: <full-sha>` trailer, advance the local marker tag,
#      and push origin/<defaultBranch>.
#   7. Print a summary (files-changed count, new commit SHA, remote branch,
#      public URL).
#
# Flags:
#   --dry-run   Read-only preview mode. Prepares the scratch worktree
#               (fetch+reset only — no rsync writes, no commit, no push),
#               then prints two labeled sections:
#                 - "Files that would ship" (from rsync --dry-run)
#                 - "Files that would be blocked" (candidates \ shipped)
#               Followed by totals and an explicit "dry run — no push" notice.
#   --inventory Read-only preview mode, same safety class as --dry-run
#               (fetch+reset only — no rsync writes, no commit, no push).
#               Computes the identical "would ship" set that --dry-run
#               computes (shared compute_ship_list function) and groups it
#               by top-level feature-type category (Skills/MCP/Agents/Hooks/
#               Scripts/Templates/Docs/Other), rendering the report through
#               skills/j-mirror-public/assets/inventory-template.md. Prints a
#               per-category file count and a grand total.
#   --exclude <path>
#               Purely local, ergonomic wrapper around hand-editing
#               .publicignore. Appends <path> as a new line, idempotently
#               (no duplicate if the exact pattern already exists). Never
#               loads config, never prepares the scratch worktree, never
#               fetches, never runs the safety check, never mirrors — it
#               only touches .publicignore and exits. Requires a non-empty
#               argument; missing or empty-string is a non-zero-exit error.
#   --force     Override the safety-abort when the public branch is ahead
#               of the recorded last mirror. Before mutating anything,
#               prints the full marker..remote divergent commit list (with
#               a count) and the set of public-only files that are not
#               matched by .publicignore and are absent from private (the
#               signature of unmirrored public-side work — routine
#               .publicignore-blocked deletions are excluded from this set
#               so they don't drown the signal), then requires explicit
#               confirmation. Declining aborts with no further mutation.
#               In a non-interactive shell, --force refuses unless paired
#               with --yes. Once confirmed, pushes a `pre-force-<short-sha>`
#               rescue tag at the pre-overwrite tip to the remote (T05)
#               before any rsync overwrite/commit/push; aborts if that tag
#               push fails. Naming is collision-safe (numeric suffix) when
#               the same tip is force-overwritten more than once.
#   --yes       Explicit non-interactive approval for the --force
#               confirmation prompt. Only meaningful alongside --force.
#               Without it, a non-interactive --force run refuses rather
#               than defaulting to proceed.
#   -h|--help   Print usage and exit.
#
# Env overrides:
#   MIRROR_PUBLIC_URL_OVERRIDE   Swap the configured publicRepoUrl at
#                                runtime (used for local-remote testing).
#
# The script NEVER modifies the private repo's .git/ or working tree.
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
  printf 'mirror.sh: error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'mirror.sh: %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage: mirror.sh [--dry-run | --inventory] [--force] [-h|--help]
       mirror.sh --exclude <path>

Options:
  --dry-run   Read-only preview. Prints the exact list of files that would
              ship and the list of files blocked by .publicignore, then
              exits with no commit and no push.
  --inventory Read-only preview. Prints the same "would ship" set as
              --dry-run, grouped by feature-type category (Skills, MCP,
              Agents, Hooks, Scripts, Templates, Docs, Other) with a
              per-category count and a grand total. No commit, no push.
              Mutually exclusive with --dry-run.
  --exclude <path>
              Purely local. Appends <path> to .publicignore idempotently
              (no duplicate line if already present) and exits — no config
              load, no scratch worktree, no fetch, no safety check, no
              mirror. Requires a non-empty argument. Cannot be combined
              with --dry-run, --inventory, or --force.
  --force     Override the safety abort when the public branch has moved
              since the last mirror. Prints the divergent commit list and
              the public-only file signature that will be destroyed, then
              requires explicit confirmation (or --yes non-interactively).
  --yes       Explicit approval for the --force confirmation prompt, for
              non-interactive use. Only meaningful alongside --force.
  -h, --help  Show this message and exit.

Env:
  MIRROR_PUBLIC_URL_OVERRIDE  Override the configured publicRepoUrl.
EOF
}

# -----------------------------------------------------------------------------
# Locate script + repo root
# -----------------------------------------------------------------------------

SCRIPT_PATH="${BASH_SOURCE[0]}"
# Resolve symlinks to a real path so SCRIPT_DIR points at the on-disk file.
while [ -h "$SCRIPT_PATH" ]; do
  LINK_TARGET="$(readlink "$SCRIPT_PATH")"
  case "$LINK_TARGET" in
    /*) SCRIPT_PATH="$LINK_TARGET" ;;
    *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)/$LINK_TARGET" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_ROOT="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "could not locate private repo root (git rev-parse failed from $SKILL_DIR)"

CONFIG_FILE="$SKILL_DIR/assets/config.json"
[ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE"

PUBLICIGNORE="$REPO_ROOT/.publicignore"
[ -f "$PUBLICIGNORE" ] || die ".publicignore not found at $PUBLICIGNORE (should have been created in T01)"

INVENTORY_TEMPLATE="$SKILL_DIR/assets/inventory-template.md"

# -----------------------------------------------------------------------------
# Parse flags
# -----------------------------------------------------------------------------

DRY_RUN=0
INVENTORY=0
FORCE=0
YES=0
EXCLUDE=0
EXCLUDE_PATH=""
# Name of the pre-force rescue tag pushed to the remote before an overwrite
# (T05). Stays empty on every path except a confirmed --force run, and is
# referenced (guarded by an emptiness check) in the final summary block —
# declared here so `set -u` never trips on it.
RESCUE_TAG=""

# Version-only auto-reconciliation (T02 / E28_S05). Stay empty on every path
# except a detected+applied version-only divergence, and are referenced
# (guarded by an emptiness check) in the final summary block — declared here
# so `set -u` never trips on them.
VERSION_ONLY_DETECTED_VERSION=""
VERSION_ONLY_RECONCILED_SHA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --inventory) INVENTORY=1 ;;
    --force)     FORCE=1 ;;
    --yes)       YES=1 ;;
    --exclude)
      EXCLUDE=1
      shift
      if [ $# -eq 0 ] || [ -z "$1" ]; then
        usage >&2
        die "--exclude requires a non-empty path argument"
      fi
      EXCLUDE_PATH="$1"
      ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

if [ "$DRY_RUN" -eq 1 ] && [ "$INVENTORY" -eq 1 ]; then
  usage >&2
  die "--dry-run and --inventory are mutually exclusive"
fi

if [ "$EXCLUDE" -eq 1 ] && { [ "$DRY_RUN" -eq 1 ] || [ "$INVENTORY" -eq 1 ] || [ "$FORCE" -eq 1 ]; }; then
  usage >&2
  die "--exclude cannot be combined with --dry-run, --inventory, or --force"
fi

if [ "$INVENTORY" -eq 1 ]; then
  [ -f "$INVENTORY_TEMPLATE" ] || die "inventory template not found: $INVENTORY_TEMPLATE"
fi

# rsync is needed both for the real sync and for the --force enumeration
# step (which runs before the safety-check block below), so the
# availability check is done here rather than after the safety check.
command -v rsync >/dev/null 2>&1 || die "rsync not installed"

# -----------------------------------------------------------------------------
# --exclude <path>: append to .publicignore idempotently, then exit
#
# Purely local — no config load, no scratch worktree, no fetch, no safety
# check, no mirror. This intentionally runs BEFORE the "Load config" section
# below so it can never trigger any of that machinery.
# -----------------------------------------------------------------------------

if [ "$EXCLUDE" -eq 1 ]; then
  if grep -qxF -- "$EXCLUDE_PATH" "$PUBLICIGNORE"; then
    log "already present, no change: '$EXCLUDE_PATH' already exists in $PUBLICIGNORE"
  else
    # Ensure the file ends in a newline before appending, so the new pattern
    # never gets concatenated onto a non-newline-terminated last line.
    if [ -s "$PUBLICIGNORE" ] && [ "$(tail -c1 "$PUBLICIGNORE")" != "" ]; then
      printf '\n' >> "$PUBLICIGNORE"
    fi
    printf '%s\n' "$EXCLUDE_PATH" >> "$PUBLICIGNORE"
    log "added '$EXCLUDE_PATH' to $PUBLICIGNORE"
  fi
  log "verify the result with --dry-run or --inventory before the next real run"
  exit 0
fi

# -----------------------------------------------------------------------------
# Load config (jq preferred, python3 fallback)
# -----------------------------------------------------------------------------

read_config_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg f "$field" '.[$f]' "$CONFIG_FILE" 2>/dev/null || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" "$field" <<'PY' || return 1
import json, sys
path, field = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
if field not in data:
    sys.exit(1)
sys.stdout.write(str(data[field]))
PY
  else
    die "neither jq nor python3 available to parse $CONFIG_FILE"
  fi
}

PUBLIC_URL="$(read_config_field publicRepoUrl)" || die "config missing publicRepoUrl"
DEFAULT_BRANCH="$(read_config_field defaultBranch)" || die "config missing defaultBranch"
WORKTREE_REL="$(read_config_field worktreePath)" || die "config missing worktreePath"

# Env override for local-remote testing.
if [ -n "${MIRROR_PUBLIC_URL_OVERRIDE:-}" ]; then
  log "using MIRROR_PUBLIC_URL_OVERRIDE=$MIRROR_PUBLIC_URL_OVERRIDE (config value ignored)"
  PUBLIC_URL="$MIRROR_PUBLIC_URL_OVERRIDE"
fi

# Resolve worktree path against repo root if it's relative.
case "$WORKTREE_REL" in
  /*) WORKTREE_PATH="$WORKTREE_REL" ;;
  *)  WORKTREE_PATH="$REPO_ROOT/$WORKTREE_REL" ;;
esac

log "repo root:      $REPO_ROOT"
log "public URL:     $PUBLIC_URL"
log "default branch: $DEFAULT_BRANCH"
log "worktree path:  $WORKTREE_PATH"

# -----------------------------------------------------------------------------
# Prepare scratch worktree (clone if missing, fetch+reset if present)
#
# REMOTE_BRANCH_EXISTS (T06): a genuinely empty public repo (zero commits,
# no refs at all yet) has no "$DEFAULT_BRANCH" ref for `git clone --branch`
# or `git fetch <branch>` to resolve — both die outright ("Remote branch ...
# not found" / "couldn't find remote ref ...") rather than falling back to
# an unborn checkout. That used to make genuine first-run bootstrap against
# a brand-new public repo impossible before ever reaching the marker
# durability check below, so the branch's existence is probed once, up
# front, and both the initial-clone and refresh paths branch on it. This is
# the single source of truth the safety check reuses to tell "genuinely
# empty remote, bootstrap" apart from "remote has commits but no local
# marker" (T06's actual fix, see the Safety check section).
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "$WORKTREE_PATH")"

REMOTE_BRANCH_EXISTS=0
if git ls-remote --exit-code --heads "$PUBLIC_URL" "$DEFAULT_BRANCH" >/dev/null 2>&1; then
  REMOTE_BRANCH_EXISTS=1
fi

if [ ! -d "$WORKTREE_PATH/.git" ]; then
  if [ "$REMOTE_BRANCH_EXISTS" -eq 1 ]; then
    log "cloning $PUBLIC_URL -> $WORKTREE_PATH (branch: $DEFAULT_BRANCH)"
    git clone --branch "$DEFAULT_BRANCH" --single-branch "$PUBLIC_URL" "$WORKTREE_PATH"
  else
    log "cloning $PUBLIC_URL -> $WORKTREE_PATH ($DEFAULT_BRANCH has no commits yet — empty-repo bootstrap)"
    git init -q -b "$DEFAULT_BRANCH" "$WORKTREE_PATH"
    git -C "$WORKTREE_PATH" remote add origin "$PUBLIC_URL"
  fi
else
  log "refreshing existing scratch worktree at $WORKTREE_PATH"
  git -C "$WORKTREE_PATH" remote set-url origin "$PUBLIC_URL"
  if [ "$REMOTE_BRANCH_EXISTS" -eq 1 ]; then
    git -C "$WORKTREE_PATH" fetch origin "$DEFAULT_BRANCH"
    git -C "$WORKTREE_PATH" checkout -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
    git -C "$WORKTREE_PATH" reset --hard "origin/$DEFAULT_BRANCH"
    # Preserve the marker tag if it exists; -x would leave untracked scratch,
    # but -fd is enough because we hard-reset above.
    git -C "$WORKTREE_PATH" clean -fd
  else
    log "$DEFAULT_BRANCH still has no commits on the remote — leaving scratch worktree as an unborn checkout"
    git -C "$WORKTREE_PATH" checkout -B "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
    git -C "$WORKTREE_PATH" clean -fd
  fi
fi

# -----------------------------------------------------------------------------
# _filter_itemize_changes
#
# Shared awk filter for `rsync --dry-run --itemize-changes --out-format='%i
# %n'` output. Reads itemize lines on stdin, prints one path per line for
# every entry that transfers/creates a file, symlink, or hardlink; drops
# directory-only entries (rsync recreates dirs implicitly) and any
# attribute-only / deletion / message lines. Itemize flag format is 11
# chars: YXcstpoguax
#   Y (update type): >=receive, <=send, c=create local, h=hard link,
#                    .=no update, *=message (e.g. deleting)
#   X (file type):   f=file, d=directory, L=symlink, D=device, S=special
# Factored out so every caller that needs "which files does this rsync
# dry-run touch" (compute_ship_list, compute_public_signature) parses the
# exact same way and can never drift apart.
# -----------------------------------------------------------------------------

_filter_itemize_changes() {
  awk '{
      flag = $1;
      first  = substr(flag, 1, 1);
      second = substr(flag, 2, 1);
      # Skip directories — recreated implicitly by rsync.
      if (second == "d") next;
      # Keep only entries that transfer or create a file/symlink/hardlink.
      keep = 0;
      if (first == ">" || first == "<") keep = 1;   # file transfer
      else if (first == "c" && second == "L") keep = 1;  # create symlink
      else if (first == "h") keep = 1;              # hard link
      if (!keep) next;
      # Rebuild path (everything after the flag token).
      $1 = "";
      sub(/^ /, "");
      # Strip trailing slash just in case (should only appear on dirs, which
      # we already skipped, but be defensive).
      sub(/\/$/, "");
      if (length($0) > 0) print $0;
    }'
}

# -----------------------------------------------------------------------------
# compute_ship_list <out_file>
#
# Compute the exact "would ship" set (from rsync --dry-run --itemize) into
# <out_file>. This is the SINGLE SOURCE OF TRUTH for the post-.publicignore
# ship set — both --dry-run and --inventory call this same function so they
# are provably computing the identical set, never two independent
# derivations that could drift apart.
#
# rsync --dry-run --itemize-changes uses the SAME flag set as the real run
# further below, so the emitted transfer list is exactly what the real run
# would transfer.
# -----------------------------------------------------------------------------

compute_ship_list() {
  local out_file="$1"
  rsync -a --delete --delete-excluded \
    --filter='protect .git/' \
    --exclude-from="$PUBLICIGNORE" \
    --exclude=".git" \
    --dry-run --itemize-changes --out-format='%i %n' \
    "$REPO_ROOT/" \
    "$WORKTREE_PATH/" \
    | _filter_itemize_changes \
    | LC_ALL=C sort -u > "$out_file"
}

# -----------------------------------------------------------------------------
# compute_full_ship_set <out_file>
#
# Compute the FULL resulting set of files that will exist post-sync and are
# not excluded by .publicignore — as opposed to compute_ship_list's transfer
# DIFF against whatever state the scratch worktree currently happens to be
# in. A file that is content-identical between $REPO_ROOT and $WORKTREE_PATH
# (e.g. project/logs/publish-history.json unchanged at `[]`) never appears
# in compute_ship_list's output, because rsync correctly determines there is
# nothing to transfer — but it IS, and will remain, present in the resulting
# ship set. check_publish_invariant needs to answer "is <path> in the ship
# set" against that full set, not the diff, or it false-positives on any
# unchanged-but-shipped file (T01).
#
# Implementation reuses the exact same rsync-to-empty-directory trick already
# established by compute_public_signature above, just pointed at $REPO_ROOT
# instead of $WORKTREE_PATH: rsync the private repo root into a throwaway
# empty directory with the SAME --exclude-from/--exclude filters every other
# set computation in this file uses, so every non-excluded file shows up as
# a "would create" entry regardless of the scratch worktree's prior state.
# Piped through the same _filter_itemize_changes parser as everything else.
#
# This is deliberately NOT a second, independent exclude-matching
# implementation (the kind of drift-between-two-derivations this file's
# comments warn against) — it is the identical rsync + .publicignore filter
# engine and the identical itemize parser, just run in "list everything
# non-excluded" mode (empty destination) instead of "list what changed"
# mode (real destination). It can never disagree with what a real sync
# would actually produce, because it uses the same inputs (REPO_ROOT,
# PUBLICIGNORE) that the real sync itself uses.
#
# Used ONLY to feed check_publish_invariant's presence checks. --dry-run and
# --inventory intentionally keep using compute_ship_list (the diff), since
# their documented behavior is to preview an actual transfer, not to answer
# a "will this exist" question.
# -----------------------------------------------------------------------------

compute_full_ship_set() {
  local out_file="$1"
  local empty_dir
  empty_dir="$(mktemp -d -t mirror-fullset.XXXXXX)"

  rsync -a \
    --exclude-from="$PUBLICIGNORE" \
    --exclude=".git" \
    --dry-run --itemize-changes --out-format='%i %n' \
    "$REPO_ROOT/" \
    "$empty_dir/" \
    | _filter_itemize_changes \
    | LC_ALL=C sort -u > "$out_file"

  rm -rf "$empty_dir"
}

# -----------------------------------------------------------------------------
# compute_public_signature <out_file>
#
# Compute the signature of unmirrored public-side work: every file that
# exists on the public worktree (at origin/<branch> tip, already fetched
# above), is NOT matched by .publicignore, and is absent from private.
# Blocklisted paths are deliberately excluded from this set — routine
# --delete-excluded purges are not the signal --force needs to surface,
# and mixing them in would drown genuine public-only work in noise (see
# task description: publish.json and the npm-publish workflow were both
# in this set and both were silently deleted by a --force run that had no
# way to show this before mutating).
#
# Reuses the same itemize-changes + _filter_itemize_changes trick as
# compute_ship_list, but pointed the other direction: source is the public
# worktree, dest is a throwaway empty directory, so every non-excluded
# public file shows up as a "would create" entry. That list is then
# filtered down to paths that don't exist under $REPO_ROOT.
# -----------------------------------------------------------------------------

compute_public_signature() {
  local out_file="$1"
  local not_blocklisted_file
  local empty_dir
  not_blocklisted_file="$(mktemp -t mirror-pubfiles.XXXXXX)"
  empty_dir="$(mktemp -d -t mirror-empty.XXXXXX)"

  rsync -a \
    --exclude-from="$PUBLICIGNORE" \
    --exclude=".git" \
    --dry-run --itemize-changes --out-format='%i %n' \
    "$WORKTREE_PATH/" \
    "$empty_dir/" \
    | _filter_itemize_changes \
    | LC_ALL=C sort -u > "$not_blocklisted_file"

  : > "$out_file"
  while IFS= read -r rel_path; do
    [ -n "$rel_path" ] || continue
    if [ ! -e "$REPO_ROOT/$rel_path" ]; then
      printf '%s\n' "$rel_path" >> "$out_file"
    fi
  done < "$not_blocklisted_file"

  rm -f "$not_blocklisted_file"
  rm -rf "$empty_dir"
}

# -----------------------------------------------------------------------------
# _read_json_field <file> <dotted.path>
#
# Read a (possibly nested, dot-separated) field out of a JSON file. Prints
# the value (as a string) or nothing if the field is absent/null — callers
# are responsible for treating an empty result as "missing" and failing
# closed if the field is required. Same jq-preferred / python3-fallback dual
# path already used by read_config_field above, so this script never gains
# a hard dependency on either tool alone.
# -----------------------------------------------------------------------------

_read_json_field() {
  local file="$1" dotted="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${dotted} // empty" "$file" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$dotted" <<'PY'
import json, sys
path_file, dotted = sys.argv[1], sys.argv[2]
with open(path_file) as fh:
    data = json.load(fh)
cur = data
for part in dotted.split('.'):
    if not isinstance(cur, dict) or part not in cur:
        cur = None
        break
    cur = cur[part]
sys.stdout.write('' if cur is None else str(cur))
PY
  else
    die "neither jq nor python3 available to parse $file"
  fi
}

# -----------------------------------------------------------------------------
# _publish_targets_tsv <publish_json_file>
#
# Emit one TSV row per publish.json target: name, type, npm.package_name,
# workflow_path (each empty-string when absent on that target). Used by
# check_publish_invariant to walk every target without re-deriving JSON
# parsing logic per field. Same jq/python3 dual path as _read_json_field.
# -----------------------------------------------------------------------------

_publish_targets_tsv() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.targets // [])[] | [(.name // ""), (.type // ""), (.npm.package_name // ""), (.workflow_path // "")] | @tsv' "$file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for t in (data.get('targets') or []):
    npm = t.get('npm') or {}
    print('\t'.join([
        t.get('name') or '',
        t.get('type') or '',
        npm.get('package_name') or '',
        t.get('workflow_path') or '',
    ]))
PY
  else
    die "neither jq nor python3 available to parse $file"
  fi
}

# -----------------------------------------------------------------------------
# _publicignore_rule_for <rel_path>
#
# Best-effort attribution: does any line in .publicignore look like it would
# block <rel_path>? Walks the file doing gitignore-ish matching (directory
# prefix for trailing-"/" lines, case-glob against the full relative path and
# the basename for everything else), skipping comments, blank lines, and
# "+"-prefixed include lines (which never block anything).
#
# This is a diagnostic aid ONLY — used to make a check_publish_invariant
# failure message more actionable — never the pass/fail signal itself (that
# always comes from whether the path is a line in compute_ship_list's real
# output). A missed or wrong attribution here cannot cause a false pass or
# false fail of the actual invariant.
#
# Prints the matching .publicignore line and returns 0 on a match; returns 1
# with no output if nothing matched.
# -----------------------------------------------------------------------------

_publicignore_rule_for() {
  local rel_path="$1" line pattern base dirpat
  base="$(basename "$rel_path")"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*|'+'*) continue ;;
    esac
    pattern="$line"
    case "$pattern" in
      '- '*) pattern="${pattern#- }" ;;
    esac
    [ -n "$pattern" ] || continue
    case "$pattern" in
      */)
        dirpat="${pattern%/}"
        case "$rel_path" in
          "$dirpat"/*)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        ;;
      *)
        case "$rel_path" in
          $pattern)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        case "$base" in
          $pattern)
            printf '%s\n' "$line"
            return 0
            ;;
        esac
        ;;
    esac
  done < "$PUBLICIGNORE"
  return 1
}

# -----------------------------------------------------------------------------
# check_publish_invariant <ship_list_file>
#
# Pre-push invariant (T04): publishing runs from the PUBLIC repo, so the
# mirror is the only path by which publish.json (and what it points at)
# reaches the place it executes. This fails the push closed, before any
# rsync write/commit/push, when what's about to ship would break the
# publish contract:
#
#   - package.json .name must equal every publish.json target's
#     .npm.package_name (checked per-target, so multiple npm/npm-ci targets
#     in the future are each verified independently).
#   - Every npm-ci target's .workflow_path (or the schema default,
#     .github/workflows/npm-publish.yml, when the target omits it) must be
#     present in the ship set.
#   - publish.json's .defaults.history_file must be present in the ship set.
#
# <ship_list_file> MUST be produced by compute_full_ship_set (T01) — the
# full resulting set, not compute_ship_list's transfer diff — since a
# content-identical-but-shipped file (e.g. an unchanged publish-history.json)
# would otherwise false-positive as "missing". This function never
# re-derives the ship set itself, so it can never drift from what the same
# rsync + .publicignore filter engine would actually produce.
#
# Absence of publish.json at the repo root is a clean no-op (return 0): not
# every mirrored repo carries an npm-ci publish target, and there is nothing
# to enforce without one. A PRESENT-but-broken publish.json (unreadable,
# missing .defaults.history_file, etc.) still fails closed, since that is
# exactly the kind of silently-shipped inconsistency this check exists to
# catch.
# -----------------------------------------------------------------------------

check_publish_invariant() {
  local ship_list_file="$1"
  local publish_json="$REPO_ROOT/publish.json"
  local package_json="$REPO_ROOT/package.json"

  if [ ! -f "$publish_json" ]; then
    log "publish-invariant: no publish.json at repo root — nothing to check"
    return 0
  fi

  [ -f "$package_json" ] || die "publish-invariant: publish.json exists at $publish_json but package.json is missing at $package_json"

  local pkg_name
  pkg_name="$(_read_json_field "$package_json" name)"
  [ -n "$pkg_name" ] || die "publish-invariant: package.json is missing a top-level .name field"

  local history_file
  history_file="$(_read_json_field "$publish_json" defaults.history_file)"
  [ -n "$history_file" ] || die "publish-invariant: publish.json is missing .defaults.history_file"

  if ! grep -Fxq "$history_file" "$ship_list_file"; then
    local rule
    rule="$(_publicignore_rule_for "$history_file")" || rule=""
    if [ -n "$rule" ]; then
      die "publish-invariant: publish.json .defaults.history_file ('$history_file') is not in the computed ship set — matched .publicignore rule: $rule"
    else
      die "publish-invariant: publish.json .defaults.history_file ('$history_file') is not in the computed ship set (no matching .publicignore rule found — confirm the file exists in the private repo)"
    fi
  fi

  local targets_tsv
  targets_tsv="$(_publish_targets_tsv "$publish_json")" || die "publish-invariant: could not read publish.json .targets"

  local target_name target_type target_pkg_name target_workflow_path
  while IFS=$'\t' read -r target_name target_type target_pkg_name target_workflow_path; do
    [ -n "$target_name" ] || continue

    if [ -n "$target_pkg_name" ] && [ "$target_pkg_name" != "$pkg_name" ]; then
      die "publish-invariant: package.json .name ('$pkg_name') disagrees with publish.json target '$target_name' .npm.package_name ('$target_pkg_name')"
    fi

    if [ "$target_type" = "npm-ci" ]; then
      local workflow_path="$target_workflow_path"
      [ -n "$workflow_path" ] || workflow_path=".github/workflows/npm-publish.yml"
      if ! grep -Fxq "$workflow_path" "$ship_list_file"; then
        local rule
        rule="$(_publicignore_rule_for "$workflow_path")" || rule=""
        if [ -n "$rule" ]; then
          die "publish-invariant: publish.json target '$target_name' .workflow_path ('$workflow_path') is not in the computed ship set — matched .publicignore rule: $rule"
        else
          die "publish-invariant: publish.json target '$target_name' .workflow_path ('$workflow_path') is not in the computed ship set (no matching .publicignore rule found — confirm the file exists in the private repo)"
        fi
      fi
    fi
  done <<EOF
$targets_tsv
EOF

  log "publish-invariant: package.json name agrees with publish.json; workflow_path + history_file present in ship set — OK"
}

# -----------------------------------------------------------------------------
# _run_force_confirmation_and_rescue_tag <marker_sha_or_empty>
#
# Shared --force flow: T03's enumeration + confirmation and T05's pre-force
# rescue tag, factored out so the two branches of the safety check below
# that can reach --force (a stale/diverged marker — T03/T05's original
# case — and a missing marker against a non-empty public repo — T06's new
# case) call the exact same implementation instead of two copies that could
# drift apart. <marker_sha_or_empty> is the known last-mirror-sync SHA, or
# an empty string when no marker exists at all (T06's case), in which case
# the "what's about to be overwritten" section prints the full public
# branch history instead of a marker..remote range, since there is no
# known-safe point left to diff from — the marker itself is what's missing.
#
# Reads/writes the caller's REMOTE_HEAD, FORCE, YES, DEFAULT_BRANCH,
# WORKTREE_PATH globals (all already set by the time the safety check
# runs). Sets RESCUE_TAG as a side effect (declared at top-level, `set -u`
# safe). Dies (no further mutation) on declined confirmation or a failed
# rescue-tag push, identically to the pre-T06 behavior.
# -----------------------------------------------------------------------------

_run_force_confirmation_and_rescue_tag() {
  local marker_sha="$1"

  if [ -n "$marker_sha" ]; then
    local commit_count
    commit_count="$(git -C "$WORKTREE_PATH" rev-list --count "$marker_sha..$REMOTE_HEAD")"
    printf '\n'
    printf '=== Divergent commits on public (%s..%s), %s commit(s) ===\n' \
      "${marker_sha:0:12}" "${REMOTE_HEAD:0:12}" "$commit_count"
    git -C "$WORKTREE_PATH" log --oneline "$marker_sha..$REMOTE_HEAD"
  else
    local commit_count
    commit_count="$(git -C "$WORKTREE_PATH" rev-list --count "$REMOTE_HEAD")"
    printf '\n'
    printf '=== No last-mirror-sync marker found — full history on public %s (%s commit(s)) ===\n' \
      "${REMOTE_HEAD:0:12}" "$commit_count"
    git -C "$WORKTREE_PATH" log --oneline "$REMOTE_HEAD"
  fi

  local signature_file signature_count
  signature_file="$(mktemp -t mirror-signature.XXXXXX)"
  compute_public_signature "$signature_file"
  signature_count="$(wc -l < "$signature_file" | tr -d ' ')"

  printf '\n'
  printf '=== Public-only files NOT in .publicignore and absent from private (%s) ===\n' "$signature_count"
  if [ "$signature_count" -eq 0 ]; then
    printf '  (none — nothing outside routine .publicignore purges will be lost)\n'
  else
    cat "$signature_file"
    printf '\nTHESE %s FILE(S) WILL BE DELETED if you proceed — they exist only on public and are not blocklisted.\n' "$signature_count"
  fi
  rm -f "$signature_file"
  printf '\n'

  if [ "$YES" -eq 1 ]; then
    log "explicit --yes approval provided; skipping interactive confirmation"
  elif [ -t 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf 'Type "destroy" to confirm --force will overwrite %s and delete the file(s) listed above: ' "$DEFAULT_BRANCH" > /dev/tty
    local confirm_input
    confirm_input=""
    read -r confirm_input < /dev/tty || confirm_input=""
    if [ "$confirm_input" != "destroy" ]; then
      die "confirmation declined — aborting --force with no further mutation (no rsync overwrite, no commit, no push)"
    fi
    log "confirmed interactively — proceeding with --force"
  else
    die "--force requires interactive confirmation; re-run with --yes for non-interactive/explicit approval (no mutation performed)"
  fi

  # ---------------------------------------------------------------------
  # Pre-force rescue tag (T05)
  #
  # Confirmation has just succeeded, so an overwrite is about to happen.
  # Push a lightweight tag at the pre-overwrite public tip (REMOTE_HEAD)
  # to the remote itself before any rsync overwrite/commit/push, so the
  # about-to-be-discarded state is recoverable independent of this
  # scratch clone — .mirror-worktrees/ is gitignored AND blocklisted, and
  # the 2026-08-28 incident's seven commits were only recoverable because
  # that scratch clone happened to still hold the objects. A failed tag
  # push aborts the run outright: never overwrite without a remote
  # recovery point.
  #
  # Naming is collision-safe when the same tip is force-overwritten more
  # than once: probe the remote for the base name first, and if it's
  # already taken, walk numeric suffixes (-2, -3, ...) until an unused
  # name is found, rather than assuming the base name is free.
  # ---------------------------------------------------------------------
  RESCUE_TAG_BASE="pre-force-${REMOTE_HEAD:0:12}"
  RESCUE_TAG="$RESCUE_TAG_BASE"
  local rescue_tag_suffix=2
  while git -C "$WORKTREE_PATH" ls-remote --exit-code --tags origin "refs/tags/$RESCUE_TAG" >/dev/null 2>&1; do
    RESCUE_TAG="${RESCUE_TAG_BASE}-${rescue_tag_suffix}"
    rescue_tag_suffix=$((rescue_tag_suffix + 1))
  done

  log "pushing pre-force rescue tag $RESCUE_TAG -> origin (pre-overwrite tip $REMOTE_HEAD)"
  git -C "$WORKTREE_PATH" tag -f "$RESCUE_TAG" "$REMOTE_HEAD" >/dev/null
  if ! git -C "$WORKTREE_PATH" push origin "refs/tags/$RESCUE_TAG"; then
    local rescue_tag_attempted="$RESCUE_TAG"
    git -C "$WORKTREE_PATH" tag -d "$RESCUE_TAG" >/dev/null 2>&1 || true
    RESCUE_TAG=""
    die "failed to push rescue tag $rescue_tag_attempted to origin — aborting --force with no further mutation (no rsync overwrite, no commit, no push). The pre-overwrite tip ($REMOTE_HEAD) has no remote recovery point; do not retry --force until the tag push can succeed."
  fi
  log "rescue tag $RESCUE_TAG pushed — pre-overwrite tip ($REMOTE_HEAD) is now recoverable from the remote independent of this scratch clone"
}

# -----------------------------------------------------------------------------
# _json_canonical_sans_version <file> <package|lockfile>
#
# Prints a stable (sorted-key) JSON serialization of <file> with its version
# field(s) removed: `.version` for "package"; `.version` and
# `.packages[""].version` for "lockfile" (package-lock.json's own top-level
# version plus npm v7+'s root-package entry, per T02's Acceptance Criteria).
# Two revisions of the same file that produce IDENTICAL output here differ,
# if at all, ONLY in those version field(s) — this is the field-level half
# of the version-only divergence check (_detect_version_only_divergence
# below is the file-level half). jq-preferred / python3-fallback, matching
# every other JSON helper in this file.
# -----------------------------------------------------------------------------

_json_canonical_sans_version() {
  local file="$1" kind="$2"
  if command -v jq >/dev/null 2>&1; then
    case "$kind" in
      package)
        jq -S 'del(.version)' "$file"
        ;;
      lockfile)
        jq -S 'del(.version) | (if (.packages? // {} | has("")) then .packages[""] |= del(.version) else . end)' "$file"
        ;;
      *)
        die "_json_canonical_sans_version: unknown kind '$kind'"
        ;;
    esac
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$kind" <<'PY'
import json, sys
file_path, kind = sys.argv[1], sys.argv[2]
with open(file_path) as fh:
    data = json.load(fh)
data.pop('version', None)
if kind == 'lockfile':
    pkgs = data.get('packages')
    if isinstance(pkgs, dict) and '' in pkgs and isinstance(pkgs[''], dict):
        pkgs[''].pop('version', None)
sys.stdout.write(json.dumps(data, sort_keys=True))
PY
  else
    die "neither jq nor python3 available to parse $file"
  fi
}

# -----------------------------------------------------------------------------
# _detect_version_only_divergence <marker_sha> <remote_head>
#
# Answers whether the full file-level diff between <marker_sha> and
# <remote_head> (both resolved inside the scratch worktree, which already
# has <remote_head> fetched) is "version-only" per T02's narrow definition:
#
#   - The set of changed files across the whole range is exactly a subset
#     of {package.json, package-lock.json} — any other file touched
#     disqualifies it.
#   - Within each changed file, the only changed value is a version field
#     (see _json_canonical_sans_version above) — any other field change
#     disqualifies it.
#   - An EMPTY file-level diff (marker and remote trees are identical)
#     counts as version-only too, trivially — the degenerate "private
#     already matches" case.
#
# Uses `git diff --name-only <a> <b>` — a direct tree-to-tree comparison,
# not a per-commit walk — so it answers "what actually differs between
# these two points" regardless of how many commits separate them or
# whether any individual commit is a no-op.
#
# On success (return 0), sets VERSION_ONLY_DETECTED_VERSION to the version
# read from package.json at <remote_head> (via a temp checkout of that one
# blob + the existing _read_json_field helper — no new JSON parsing).
# Returns 1 (leaving VERSION_ONLY_DETECTED_VERSION unset/empty) the instant
# any disqualifying condition is found.
# -----------------------------------------------------------------------------

_detect_version_only_divergence() {
  local marker_sha="$1" remote_head="$2"
  local changed_files

  # Read the remote-tip version unconditionally — needed both for a
  # positive detection's return value and to fail safe (return 1) if
  # package.json is somehow unreadable at remote_head.
  local remote_pkg_tmp
  remote_pkg_tmp="$(mktemp -t mirror-remote-pkg.XXXXXX)"
  if ! git -C "$WORKTREE_PATH" show "$remote_head:package.json" > "$remote_pkg_tmp" 2>/dev/null; then
    rm -f "$remote_pkg_tmp"
    return 1
  fi
  VERSION_ONLY_DETECTED_VERSION="$(_read_json_field "$remote_pkg_tmp" version)"
  rm -f "$remote_pkg_tmp"
  if [ -z "$VERSION_ONLY_DETECTED_VERSION" ]; then
    VERSION_ONLY_DETECTED_VERSION=""
    return 1
  fi

  changed_files="$(git -C "$WORKTREE_PATH" diff --name-only "$marker_sha" "$remote_head")"

  if [ -z "$changed_files" ]; then
    # Degenerate case: marker and remote trees are identical. Trivially
    # version-only (nothing to reconcile).
    return 0
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      package.json|package-lock.json) ;;
      *)
        VERSION_ONLY_DETECTED_VERSION=""
        return 1
        ;;
    esac
  done <<EOF
$changed_files
EOF

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local kind marker_tmp remote_tmp marker_canon remote_canon
    case "$f" in
      package.json)      kind="package" ;;
      package-lock.json)  kind="lockfile" ;;
    esac

    marker_tmp="$(mktemp -t mirror-marker-json.XXXXXX)"
    remote_tmp="$(mktemp -t mirror-remote-json.XXXXXX)"

    if ! git -C "$WORKTREE_PATH" show "$marker_sha:$f" > "$marker_tmp" 2>/dev/null; then
      # File didn't exist at the marker at all — not a pure version-field
      # change (a whole-file addition/removal is out of scope for T02).
      rm -f "$marker_tmp" "$remote_tmp"
      VERSION_ONLY_DETECTED_VERSION=""
      return 1
    fi
    if ! git -C "$WORKTREE_PATH" show "$remote_head:$f" > "$remote_tmp" 2>/dev/null; then
      rm -f "$marker_tmp" "$remote_tmp"
      VERSION_ONLY_DETECTED_VERSION=""
      return 1
    fi

    marker_canon="$(_json_canonical_sans_version "$marker_tmp" "$kind")"
    remote_canon="$(_json_canonical_sans_version "$remote_tmp" "$kind")"
    rm -f "$marker_tmp" "$remote_tmp"

    if [ "$marker_canon" != "$remote_canon" ]; then
      VERSION_ONLY_DETECTED_VERSION=""
      return 1
    fi
  done <<EOF
$changed_files
EOF

  return 0
}

# -----------------------------------------------------------------------------
# _apply_version_to_private <version>
#
# Writes <version> into $REPO_ROOT/package.json's .version and, if the file
# exists, $REPO_ROOT/package-lock.json's .version + .packages[""].version —
# the identical field scope _detect_version_only_divergence checks above,
# nothing else in either file. jq-preferred (verified to produce a minimal
# single-line diff per field, preserving existing formatting exactly when
# the value is unchanged) / python3-fallback.
#
# Returns 0 always; callers check for an actual working-tree diff themselves
# (via `git status`/`git diff`) to decide whether a reconciliation commit is
# needed — this function does not know or care whether it changed anything.
# -----------------------------------------------------------------------------

_apply_version_to_private() {
  local version="$1"
  local pkg="$REPO_ROOT/package.json"
  local lock="$REPO_ROOT/package-lock.json"

  [ -f "$pkg" ] || die "_apply_version_to_private: package.json not found at $pkg"

  if command -v jq >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp -t mirror-pkg-write.XXXXXX)"
    jq --arg v "$version" '.version = $v' "$pkg" > "$tmp" && mv "$tmp" "$pkg"
    if [ -f "$lock" ]; then
      tmp="$(mktemp -t mirror-lock-write.XXXXXX)"
      jq --arg v "$version" '.version = $v | (if (.packages? // {} | has("")) then .packages[""].version = $v else . end)' "$lock" > "$tmp" && mv "$tmp" "$lock"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$pkg" "$lock" "$version" <<'PY'
import json, os, sys
pkg_path, lock_path, version = sys.argv[1], sys.argv[2], sys.argv[3]

with open(pkg_path) as fh:
    pkg = json.load(fh)
pkg['version'] = version
with open(pkg_path, 'w') as fh:
    json.dump(pkg, fh, indent=2)
    fh.write('\n')

if os.path.exists(lock_path):
    with open(lock_path) as fh:
        lock = json.load(fh)
    lock['version'] = version
    pkgs = lock.get('packages')
    if isinstance(pkgs, dict) and '' in pkgs and isinstance(pkgs[''], dict):
        pkgs['']['version'] = version
    with open(lock_path, 'w') as fh:
        json.dump(lock, fh, indent=2)
        fh.write('\n')
PY
  else
    die "neither jq nor python3 available to write $pkg"
  fi
}

# -----------------------------------------------------------------------------
# _reconcile_version_only_divergence <marker_sha> <remote_head> <version>
#
# Applies a detected version-only divergence (T02): writes <version> into
# private via _apply_version_to_private, and — only if that produced an
# actual working-tree diff (the degenerate "private already matches" case
# from _detect_version_only_divergence makes no commit) — commits it to
# private's CURRENT branch (whatever branch is checked out in $REPO_ROOT at
# runtime; this script never switches branches) with a message identifying
# it as an auto-reconciliation and a `Public-Commits:` trailer naming the
# marker..remote commit(s) that introduced the drift.
#
# Sets VERSION_ONLY_RECONCILED_SHA to the new commit's SHA (or leaves it
# empty if no commit was needed) so the final summary block can report it.
# Does NOT push, tag, or otherwise touch the public side — the caller falls
# through into the normal push path immediately afterward, identically to
# the "marker matches" case.
# -----------------------------------------------------------------------------

_reconcile_version_only_divergence() {
  local marker_sha="$1" remote_head="$2" version="$3"

  _apply_version_to_private "$version"

  if git -C "$REPO_ROOT" diff --quiet -- package.json package-lock.json 2>/dev/null \
     && git -C "$REPO_ROOT" diff --cached --quiet -- package.json package-lock.json 2>/dev/null; then
    log "auto-reconcile: private already matches public's version ($version) — no commit needed"
    VERSION_ONLY_RECONCILED_SHA=""
    return 0
  fi

  local public_commits short_remote
  public_commits="$(git -C "$WORKTREE_PATH" log --format='%h' "$marker_sha..$remote_head" | tr '\n' ',' | sed 's/,$//')"
  short_remote="${remote_head:0:12}"

  git -C "$REPO_ROOT" add -- package.json package-lock.json
  git -C "$REPO_ROOT" commit \
    -m "chore(mirror-public): auto-reconcile version drift to $version from public $short_remote" \
    -m "Public-Commits: $public_commits" >/dev/null
  VERSION_ONLY_RECONCILED_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  log "auto-reconcile: committed version $version to private ($VERSION_ONLY_RECONCILED_SHA), sourced from public commit(s) $public_commits"
}

# -----------------------------------------------------------------------------
# Safety check: last-mirror-sync tag vs origin/<branch>
#
# Four cases (T06 expands this from three):
#   1. No marker, no commits on origin/<branch> yet -> genuine first-run
#      bootstrap against a brand-new public repo. Proceed with no ceremony.
#   2. No marker, but origin/<branch> already has commits -> T06's actual
#      fix. The last-mirror-sync tag lives ONLY inside this scratch clone
#      (.mirror-worktrees/, gitignored AND blocklisted) and is never
#      pushed, so deleting that directory while tidying — an easy mistake,
#      since it looks disposable — silently discarded the marker and used
#      to make the script treat an established public repo as a fresh
#      target, with no --force and no warning. Abort by default; --force
#      remains the override, reusing the identical enumeration +
#      confirmation + rescue-tag flow as case 4 below (no known marker to
#      diff from, so the "what's at risk" section shows full history
#      instead of a range).
#   3. Marker matches origin/<branch> -> safe to proceed, unchanged.
#   4. Marker present but origin/<branch> has moved past it -> unchanged
#      T03/T05 stale-marker abort/--force flow.
# -----------------------------------------------------------------------------

MARKER_SHA="$(git -C "$WORKTREE_PATH" rev-parse -q --verify refs/tags/last-mirror-sync 2>/dev/null || true)"
if [ "$REMOTE_BRANCH_EXISTS" -eq 1 ]; then
  REMOTE_HEAD="$(git -C "$WORKTREE_PATH" rev-parse "origin/$DEFAULT_BRANCH")"
else
  REMOTE_HEAD=""
fi

if [ -z "$MARKER_SHA" ] && [ -z "$REMOTE_HEAD" ]; then
  log "no last-mirror-sync tag and no commits on origin/$DEFAULT_BRANCH yet — genuine first-run bootstrap, proceeding"
elif [ -z "$MARKER_SHA" ]; then
  if [ "$FORCE" -eq 1 ]; then
    log "WARNING: no last-mirror-sync marker found, but origin/$DEFAULT_BRANCH ($REMOTE_HEAD) already has commits — proceeding due to --force (scratch clone likely wiped)"
    _run_force_confirmation_and_rescue_tag ""
  else
    die "no last-mirror-sync marker found, but origin/$DEFAULT_BRANCH already has commits (current public tip: $REMOTE_HEAD). This usually means the scratch clone (.mirror-worktrees/) was wiped, which erases the only copy of the marker and would otherwise let this run silently overwrite public-side work with no divergence check at all. Re-run with --force to overwrite anyway (a recovery point is pushed to the remote before any mutation)."
  fi
elif [ "$MARKER_SHA" = "$REMOTE_HEAD" ]; then
  log "last-mirror-sync matches origin/$DEFAULT_BRANCH — safe to proceed"
else
  # T02 (E28_S05): before falling into the --force/abort path, check
  # whether the ENTIRE marker..remote divergence is version-only (see
  # _detect_version_only_divergence above for the exact definition). This
  # check runs regardless of whether --force was also passed — a provably
  # safe, auto-reconcilable divergence never needs the destructive-by-
  # default --force/destroy flow, and running it anyway would defeat the
  # point of narrowing this to a safe case.
  if _detect_version_only_divergence "$MARKER_SHA" "$REMOTE_HEAD"; then
    log "origin/$DEFAULT_BRANCH ($REMOTE_HEAD) has moved past last-mirror-sync ($MARKER_SHA), but the divergence is version-only (package.json/package-lock.json .version field(s) only, detected version $VERSION_ONLY_DETECTED_VERSION) — auto-reconciling into private, no --force needed"
    _reconcile_version_only_divergence "$MARKER_SHA" "$REMOTE_HEAD" "$VERSION_ONLY_DETECTED_VERSION"
  elif [ "$FORCE" -eq 1 ]; then
    log "WARNING: origin/$DEFAULT_BRANCH ($REMOTE_HEAD) has moved past last-mirror-sync ($MARKER_SHA); proceeding due to --force"
    _run_force_confirmation_and_rescue_tag "$MARKER_SHA"
  else
    die "origin/$DEFAULT_BRANCH ($REMOTE_HEAD) has moved past last-mirror-sync ($MARKER_SHA). The public repo has commits the mirror did not create. Re-run with --force to overwrite."
  fi
fi

# -----------------------------------------------------------------------------
# --dry-run: full read-only preview
#
# Compute + print the exact "would ship" set (via compute_ship_list) and the
# "would be blocked" set (git-tracked/untracked candidates minus the ship
# set). Zero rsync writes, zero commits, zero pushes.
# -----------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: computing ship + blocked sets (no rsync write, no commit, no push)"

  SHIP_LIST_FILE="$(mktemp -t mirror-ship.XXXXXX)"
  CANDIDATE_LIST_FILE="$(mktemp -t mirror-candidates.XXXXXX)"
  BLOCKED_LIST_FILE="$(mktemp -t mirror-blocked.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$SHIP_LIST_FILE' '$CANDIDATE_LIST_FILE' '$BLOCKED_LIST_FILE'" EXIT

  # 1. Ship list.
  compute_ship_list "$SHIP_LIST_FILE"

  # 2. Candidate list — every tracked file plus every untracked-not-gitignored
  # file under the private repo root. This is the honest "what the maintainer
  # thinks of as the repo" set.
  git -C "$REPO_ROOT" ls-files -co --exclude-standard \
    | LC_ALL=C sort -u > "$CANDIDATE_LIST_FILE"

  # 3. Blocked = candidates \ shipped.
  LC_ALL=C comm -23 "$CANDIDATE_LIST_FILE" "$SHIP_LIST_FILE" > "$BLOCKED_LIST_FILE"

  SHIP_COUNT="$(wc -l < "$SHIP_LIST_FILE" | tr -d ' ')"
  BLOCKED_COUNT="$(wc -l < "$BLOCKED_LIST_FILE" | tr -d ' ')"

  printf '\n'
  printf '=== Files that would ship (%s) ===\n' "$SHIP_COUNT"
  if [ "$SHIP_COUNT" -eq 0 ]; then
    printf '  (none — public tree already matches private, post-blocklist)\n'
  else
    cat "$SHIP_LIST_FILE"
  fi

  printf '\n'
  printf '=== Files that would be blocked (%s) ===\n' "$BLOCKED_COUNT"
  if [ "$BLOCKED_COUNT" -eq 0 ]; then
    printf '  (none — .publicignore matched nothing under this repo)\n'
  else
    cat "$BLOCKED_LIST_FILE"
  fi

  printf '\n'
  printf '================ mirror-public dry-run summary ================\n'
  printf 'would ship    : %s files\n' "$SHIP_COUNT"
  printf 'would block   : %s files\n' "$BLOCKED_COUNT"
  printf 'public URL    : %s\n' "$PUBLIC_URL"
  printf 'remote branch : %s\n' "$DEFAULT_BRANCH"
  printf 'dry run — no push, no commit, no remote mutation\n'
  printf '===============================================================\n'

  exit 0
fi

# -----------------------------------------------------------------------------
# --inventory: categorized shipped-feature preview
#
# Computes the IDENTICAL "would ship" set that --dry-run computes (same
# compute_ship_list function — single source of truth), groups it by
# top-level feature-type category, and renders the report through
# skills/j-mirror-public/assets/inventory-template.md. Zero rsync writes,
# zero commits, zero pushes — same safety class as --dry-run.
# -----------------------------------------------------------------------------

if [ "$INVENTORY" -eq 1 ]; then
  log "inventory: computing categorized ship set (no rsync write, no commit, no push)"

  SHIP_LIST_FILE="$(mktemp -t mirror-ship.XXXXXX)"
  REMAINING_FILE="$(mktemp -t mirror-remaining.XXXXXX)"
  CAT_FILE="$(mktemp -t mirror-cat.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$SHIP_LIST_FILE' '$REMAINING_FILE' '$CAT_FILE'" EXIT

  compute_ship_list "$SHIP_LIST_FILE"
  cp "$SHIP_LIST_FILE" "$REMAINING_FILE"

  # Fixed category order. Each named category is matched against whatever is
  # still unmatched ($REMAINING_FILE) by an extended-regex alternation of
  # every path prefix that represents that feature type; anything left after
  # all named prefixes are peeled off falls into "Other". This order/peel
  # approach guarantees every shipped file is counted in exactly one category
  # (no double-counting, nothing silently dropped).
  #
  # Each category matches its canonical root dir (e.g. "skills/") AND its
  # self-sync mirror copies under .claude/ and .agents/ (e.g.
  # ".claude/skills/", ".agents/skills/" — see skills/self-sync). Those
  # mirrors are generated, file-for-file copies of the same feature-type
  # content (confirmed against this repo's actual ship set: without this
  # folding, .claude/+.agents/ alone contribute ~370 files that would
  # otherwise all land undifferentiated in "Other", dwarfing every named
  # category — exactly the "high-volume area unhelpfully lumped into Other"
  # this categorization is meant to avoid).
  CATEGORY_KEYS=(SKILLS MCP AGENTS HOOKS SCRIPTS TEMPLATES DOCS OTHER)
  CATEGORY_NAMES=(Skills MCP Agents Hooks Scripts Templates Docs Other)
  CATEGORY_PATTERNS=(
    '^(skills/|\.claude/skills/|\.agents/skills/)'
    '^(mcp/|\.claude/mcp/|\.agents/mcp/)'
    '^(agents/|\.claude/agents/|\.agents/agents/)'
    '^(hooks/|\.claude/hooks/|\.agents/hooks/)'
    '^(scripts/|\.claude/scripts/|\.agents/scripts/)'
    '^(templates/|\.claude/templates/|\.agents/templates/)'
    '^(docs/|\.claude/docs/|\.agents/docs/)'
    ''
  )

  SECTION_TEMPLATE="$(awk '/<!-- SECTION_TEMPLATE_START -->/{flag=1;next}/<!-- SECTION_TEMPLATE_END -->/{flag=0}flag' "$INVENTORY_TEMPLATE")"
  SUMMARY_TEMPLATE="$(awk '/<!-- SUMMARY_TEMPLATE_START -->/{flag=1;next}/<!-- SUMMARY_TEMPLATE_END -->/{flag=0}flag' "$INVENTORY_TEMPLATE")"

  RENDERED_SECTIONS=""
  GRAND_TOTAL=0
  declare -a CATEGORY_COUNTS

  for i in "${!CATEGORY_NAMES[@]}"; do
    name="${CATEGORY_NAMES[$i]}"
    pattern="${CATEGORY_PATTERNS[$i]}"

    if [ "$name" = "Other" ]; then
      # Whatever is left after every named pattern has been peeled off.
      cp "$REMAINING_FILE" "$CAT_FILE"
    else
      grep -E "$pattern" "$REMAINING_FILE" > "$CAT_FILE" || true
      grep -vE "$pattern" "$REMAINING_FILE" > "${REMAINING_FILE}.next" || true
      mv "${REMAINING_FILE}.next" "$REMAINING_FILE"
    fi

    count="$(wc -l < "$CAT_FILE" | tr -d ' ')"
    CATEGORY_COUNTS[$i]="$count"
    GRAND_TOTAL=$((GRAND_TOTAL + count))

    if [ "$count" -eq 0 ]; then
      files="  (none)"
    else
      files="$(cat "$CAT_FILE")"
    fi

    section="$SECTION_TEMPLATE"
    section="${section//\{\{CATEGORY_NAME\}\}/$name}"
    section="${section//\{\{CATEGORY_COUNT\}\}/$count}"
    section="${section//\{\{CATEGORY_FILES\}\}/$files}"

    RENDERED_SECTIONS="$RENDERED_SECTIONS
$section"
  done

  summary="$SUMMARY_TEMPLATE"
  for i in "${!CATEGORY_KEYS[@]}"; do
    key="${CATEGORY_KEYS[$i]}"
    summary="${summary//\{\{${key}_COUNT\}\}/${CATEGORY_COUNTS[$i]}}"
  done
  summary="${summary//\{\{GRAND_TOTAL\}\}/$GRAND_TOTAL}"
  summary="${summary//\{\{PUBLIC_URL\}\}/$PUBLIC_URL}"
  summary="${summary//\{\{DEFAULT_BRANCH\}\}/$DEFAULT_BRANCH}"

  printf '%s\n' "$RENDERED_SECTIONS"
  printf '\n%s\n' "$summary"

  exit 0
fi

# -----------------------------------------------------------------------------
# Publish-config invariant (T04) — runs on EVERY push path, forced or not.
#
# Both --dry-run and --inventory have already exited above, so only real
# push paths (plain and --force, which falls through to this same point
# after its enumeration/confirmation) ever reach here. Computes the FULL
# resulting ship set via compute_full_ship_set (T01) — not
# compute_ship_list's transfer diff, which --dry-run/--inventory use for
# their own preview reporting — and hands it to check_publish_invariant so
# a content-identical-but-shipped file (e.g. an unchanged
# publish-history.json) is correctly recognized as present instead of
# false-positively aborting. Aborts non-zero before any rsync write,
# commit, or push.
# -----------------------------------------------------------------------------

PUBLISH_INVARIANT_SHIP_FILE="$(mktemp -t mirror-publish-invariant.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$PUBLISH_INVARIANT_SHIP_FILE'" EXIT
compute_full_ship_set "$PUBLISH_INVARIANT_SHIP_FILE"
check_publish_invariant "$PUBLISH_INVARIANT_SHIP_FILE"
rm -f "$PUBLISH_INVARIANT_SHIP_FILE"
trap - EXIT

# -----------------------------------------------------------------------------
# rsync private root -> scratch worktree
# -----------------------------------------------------------------------------

log "rsync $REPO_ROOT/ -> $WORKTREE_PATH/ (excludes: .publicignore + .git)"
rsync -a --delete --delete-excluded \
  --filter='protect .git/' \
  --exclude-from="$PUBLICIGNORE" \
  --exclude=".git" \
  "$REPO_ROOT/" \
  "$WORKTREE_PATH/"

# -----------------------------------------------------------------------------
# Regenerate the shipped skill allow-list against the POST-BLOCKLIST tree
#
# lib/skill-allow-list.json (lib/generate-skill-allow-list.js) is generated
# by scanning a skills/ directory. Private's own committed copy is generated
# against private's skills/ — correct for private's own j: allow-list guard,
# but several of those skills (mirror-public, self-sync, train, strategy,
# convert, route) are private-only and excluded by .publicignore. Blindly
# rsync-copying private's file verbatim leaks those names into a file that
# ships in the npm tarball and no longer matches what the public package
# actually contains. Regenerate the artifact here, against the scratch
# worktree's OWN skills/ directory post-rsync/post-blocklist, so the shipped
# allow-list is always self-consistent with what's actually public — never a
# copy of private's internal one. Fixes a leak first caught and hand-fixed
# directly on the public repo (commit 1be60a4), then reintroduced by a
# --force mirror run that rsynced private's 43-skill copy back over it.
# -----------------------------------------------------------------------------

if [ -f "$REPO_ROOT/lib/generate-skill-allow-list.js" ] && [ -d "$WORKTREE_PATH/skills" ]; then
  node "$REPO_ROOT/lib/generate-skill-allow-list.js" \
    "$WORKTREE_PATH/skills" \
    "$WORKTREE_PATH/lib/skill-allow-list.json" >/dev/null
  log "regenerated lib/skill-allow-list.json against the public tree ($WORKTREE_PATH/skills)"
fi

# -----------------------------------------------------------------------------
# Stage + detect changes (idempotency)
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" add -A

if git -C "$WORKTREE_PATH" diff --cached --quiet; then
  # T02 (E28_S05): a version-only auto-reconciliation can land here with
  # nothing left to push (the reconciliation commit already made private's
  # content match what's at REMOTE_HEAD) — but the local last-mirror-sync
  # marker is still pointing at the OLD (pre-divergence) commit, since the
  # only place that tag normally advances is further down, past this early
  # exit. Left alone, the next run would re-detect the identical
  # already-resolved divergence forever. Advance the marker to REMOTE_HEAD
  # here so a version-only-reconciled run that happens to need no push
  # still satisfies "the marker tag advances normally on the resulting
  # successful push" (this task's AC) instead of getting stuck.
  if [ -n "$VERSION_ONLY_DETECTED_VERSION" ]; then
    git -C "$WORKTREE_PATH" tag -f last-mirror-sync "$REMOTE_HEAD" >/dev/null
    log "nothing to mirror — public tree already matches private (post-blocklist); advancing local last-mirror-sync marker to $REMOTE_HEAD since this run auto-reconciled version drift"
  else
    log "nothing to mirror — public tree already matches private (post-blocklist)"
  fi
  exit 0
fi

# -----------------------------------------------------------------------------
# Squash commit
# -----------------------------------------------------------------------------

PRIVATE_SHORT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
PRIVATE_FULL_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
UTC_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

COMMIT_SUBJECT="chore(mirror): sync from private at $PRIVATE_SHORT_SHA $UTC_TS"
COMMIT_TRAILER="Source-Commit: $PRIVATE_FULL_SHA"

# Ensure the scratch clone has a committer identity even in ephemeral CI/test.
if ! git -C "$WORKTREE_PATH" config user.email >/dev/null 2>&1; then
  git -C "$WORKTREE_PATH" config user.email "mirror-public@jenga.local"
fi
if ! git -C "$WORKTREE_PATH" config user.name >/dev/null 2>&1; then
  git -C "$WORKTREE_PATH" config user.name "jenga mirror-public"
fi

git -C "$WORKTREE_PATH" commit -m "$COMMIT_SUBJECT" -m "$COMMIT_TRAILER" >/dev/null

NEW_SHA="$(git -C "$WORKTREE_PATH" rev-parse HEAD)"

# -----------------------------------------------------------------------------
# Advance marker tag (LOCAL to scratch clone — never pushed)
# -----------------------------------------------------------------------------

git -C "$WORKTREE_PATH" tag -f last-mirror-sync HEAD >/dev/null

# -----------------------------------------------------------------------------
# Push
# -----------------------------------------------------------------------------

log "pushing $NEW_SHA -> origin/$DEFAULT_BRANCH"
git -C "$WORKTREE_PATH" push origin "$DEFAULT_BRANCH"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

FILES_CHANGED="$(git -C "$WORKTREE_PATH" diff-tree --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ')"

printf '\n'
printf '================ mirror-public summary ================\n'
printf 'files changed : %s\n' "$FILES_CHANGED"
printf 'new commit    : %s\n' "$NEW_SHA"
printf 'remote branch : %s\n' "$DEFAULT_BRANCH"
printf 'public URL    : %s\n' "$PUBLIC_URL"
if [ -n "$RESCUE_TAG" ]; then
  printf 'rescue tag    : %s (pre-overwrite tip, pushed to remote)\n' "$RESCUE_TAG"
fi
if [ -n "$VERSION_ONLY_DETECTED_VERSION" ]; then
  if [ -n "$VERSION_ONLY_RECONCILED_SHA" ]; then
    printf 'auto-reconcile: version %s pulled in from public, private commit %s\n' "$VERSION_ONLY_DETECTED_VERSION" "$VERSION_ONLY_RECONCILED_SHA"
  else
    printf 'auto-reconcile: version %s already matched private — no commit needed\n' "$VERSION_ONLY_DETECTED_VERSION"
  fi
fi
printf '=======================================================\n'

#!/usr/bin/env bash
set -euo pipefail

emit_error() {
  local branch="${1:-}"
  local code="$2"
  local message="$3"
  python3 - "$branch" "$code" "$message" <<'PY'
import json
import sys

branch, code, message = sys.argv[1:4]
payload = {
    "status": "error",
    "code": code,
    "message": message,
}
if branch:
    payload["branch"] = branch
print(json.dumps(payload, ensure_ascii=False))
PY
}

emit_local_branch_missing() {
  local branch="$1"
  local remote_exists="$2"
  python3 - "$branch" "$remote_exists" <<'PY'
import json
import sys

branch = sys.argv[1]
remote_exists = sys.argv[2].lower() == "true"
print(json.dumps({
    "status": "local_branch_missing",
    "branch": branch,
    "remote_exists": remote_exists,
    "message": "The requested branch does not exist locally."
}, ensure_ascii=False))
PY
}

emit_ok() {
  local branch="$1"
  local rebased_commits="$2"
  python3 - "$branch" "$rebased_commits" <<'PY'
import json
import sys

branch, rebased_commits = sys.argv[1], int(sys.argv[2])
print(json.dumps({
    "status": "ok",
    "branch": branch,
    "rebased_commits": rebased_commits,
}, ensure_ascii=False))
PY
}

emit_handled_later() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

print(json.dumps({
    "status": "handled_later",
    "file": sys.argv[1],
}, ensure_ascii=False))
PY
}

rebase_in_progress() {
  local git_dir
  git_dir="$(git rev-parse --git-dir)"
  [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]
}

annotate_conflicts() {
  local file="$1"
  local branch="$2"
  python3 - "$file" "$branch" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
branch = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
comment_block = [
    "# RECONCILE-ORIGIN CONFLICT:\n",
    f"# Local commits and origin/{branch} both changed the lines below in {path}.\n",
    "# Resolve the conflict when you are ready, then remove this note if it is no longer needed.\n",
]

result = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("<<<<<<< "):
        if len(result) >= len(comment_block) and result[-len(comment_block):] == comment_block:
            pass
        else:
            result.extend(comment_block)
    result.append(line)
    i += 1

path.write_text("".join(result), encoding="utf-8")
PY
}

build_conflict_report() {
  local branch="$1"
  shift
  python3 - "$branch" "$@" <<'PY'
import json
import sys
from pathlib import Path

branch = sys.argv[1]
files = sys.argv[2:]
conflicts = []

for file_path in files:
    path = Path(file_path)
    if not path.exists():
        continue

    lines = path.read_text(encoding="utf-8").splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("<<<<<<< "):
            i += 1
            origin_lines = []
            while i < len(lines) and lines[i] != "=======":
                origin_lines.append(lines[i])
                i += 1
            if i < len(lines) and lines[i] == "=======":
                i += 1
            local_lines = []
            while i < len(lines) and not lines[i].startswith(">>>>>>>"):
                local_lines.append(lines[i])
                i += 1
            while i < len(lines) and not lines[i].startswith(">>>>>>>"):
                i += 1
            if i < len(lines) and lines[i].startswith(">>>>>>>"):
                i += 1
            blocks.append(("\n".join(local_lines).strip(), "\n".join(origin_lines).strip()))
        else:
            i += 1

    if not blocks:
        continue

    local_text = "\n\n---\n\n".join(block[0] for block in blocks)
    origin_text = "\n\n---\n\n".join(block[1] for block in blocks)
    conflicts.append({
        "file": file_path,
        "local_section": local_text,
        "origin_section": origin_text,
        "description": f"Overlapping edits between local commits and origin/{branch} across {len(blocks)} conflict block(s).",
    })

print(json.dumps({
    "status": "conflict",
    "branch": branch,
    "conflicts": conflicts,
}, ensure_ascii=False))
PY
}

fetch_origin_branch() {
  local branch="$1"
  git fetch origin "refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1
}

ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    emit_error "$1" "uncommitted_changes" "Uncommitted changes detected. Stash or commit them before reconciling with origin."
    exit 1
  fi
}

ensure_branch_context() {
  local branch="$1"
  local create_tracking="$2"
  local current_branch
  current_branch="$(git branch --show-current)"

  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      if [[ "$create_tracking" == "true" ]]; then
        fetch_origin_branch "$branch" || {
          emit_error "$branch" "branch_not_found_on_origin" "Unable to fetch origin/$branch."
          exit 1
        }
        git checkout -b "$branch" --track "origin/$branch" >/dev/null 2>&1 || {
          emit_error "$branch" "checkout_failed" "Unable to create and check out local tracking branch $branch."
          exit 1
        }
      else
        emit_local_branch_missing "$branch" "true"
        exit 0
      fi
    else
      emit_local_branch_missing "$branch" "false"
      exit 0
    fi
  elif [[ "$current_branch" != "$branch" ]]; then
    git checkout "$branch" >/dev/null 2>&1 || {
      emit_error "$branch" "checkout_failed" "Unable to check out local branch $branch."
      exit 1
    }
  fi
}

run_standard_reconcile() {
  local branch="$1"
  fetch_origin_branch "$branch" || {
    emit_error "$branch" "branch_not_found_on_origin" "Branch origin/$branch was not found or could not be fetched."
    exit 1
  }

  local rebased_commits
  rebased_commits="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"

  if git rebase "origin/$branch" >/dev/null 2>&1; then
    emit_ok "$branch" "$rebased_commits"
    return 0
  fi

  local conflict_files
  conflict_files="$(git diff --name-only --diff-filter=U || true)"
  if [[ -n "$conflict_files" ]]; then
    local -a conflict_array=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && conflict_array+=("$line")
    done <<<"$conflict_files"
    local report
    report="$(build_conflict_report "$branch" "${conflict_array[@]}")"
    git rebase --abort >/dev/null 2>&1 || true
    printf '%s\n' "$report"
    return 0
  fi

  if rebase_in_progress; then
    git rebase --abort >/dev/null 2>&1 || true
  fi
  emit_error "$branch" "rebase_failed" "The rebase failed before conflict details could be collected."
  exit 1
}

run_handle_later() {
  local branch="$1"
  local target_file="$2"

  fetch_origin_branch "$branch" || {
    emit_error "$branch" "branch_not_found_on_origin" "Branch origin/$branch was not found or could not be fetched."
    exit 1
  }

  local rebased_commits
  rebased_commits="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"

  if git rebase "origin/$branch" >/dev/null 2>&1; then
    emit_ok "$branch" "$rebased_commits"
    return 0
  fi

  local conflict_files
  conflict_files="$(git diff --name-only --diff-filter=U || true)"
  if [[ -z "$conflict_files" ]]; then
    if rebase_in_progress; then
      git rebase --abort >/dev/null 2>&1 || true
    fi
    emit_error "$branch" "rebase_failed" "The rebase failed before the requested conflict could be handled."
    exit 1
  fi

  if ! printf '%s\n' "$conflict_files" | grep -Fxq "$target_file"; then
    local -a conflict_array=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && conflict_array+=("$line")
    done <<<"$conflict_files"
    local report
    report="$(build_conflict_report "$branch" "${conflict_array[@]}")"
    git rebase --abort >/dev/null 2>&1 || true
    printf '%s\n' "$report"
    exit 1
  fi

  while true; do
    annotate_conflicts "$target_file" "$branch"
    git add "$target_file"

    if GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
      emit_handled_later "$target_file"
      return 0
    fi

    conflict_files="$(git diff --name-only --diff-filter=U || true)"
    if [[ -z "$conflict_files" ]]; then
      emit_error "$branch" "rebase_continue_failed" "Rebase continuation failed after annotating $target_file."
      exit 1
    fi

    if printf '%s\n' "$conflict_files" | grep -Fxq "$target_file"; then
      continue
    fi

    emit_handled_later "$target_file"
    return 0
  done
}

branch_arg=""
handle_later_file=""
create_tracking="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handle-later)
      shift
      if [[ $# -eq 0 ]]; then
        emit_error "$branch_arg" "missing_handle_later_file" "The --handle-later flag requires a file path."
        exit 1
      fi
      handle_later_file="$1"
      ;;
    --create-tracking)
      create_tracking="true"
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: reconcile-origin.sh [<branch>] [--handle-later <file>] [--create-tracking]
USAGE
      exit 0
      ;;
    *)
      if [[ -n "$branch_arg" ]]; then
        emit_error "$branch_arg" "unexpected_argument" "Unexpected argument: $1"
        exit 1
      fi
      branch_arg="$1"
      ;;
  esac
  shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_error "$branch_arg" "not_a_git_repository" "This command must be run inside a git work tree."
  exit 1
fi

if rebase_in_progress; then
  emit_error "$branch_arg" "rebase_in_progress" "A rebase is already in progress. Resolve or abort it before running reconcile-origin."
  exit 1
fi

branch="${branch_arg:-$(git branch --show-current)}"
if [[ -z "$branch" ]]; then
  emit_error "$branch" "detached_head" "Unable to determine the current branch from a detached HEAD state."
  exit 1
fi

ensure_clean_worktree "$branch"
ensure_branch_context "$branch" "$create_tracking"

if [[ -n "$handle_later_file" ]]; then
  run_handle_later "$branch" "$handle_later_file"
else
  run_standard_reconcile "$branch"
fi

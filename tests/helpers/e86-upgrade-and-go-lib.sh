#!/usr/bin/env bash
# e86-upgrade-and-go-lib.sh - shared by tests/e86-upgrade-and-go.bats and tests/helpers/e86-capture-baseline.sh
# (epic E86, task E86_S06_T05). Sourced, never executed; it defines functions and prints nothing when sourced.
#
# The upgrade-and-go regression runs ONE set of script invocations twice: once with the pre-E86 scripts (baseline
# ref 39c530fa, by tests/helpers/e86-capture-baseline.sh, which commits the output as goldens) and once with the
# current scripts (by the bats file, which compares against those goldens byte for byte). Both sides call the same
# function below, so the invocations, the board, the throwaway git history and the output filter cannot drift apart.
#
#   e86_materialize <fixture-dir> <target>
#       Builds the frozen two-digit board project in <target> (created; must not exist or be empty): copies
#       <fixture-dir>/board/proj (stored as proj/, not project/, so the public mirror's .publicignore patterns such as
#       project/board/ cannot strip it), then replays <fixture-dir>/commits.txt into a fresh git repository with pinned
#       author, committer and dates, so every commit SHA reproduces on every machine.
#   e86_run_all <fixture-dir> <scripts-tree> <workdir> <outdir>
#       <scripts-tree> is a checkout-shaped tree holding the scripts under test at their repository-relative paths
#       (the current checkout, or an extracted baseline ref). Builds <workdir>/h (the harness project, via
#       e86_materialize), installs plain copies of the scripts into it (several find the project root from their own
#       location), runs every compared invocation and writes one normalised output file per script into <outdir>.
#       Also writes tree-before.txt and tree-after.txt (name and checksum of every file under project/) and
#       git-status-after.txt, the evidence that nothing is renamed or changed.
#
# Output filter (fixed, applied identically on both sides): the harness path becomes <ROOT> and the scratch temp path
# becomes <TMP>. Nothing else is rewritten; every other byte (dates, SHAs, JSON key order, messages) is compared as is.
#
# Compatible with bash 3.2 (no associative arrays, no mapfile). No network. Writes only below <workdir>/<outdir>.

# Scripts (repository-relative) copied into the harness. A path that does not exist in the tree is skipped: the
# baseline has no scripts/lib/ and no next-board-id.sh.
E86_INSTALL_FILES="
scripts/validate-board.sh
scripts/validate-story-format.sh
scripts/validate-conventions.sh
scripts/resolve-root.sh
scripts/commits-for-item.sh
scripts/render-ranked-list.sh
scripts/next-board-id.sh
skills/jenga/scripts/board-scan.sh
skills/jenga/scripts/cascade-resolve.sh
skills/jenga/scripts/resolve-id.sh
skills/index/scripts/board_index.py
skills/j-close-story/scripts/check-story-closeable.sh
skills/j-close-story/scripts/extract-task-diff-stats.sh
skills/j-do/scripts/bundle-resume.sh
skills/j-uncharted/scripts/validate-proposed-items.sh
skills/j-commit/scripts/commit-subject-check.sh
lib/resolve-project-dir.sh
"

# Pin the git environment the way tests/helpers/mixed-width-board.sh does.
e86_pin_git_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
  unset GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_TEMPLATE_DIR GIT_PREFIX GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Fixture Author" GIT_AUTHOR_EMAIL="fixture@example.invalid"
  export GIT_COMMITTER_NAME="Fixture Author" GIT_COMMITTER_EMAIL="fixture@example.invalid"
}

e86_fgit() {
  git -C "$E86_DIR" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
    -c core.autocrlf=false -c core.safecrlf=false -c core.fileMode=true "$@"
}

e86_materialize() {
  local fx="$1" target="$2" n=0 subject paths p stamp
  mkdir -p "$target" || return 1
  [ -z "$(ls -A "$target")" ] || { echo "e86_materialize: $target is not empty" >&2; return 1; }
  E86_DIR="$(cd "$target" && pwd -P)"
  (
    umask 022
    e86_pin_git_env
    cp -R "$fx/board/proj" "$E86_DIR/project" || exit 1
    e86_fgit -c init.defaultBranch=main init -q || exit 1
    e86_fgit symbolic-ref HEAD refs/heads/main || exit 1
    while IFS="$(printf '\t')" read -r subject paths; do
      [ -n "$subject" ] || continue
      stamp="$(printf '2026-01-04T%02d:%02d:00+0000' $((n / 60)) $((n % 60)))"
      n=$((n + 1))
      export GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp"
      if [ -n "$paths" ]; then
        for p in $paths; do e86_fgit add -- "$p" || exit 1; done
        e86_fgit commit -q -m "$subject" || exit 1
      else
        e86_fgit commit -q --allow-empty -m "$subject" || exit 1
      fi
    done < "$fx/commits.txt"
    [ -z "$(e86_fgit status --porcelain)" ] || { echo "e86_materialize: replayed history left a dirty tree" >&2; exit 1; }
  )
}

# e86_install <scripts-tree> <harness>
e86_install() {
  local src="$1" h="$2" rel
  for rel in $E86_INSTALL_FILES; do
    [ -f "$src/$rel" ] || continue
    mkdir -p "$h/$(dirname "$rel")"
    cp "$src/$rel" "$h/$rel"
  done
  if [ -d "$src/scripts/lib" ]; then
    mkdir -p "$h/scripts"
    cp -R "$src/scripts/lib" "$h/scripts/lib"
  fi
  # Untracked copies of the scripts must not show up as changes of the board repository.
  printf '/scripts/\n/skills/\n/lib/\n' >> "$h/.git/info/exclude"
}

# e86_board_ids  - the ID of every board file of the harness (epic, story and task), one per line, sorted as text.
e86_board_ids() {
  (
    cd "$E86_H/project/board" || exit 1
    for f in epics/*.md; do b="${f##*/}"; printf '%s\n' "${b%%_*}"; done
    for f in stories/*.md; do b="${f##*/}"; printf '%s\n' "$b" | cut -d_ -f1,2; done
    for f in tasks/*.md; do b="${f##*/}"; printf '%s\n' "$b" | cut -d_ -f1,2,3; done
  ) | LC_ALL=C sort -u
}

# e86_tree_listing <harness>  - "<cksum> <size> <path>" of every file below project/, sorted by path.
e86_tree_listing() {
  (cd "$1" && find project -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f" | tr -d '\n')" "$f"; done)
}

# --- recording ---------------------------------------------------------------------------------------------------

# e86_rec <file> <label> <command...>  - run in the harness, append "$ label / exit / stdout / stderr" to <outdir>/<file>.
e86_rec() {
  local file="$1" label="$2" rc out err
  shift 2
  out="$E86_SCRATCH/out.$$" err="$E86_SCRATCH/err.$$"
  (cd "$E86_H" && "$@") > "$out" 2> "$err"
  rc=$?
  {
    printf '$ %s\n' "$label"
    printf 'exit=%s\n' "$rc"
    printf -- '--- stdout\n'
    cat "$out"
    printf -- '--- stderr\n'
    cat "$err"
    printf '=== end\n'
  } >> "$E86_OUT/$file"
}

e86_normalise() {
  local f="$1" h t
  h="$E86_H"
  t="$E86_TMP"
  sed -e "s#$h#<ROOT>#g" -e "s#$t#<TMP>#g" "$f" > "$f.n" && mv "$f.n" "$f"
}

e86_run_all() {
  local fx="$1" tree="$2" work="$3" outdir="$4" f id sha st files bad tid
  mkdir -p "$work" "$outdir" || return 1
  work="$(cd "$work" && pwd -P)"
  E86_OUT="$(cd "$outdir" && pwd -P)"
  E86_TMP="$work/tmp"
  mkdir -p "$E86_TMP" "$work/home" "$E86_TMP/scratch"
  E86_SCRATCH="$E86_TMP/scratch"
  e86_materialize "$fx" "$work/h" || return 1
  E86_H="$work/h"
  e86_install "$tree" "$E86_H"
  e86_tree_listing "$E86_H" > "$E86_OUT/tree-before.txt"

  # One environment for every invocation: the harness is the project, nothing leaks in from the host.
  export TMPDIR="$E86_TMP" HOME="$work/home" PYTHONDONTWRITEBYTECODE=1 LC_ALL=C
  # PyYAML is hidden from every script (a stub module whose import fails), on both sides: validate-board.sh runs an extra
  # strict-YAML check, and warns on stderr, only on a host that has PyYAML, so an unhidden run would depend on the host.
  mkdir -p "$E86_TMP/pystub"
  printf 'raise ImportError("PyYAML is hidden from the upgrade-and-go regression")\n' > "$E86_TMP/pystub/yaml.py"
  export PYTHONPATH="$E86_TMP/pystub"
  export JENGA_PROJECT_ROOT="$E86_H" JENGA_PROJECT_DIR="$E86_H" CLAUDE_PROJECT_DIR="$E86_H"
  unset COPILOT_WORKSPACE_FOLDER JENGA_CONVENTIONS_SCHEMA JENGA_PERCEIVED_BRANCH
  e86_pin_git_env

  files="$(cd "$E86_H" && find project/board -type f -name '*.md' | LC_ALL=C sort)"

  # validate-board.sh: every board file, then malformed IDs that must still be rejected.
  # shellcheck disable=SC2086
  e86_rec validate-board.txt "validate-board.sh <every board file>" bash scripts/validate-board.sh $files
  for bad in E01x E01_S01x E01_S01_T01_ E_01 E01_T01 e01_s01_t01 E01-S01; do
    f="$E86_SCRATCH/bad-$bad.md"
    sed "s/^id: E01_S01_T01\$/id: $bad/" "$E86_H/project/board/tasks/E01_S01_T01_fixture-task.md" > "$f"
    e86_rec validate-board.txt "validate-board.sh <task file with id: $bad>" bash scripts/validate-board.sh "$f"
  done

  e86_rec board-scan.txt "board-scan.sh" bash skills/jenga/scripts/board-scan.sh

  for id in E01 E10 E99 E10_S10 E99_S99 E01_S01_T02 E50 "E01,E10,E11,E99" "E99,E01"; do
    e86_rec cascade-resolve.txt "cascade-resolve.sh $id" bash skills/jenga/scripts/cascade-resolve.sh "$id"
  done

  for id in E01s02 "e01 S04 t02" 0103 E01 e01s01 "e01 s01 t02" 0101 1010 "e10 s10 t10" e99s99t99 0199 E99 e11 "E01s02, e01 S04 t02, 0103" "0101,1010,0199" E50 xyz; do
    e86_rec resolve-id.txt "resolve-id.sh '$id'" bash skills/jenga/scripts/resolve-id.sh "$id"
  done

  e86_rec board-index.txt "board_index.py graph::nodes" python3 skills/index/scripts/board_index.py graph::nodes
  e86_rec board-index.txt "board_index.py graph::edges" python3 skills/index/scripts/board_index.py graph::edges
  e86_rec board-index.txt "board_index.py graph::nodes --type Epic" python3 skills/index/scripts/board_index.py graph::nodes --type Epic

  for id in E01_S01 E01_S02 E01_S04 E10_S01 E10_S10 E11_S01 E99_S99 E50_S01; do
    e86_rec check-story-closeable.txt "check-story-closeable.sh $id" bash skills/j-close-story/scripts/check-story-closeable.sh "$id"
  done

  for id in E01_S01_T01 E01_S01_T02 E01_S04_T02 E10_S01_T01 E10_S10_T10 E11_S01_T01 E99_S99_T99 E01_S01 E01_S01_T50; do
    e86_rec extract-task-diff-stats.txt "extract-task-diff-stats.sh $id" bash skills/j-close-story/scripts/extract-task-diff-stats.sh "$id"
  done

  for id in E01_S01 E01_S04 E10_S10 E10_S01 E99_S99 E11_S01 E50_S01; do
    e86_rec bundle-resume.txt "bundle-resume.sh $id" bash skills/j-do/scripts/bundle-resume.sh "$id"
  done

  # validate-proposed-items.sh on copies of the board files (it only reads), plus a story without its sections.
  mkdir -p "$E86_SCRATCH/proposed/stories" "$E86_SCRATCH/proposed/epics" "$E86_SCRATCH/proposed/tasks"
  cp "$E86_H/project/board/epics/E10_fixture-epic.md" "$E86_SCRATCH/proposed/epics/"
  cp "$E86_H/project/board/stories/E10_S10_fixture-story.md" "$E86_SCRATCH/proposed/stories/"
  cp "$E86_H/project/board/tasks/E10_S10_T10_fixture-task.md" "$E86_SCRATCH/proposed/tasks/"
  e86_rec validate-proposed-items.txt "validate-proposed-items.sh <epic> <task>" bash skills/j-uncharted/scripts/validate-proposed-items.sh \
    "$E86_SCRATCH/proposed/epics/E10_fixture-epic.md" "$E86_SCRATCH/proposed/tasks/E10_S10_T10_fixture-task.md"
  e86_rec validate-proposed-items.txt "validate-proposed-items.sh <story without sections>" bash skills/j-uncharted/scripts/validate-proposed-items.sh \
    "$E86_SCRATCH/proposed/stories/E10_S10_fixture-story.md"
  printf '\n## Acceptance Criteria\n\n- [ ] It works\n\n## Definition of Done\n\n- [ ] Done\n' >> "$E86_SCRATCH/proposed/stories/E10_S10_fixture-story.md"
  e86_rec validate-proposed-items.txt "validate-proposed-items.sh <epic> <story with sections> <task>" bash skills/j-uncharted/scripts/validate-proposed-items.sh \
    "$E86_SCRATCH/proposed/epics/E10_fixture-epic.md" "$E86_SCRATCH/proposed/stories/E10_S10_fixture-story.md" "$E86_SCRATCH/proposed/tasks/E10_S10_T10_fixture-task.md"

  # commit-subject-check.sh: every subject of the throwaway history, plus subjects that are not board subjects.
  while IFS= read -r st; do
    e86_rec commit-subject-check.txt "commit-subject-check.sh '$st'" bash skills/j-commit/scripts/commit-subject-check.sh "$st"
  done < <(git -C "$E86_H" log --reverse --format=%s)
  for st in "task(E01_S01_T01): x" "task(E01_S01_T1): x" "chore(E01_S01_T): x" "story(E99_S99): x" "epic(E10): x" "fix: nothing to see"; do
    e86_rec commit-subject-check.txt "commit-subject-check.sh '$st'" bash skills/j-commit/scripts/commit-subject-check.sh "$st"
  done

  # commits-for-item.sh: every epic, story and task ID on the board, then an unknown one.
  for id in $(e86_board_ids) E50_S01_T01; do
    e86_rec commits-for-item.txt "commits-for-item.sh $id" bash scripts/commits-for-item.sh "$id"
  done

  e86_rec render-ranked-list.txt "render-ranked-list.sh" bash scripts/render-ranked-list.sh

  # The next ID: the current allocator, or (at the baseline, which has none) the old rule - see e86_old_next_id.
  e86_rec next-board-id.txt "next epic" e86_nextid epic
  for id in E01 E10 E11 E99; do e86_rec next-board-id.txt "next story $id" e86_nextid story "$id"; done
  for id in E01_S01 E01_S04 E10_S01 E10_S10 E11_S01 E99_S99; do e86_rec next-board-id.txt "next task $id" e86_nextid task "$id"; done

  e86_dashboard "$tree"

  e86_tree_listing "$E86_H" > "$E86_OUT/tree-after.txt"
  { git -C "$E86_H" status --porcelain; git -C "$E86_H" rev-parse HEAD; } > "$E86_OUT/git-status-after.txt"

  for f in "$E86_OUT"/*.txt; do e86_normalise "$f"; done
}

# The old numbering rule, from before E86 had an allocator: the highest number among the existing files of that level,
# plus one, padded to two digits (skills/j-todo/scripts/add_trivial_task.sh at the baseline ref, lines 126-142, for tasks;
# stories and epics followed the same rule in prose, and skills/j-uncharted/scripts/write-backfilled-epics.sh used
# "E%02d" for epics). Runs in the harness project root. Usage: e86_old_next_id epic | story <epic-id> | task <story-id>.
e86_old_next_id() {
  local kind="$1" parent="${2:-}" dir pat max=0 f num
  case "$kind" in
    epic) dir=project/board/epics; pat='^E([0-9]+)_.*' ;;
    story) dir=project/board/stories; pat="^${parent}_S([0-9]+)_.*" ;;
    task) dir=project/board/tasks; pat="^${parent}_T([0-9]+)_.*" ;;
    *) echo "e86_old_next_id: bad kind $kind" >&2; return 2 ;;
  esac
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    f="$(basename "$f")"
    num="$(printf '%s' "$f" | sed -nE "s/$pat/\\1/p")"
    [ -n "$num" ] || continue
    num=$((10#$num))
    [ "$num" -gt "$max" ] && max=$num
  done
  num="$(printf '%02d' $((max + 1)))"
  case "$kind" in
    epic) printf 'E%s\n' "$num" ;;
    story) printf '%s_S%s\n' "$parent" "$num" ;;
    task) printf '%s_T%s\n' "$parent" "$num" ;;
  esac
}

e86_nextid() {
  if [ -f scripts/next-board-id.sh ]; then bash scripts/next-board-id.sh "$@"; else e86_old_next_id "$@"; fi
}

# The dashboard's board listing: the API parser, called from Node. The tree's own board.js is loaded, so the
# baseline run uses the baseline parser. gray-matter is resolved from this repository's node_modules (NODE_PATH),
# because an extracted baseline tree has none of its own.
e86_dashboard() {
  local tree="$1"
  e86_rec dashboard-board.txt "node: JSON.stringify(await parseBoard(), null, 2)" env NODE_PATH="${E86_NODE_PATH:-}" node -e '
    const path = require("path");
    const { parseBoard } = require(path.join(process.argv[1], "project/app/api/parsers/board.js"));
    parseBoard().then((b) => process.stdout.write(JSON.stringify(b, null, 2) + "\n"));
  ' "$tree"
}

# e86_node_path <repo-root>  - the node_modules directory gray-matter resolves from, or nothing.
e86_node_path() {
  local p
  p="$(cd "$1/project/app/api" 2>/dev/null && node -p "require.resolve('gray-matter')" 2>/dev/null)" || return 1
  printf '%s\n' "${p%%/node_modules/*}/node_modules"
}

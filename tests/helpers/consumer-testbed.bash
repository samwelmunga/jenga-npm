# Consumer-install testbed (E54_S03): packs this repo exactly as `npm publish` would, installs the tarball
# into a throwaway consumer project, and lets a test run framework commands from that consumer's root.
#
# This monorepo has bare root scripts/ and skills/, which masks every bug where a packaged script resolves
# a helper relative to the consumer's git toplevel instead of the package (E46, mark-deployed.sh 4.3.0).
# The consumer built here deliberately has no such root tree.
#
# Usage in a .bats file:
#   load helpers/consumer-testbed
#   setup_file() { testbed_pack; }
#   @test "..." { testbed_consumer "$BATS_TEST_TMPDIR/c" clean; cd "$BATS_TEST_TMPDIR/c"; run bash ...; }
#
# Shapes (what the consumer's own root contains besides the installed package):
#   clean     nothing framework-related at the root
#   jobo      skills/close-story/ (no j- prefix) and an unrelated scripts/ file, as in the 4.3.0 report
#   decoy     scripts/with-lock.sh and skills/j-close-story/scripts/update-task-frontmatter.sh that FAIL
#             when executed, so a script resolving helpers from the consumer root fails loudly instead of
#             silently using the wrong file
#
# The install is tarball extraction plus `node scripts/postinstall.js` with INIT_CWD set, the same steps
# `npm install` performs, minus dependency download (hermetic, no network). The package's own runtime
# dependencies (express, gray-matter, ...) are therefore not present; tests that need them belong elsewhere.

TESTBED_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Packs the working tree once per bats file (prepack, which builds the UI, is skipped on purpose).
testbed_pack() {
  TESTBED_PACK_DIR="$BATS_FILE_TMPDIR/testbed-pack"
  mkdir -p "$TESTBED_PACK_DIR"
  ( cd "$TESTBED_REPO_ROOT" && npm pack --ignore-scripts --silent --pack-destination "$TESTBED_PACK_DIR" >/dev/null )
  local tarballs=("$TESTBED_PACK_DIR"/*.tgz)
  TESTBED_TARBALL="${tarballs[0]}"
  export TESTBED_PACK_DIR TESTBED_TARBALL
  [ -f "$TESTBED_TARBALL" ] || { echo "testbed_pack: npm pack produced no tarball" >&2; return 1; }
}

# testbed_install_package <consumer-dir>: extract the tarball into node_modules/@jenga-ai/agent and run postinstall.
testbed_install_package() {
  local dir="$1" pkg
  pkg="$dir/node_modules/@jenga-ai/agent"
  mkdir -p "$pkg"
  tar -xzf "$TESTBED_TARBALL" -C "$pkg" --strip-components=1
  ( cd "$pkg" && INIT_CWD="$dir" node scripts/postinstall.js >"$dir/.postinstall.log" 2>&1 ) \
    || { cat "$dir/.postinstall.log" >&2; echo "testbed: postinstall failed" >&2; return 1; }
}

# testbed_git_init <dir>: git repo with a deterministic identity and no hooks.
testbed_git_init() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email testbed@example.com
  git -C "$dir" config user.name testbed
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config core.hooksPath /dev/null
}

# testbed_consumer <dir> <clean|jobo|decoy>
testbed_consumer() {
  local dir="$1" shape="${2:-clean}"
  mkdir -p "$dir"
  printf '{ "name": "consumer-fixture", "version": "0.0.0", "private": true }\n' > "$dir/package.json"
  printf 'node_modules/\n.claude/\n.agents/\n' > "$dir/.gitignore"
  testbed_git_init "$dir"
  case "$shape" in
    clean) ;;
    jobo)
      mkdir -p "$dir/skills/close-story" "$dir/scripts"
      printf -- '---\nname: close-story\ndescription: consumer-owned skill\n---\n' > "$dir/skills/close-story/SKILL.md"
      printf '#!/usr/bin/env bash\necho consumer script\n' > "$dir/scripts/unrelated.sh"
      ;;
    decoy)
      mkdir -p "$dir/scripts" "$dir/skills/j-close-story/scripts"
      printf '#!/usr/bin/env bash\necho "DECOY with-lock.sh used: script resolved a helper from the consumer root" >&2\nexit 97\n' > "$dir/scripts/with-lock.sh"
      printf '#!/usr/bin/env bash\necho "DECOY update-task-frontmatter.sh used: script resolved a helper from the consumer root" >&2\nexit 98\n' > "$dir/skills/j-close-story/scripts/update-task-frontmatter.sh"
      chmod +x "$dir/scripts/with-lock.sh"
      ;;
    *) echo "testbed_consumer: unknown shape '$shape'" >&2; return 1 ;;
  esac
  mkdir -p "$dir/project/board/tasks" "$dir/project/board/stories" "$dir/project/board/epics" \
           "$dir/project/data" "$dir/project/logs" "$dir/project/queue"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: consumer scaffold ($shape)"
  testbed_install_package "$dir"
}

# testbed_add_task <consumer-dir> <task-id> <status>: a minimal task file plus an EST-tagged commit for it.
testbed_add_task() {
  local dir="$1" id="$2" status="$3"
  printf -- '---\nid: %s\nstatus: %s\ndate_completed:\n---\n\n# Task: %s\n' "$id" "$status" "$id" \
    > "$dir/project/board/tasks/${id}_fixture.md"
  git -C "$dir" add project/board/tasks
  git -C "$dir" commit -q -m "task($id): fixture"
}

# testbed_skill_command <skill-name> <script-basename>: prints the first fenced command line in
# skills/<skill-name>/SKILL.md that invokes <script-basename>, with leading indentation and any trailing
# <placeholder> arguments removed (append real arguments yourself). This is the exact string a skill tells
# the agent to run, so tests drive the consumer through the instructions, not through a hand-written path.
testbed_skill_command() {
  local skill="$1" script="$2"
  grep -m1 -E "^[[:space:]]*bash \"\\\$\(\[ -f [^ ]*${script}" "$TESTBED_REPO_ROOT/skills/$skill/SKILL.md" \
    | sed -E 's/^[[:space:]]+//; s/ <[^>]+>.*$//'
}

# testbed_sweep_package_root_paths <package-dir> <allowlist-file>
# Static sweep over the shipped scripts for the defect class behind E46 and the 4.3.0 mark-deployed.sh report:
# a path to a file that ships INSIDE the package (scripts/, skills/, templates/, lib/, agents/, hooks/, mcp/)
# built from a variable that, in a consumer, is the consumer's repo root. Prints one line per violation and
# returns 1 if any. A site is accepted when its own file also names the same target through
# node_modules/@jenga-ai/agent/<target> or resolve_helper <target> (the repo's fallback idioms), or when
# <allowlist-file> has a "<file><TAB><target-or-*><TAB><reason>" line for it.
testbed_sweep_package_root_paths() {
  local pkg="$1" allow="$2" bad=0 file target
  local roots='REPO_ROOT|ROOT|PROJECT_ROOT|REPO|GIT_ROOT|TOPLEVEL'
  local dirs='scripts|skills|templates|lib|agents|hooks|mcp'
  while IFS=$'\t' read -r file target; do
    [ -n "$file" ] || continue
    if grep -qF "node_modules/@jenga-ai/agent/$target" "$pkg/$file" 2>/dev/null \
       || grep -qE "resolve_helper[[:space:]]+$target" "$pkg/$file" 2>/dev/null; then
      continue
    fi
    if [ -f "$allow" ] && awk -F'\t' -v f="$file" -v t="$target" \
         '$1==f && ($2==t || $2=="*") { found=1 } END { exit !found }' "$allow"; then
      continue
    fi
    printf '%s\t%s\n' "$file" "$target"
    bad=1
  done < <(
    cd "$pkg" && grep -rnE "\\\$\\{?($roots)\\}?/($dirs)/" scripts skills hooks lib \
        --include='*.sh' --include='*.js' 2>/dev/null \
      | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' \
      | sed -nE "s#^([^:]+):[0-9]+:.*\\\$\\{?($roots)\\}?/(($dirs)/[A-Za-z0-9_./\$-]*).*#\\1\\t\\3#p" \
      | sort -u
  )
  return "$bad"
}

# testbed_consumer_from <source-project> <dest-dir>: a disposable copy of a real consumer project (never used
# in place) with the packed working tree installed over whatever @jenga-ai/agent it had. node_modules, build
# output, .git and old tarballs are left out; the copy gets a fresh single-commit git history.
testbed_consumer_from() {
  local src="$1" dst="$2"
  [ -d "$src" ] || { echo "testbed_consumer_from: no such directory: $src" >&2; return 1; }
  mkdir -p "$dst"
  rsync -a --exclude node_modules --exclude .next --exclude .git --exclude '*.tgz' --exclude .env "$src/" "$dst/"
  testbed_git_init "$dst"
  git -C "$dst" add -A >/dev/null 2>&1
  git -C "$dst" commit -q -m "chore: disposable copy of $(basename "$src")" --allow-empty
  testbed_install_package "$dst"
}

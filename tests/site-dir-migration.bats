#!/usr/bin/env bats
# tests/site-dir-migration.bats  (E70_S02_T07)
#
# Locks in the docs/ -> site/ migration of the Jenga GitHub Pages source:
#   1. this repo keeps no docs/ (git index AND working tree),
#   2. every page still publishes at its exact pre-move URL (flat permalink),
#   3. no permalink gained a guides/ or reference/ segment,
#   4. all 11 site files exist,
#   5. site/ is not shipped in the npm tarball and is not blocked by .publicignore.
#
# The `npm pack --dry-run` check is deliberately NOT here: `prepack` runs a UI
# build, which is slow and can dirty tracked files. Its evidence is recorded in
# the E70_S02_T07 commit message; the static allowlist assertions below cover
# the same guarantee without running npm.
#
# Network-free; reads files and runs scripts/check-publicignore-match.sh only.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# page file -> literal expected front-matter permalink (the pre-move URL set)
PAGES=(
  "site/guides/getting-started.md|/getting-started.html"
  "site/guides/concepts.md|/concepts.html"
  "site/guides/preflight-checklists.md|/preflight-checklists.html"
  "site/reference/reference.md|/reference.html"
  "site/reference/skills.md|/skills.html"
  "site/reference/agents.md|/agents.html"
  "site/reference/hooks.md|/hooks.html"
  "site/reference/mcp-tools.md|/mcp-tools.html"
  "site/reference/jenga-config.md|/jenga-config.html"
)

# Front matter = lines between the first two '---' markers.
front_matter() { awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$1"; }

@test "docs/ is absent from the git index" {
  run git -C "$REPO_ROOT" ls-files docs/
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "docs/ is absent from the working tree" {
  [ ! -e "$REPO_ROOT/docs" ]
}

@test "all 11 site files exist at their moved paths" {
  n=0
  for f in site/index.md site/_config.yml; do [ -f "$REPO_ROOT/$f" ]; n=$((n+1)); done
  for row in "${PAGES[@]}"; do [ -f "$REPO_ROOT/${row%%|*}" ]; n=$((n+1)); done
  [ "$n" -eq 11 ]
}

@test "every page still declares its exact pre-move permalink" {
  for row in "${PAGES[@]}"; do
    f="${row%%|*}"; want="${row##*|}"
    got="$(front_matter "$REPO_ROOT/$f" | sed -n 's/^permalink:[[:space:]]*//p')"
    if [ "$got" != "$want" ]; then
      echo "$f: permalink '$got', expected '$want'" >&2
      return 1
    fi
  done
}

@test "site/index.md is layout: home with no permalink (publishes at the site root)" {
  fm="$(front_matter "$REPO_ROOT/site/index.md")"
  echo "$fm" | grep -qx 'layout: home'
  ! echo "$fm" | grep -q '^permalink:'
}

@test "no page under site/ declares a permalink with a guides/ or reference/ segment" {
  run grep -rnE '^permalink:.*/(guides|reference)/' "$REPO_ROOT/site"
  [ "$status" -eq 1 ]
}

@test "no permalink is anything but flat (/<name>.html)" {
  while IFS= read -r line; do
    v="${line#permalink:}"; v="${v# }"
    [[ "$v" =~ ^/[a-z-]+\.html$ ]] || { echo "non-flat permalink: $v" >&2; return 1; }
  done < <(grep -rhE '^permalink:' "$REPO_ROOT/site")
}

@test "site/_config.yml header_pages entries all resolve to files, and declares no exclude" {
  cfg="$REPO_ROOT/site/_config.yml"
  ! grep -qE '^exclude:' "$cfg"
  entries="$(sed -n '/^header_pages:/,/^[^ -]/p' "$cfg" | sed -n 's/^  - //p')"
  [ -n "$entries" ]
  while IFS= read -r e; do [ -f "$REPO_ROOT/site/$e" ] || { echo "missing: $e" >&2; return 1; }; done <<< "$entries"
}

@test "intra-site links resolve (scripts/check-site-links.sh)" {
  run bash "$REPO_ROOT/scripts/check-site-links.sh" --quiet
  [ "$status" -eq 0 ]
}

@test "npm tarball allowlist: package.json files names neither site/ nor docs/" {
  run python3 -c "
import json,sys
d=json.load(open('$REPO_ROOT/package.json'))
bad=[f for f in d['files'] if f.rstrip('/').split('/')[0] in ('site','docs')]
sys.exit(1 if bad else 0)"
  [ "$status" -eq 0 ]
}

@test ".npmignore does not re-include site/" {
  run grep -nE '^!?/?site(/|$)' "$REPO_ROOT/.npmignore"
  [ "$status" -eq 1 ]
}

@test "site/ is not blocked by .publicignore: root, a guide and a reference page are PUBLIC" {
  for p in site/index.md site/guides/getting-started.md site/reference/skills.md; do
    run bash "$REPO_ROOT/scripts/check-publicignore-match.sh" "$p"
    [ "$status" -eq 0 ]
    [[ "$output" == PUBLIC* ]] || { echo "$p -> $output" >&2; return 1; }
  done
}

# Fixtures for the `jenga sync` and drift tests (E26_S11_T07).
#
# A real sync regenerates lib/skill-allow-list.json inside the PACKAGE root (as postinstall always did), so these
# tests never point it at this repository: setup_file copies the shipped parts of the package once into a throwaway
# directory and every test drives that copy, with a throwaway consumer under $BATS_TEST_TMPDIR. Nothing here reads
# or writes this repository's own .claude/ or .agents/.
#
# Usage in a .bats file:
#   load helpers/assertions
#   load helpers/sync-fixture
#   setup_file() { sync_make_package; }
#   setup() { sync_make_consumer; }

SYNC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# sync_make_package: copy what an installed package carries into $BATS_FILE_TMPDIR/pkg-base (setup_file).
sync_make_package() {
  local pkg="$BATS_FILE_TMPDIR/pkg-base" d
  mkdir -p "$pkg"
  for d in lib scripts templates skills agents hooks bin; do
    cp -R "$SYNC_REPO_ROOT/$d" "$pkg/$d"
  done
  cp "$SYNC_REPO_ROOT/package.json" "$pkg/package.json"
}

# sync_make_consumer: a private copy of the package at $PKG (a real sync rewrites lib/skill-allow-list.json in it, so
# tests must not share one) and an empty consumer project at $CONSUMER (setup()).
sync_make_consumer() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  cp -R "$BATS_FILE_TMPDIR/pkg-base" "$PKG"
  PKG_VERSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$PKG/package.json")"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  export PKG PKG_VERSION CONSUMER
}

# jenga <args...>: the real CLI of the package copy, run from the consumer root.
jenga() {
  ( cd "$CONSUMER" && node "$PKG/bin/jenga.js" "$@" )
}

# tree_hash <dir>: one hash over every path (files and directories) and every file's content under <dir>.
tree_hash() {
  ( cd "$1" && { find . | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1 )
}

# file_hash <file>: content hash of one file.
file_hash() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# block_names <file>: the skill names listed in the Jenga block of <file>, one per line, sorted.
block_names() {
  sed -n '/<!-- JENGA:START -->/,/<!-- JENGA:END -->/p' "$1" | sed -n 's/^- \*\*\([^*]*\)\*\*.*/\1/p' | LC_ALL=C sort
}

# dir_names <dir>: immediate subdirectory names of <dir>, one per line, sorted.
dir_names() {
  ( cd "$1" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort )
}

# drop_lines <file> <sed-address>: delete the matching lines of <file> in place (extended regex, no backup file).
drop_lines() {
  sed -E "$2 d" "${1:?}" > "${1:?}.tmp" && mv "${1:?}.tmp" "${1:?}"
}

# remove_dir <dir>: remove a directory tree that must exist (an unset variable can never expand to a bare path).
remove_dir() {
  rm -rf "${1:?}"
}

# split_outside_markers <file> <prefix-out> <suffix-out>: write the bytes before JENGA:START and the bytes after
# JENGA:END of <file> to the two output files, exactly as they are.
split_outside_markers() {
  node -e '
    const fs = require("fs");
    const t = fs.readFileSync(process.argv[1], "utf8");
    const s = t.indexOf("<!-- JENGA:START -->");
    const eMarker = "<!-- JENGA:END -->";
    const e = t.indexOf(eMarker);
    if (s === -1 || e === -1) { process.exit(3); }
    fs.writeFileSync(process.argv[2], t.slice(0, s));
    fs.writeFileSync(process.argv[3], t.slice(e + eMarker.length));
  ' "$1" "$2" "$3"
}

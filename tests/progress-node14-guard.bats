#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# E92_S08_T08: the Node-14 guard for everything story E92_S08 added in JavaScript.
#
# package.json `engines.node` is >=14.13.1. tests/progress-shared-structure.bats and tests/lib-progress-core.test.mjs scan
# lib/progress/ for the API names the story bans (replaceAll, Array at, logical assignment, Object.hasOwn,
# structuredClone, node:test, fetch). Two gaps were left, and this file closes them:
#
# 1. The story's own Node TEST files and lib/commands/progress.js were never scanned. All three test files imported
#    `rmSync` from "fs" by name; fs.rmSync came in Node 14.14, so on 14.13.1 the ESM link step failed with
#    "The requested module 'fs' does not provide an export named 'rmSync'" and not one of their tests ran. The scan below
#    covers those files, with the story's list plus the APIs that newer-than-14.13.1 code most often reaches for
#    (rmSync and rm, cpSync and cp, randomUUID, findLast, toSorted, new AbortController, the */promises modules).
#    Comments, string literals and regex literals are removed first, so prose and the scanners' own patterns may name
#    the APIs. A runtime call guarded by `typeof ... === "function"` on the same line is allowed (the removeTree helper).
# 2. Nothing ran the code on Node 14.13.1. When such a binary is available (JENGA_NODE14_BIN, or nvm's v14.13.1) every
#    module under lib/progress/ and lib/commands/progress.js is imported with it and `cli.js info` is run; otherwise the
#    case is skipped. (Running the whole test files there takes minutes; they were run once by hand, see the summary of
#    E92_S08_T08.)
#
# The controls plant each banned form in a scratch file and prove the scan reports it.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# The files the story added in JavaScript, repo-relative.
story_js_files() {
  (cd "$REPO_ROOT" && {
    ls lib/progress/*.js
    ls lib/commands/progress.js
    ls tests/lib-progress-*.test.mjs
    ls project/app/ui/scripts/dependency-structure-parity.test.cjs 2>/dev/null || true
  } | LC_ALL=C sort)
}

# scan_file <file>: prints "<file>: <label>: <line>" per hit; status 1 when there is any.
scan_file() {
  perl -e '
    local $/; my $f = $ARGV[0]; open(my $h, "<", $f) or die "$f: $!"; my $src = <$h>;
    # comments: block, then whole-line //, then trailing // after code (not inside a string: strings are gone first below)
    $src =~ s{/\*.*?\*/}{ }gs;
    $src =~ s{^[ \t]*//[^\n]*}{}gm;
    my @hits;
    # imports, read before strings are blanked (the module name IS a string)
    while ($src =~ /import\s*\{([^}]*)\}\s*from\s*["\x27](?:node:)?fs["\x27]/g) {
      for my $n (split /\s*,\s*/, $1) { $n =~ s/\s+as\s+\w+//; $n =~ s/^\s+|\s+$//g;
        push @hits, "named fs import $n (newer than 14.13.1)" if $n =~ /^(rmSync|rm|cpSync|cp)$/; }
    }
    push @hits, "module $1" while $src =~ /(?:from\s*|import\s*\(\s*|require\s*\(\s*)["\x27]((?:node:)?(?:test|timers\/promises|stream\/promises|readline\/promises))["\x27]/g;
    # strings and regex literals blanked, line structure kept
    $src =~ s{"(?:[^"\\\n]|\\.)*"}{""}g;
    $src =~ s{\x27(?:[^\x27\\\n]|\\.)*\x27}{""}g;
    $src =~ s{`(?:[^`\\]|\\.)*`}{""}gs;
    $src =~ s{([(,=:\[!&|?{};]\s*)/(?![/*])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/[a-z]*}{$1 RE }g;
    $src =~ s{[ \t]//[^\n]*}{}g;
    my @rules = (
      ["replaceAll", qr/\.replaceAll\s*\(/], ["Array at", qr/\.at\s*\(/], ["logical assignment", qr/(\?\?|\|\||&&)=/],
      ["Object.hasOwn", qr/\bObject\s*\.\s*hasOwn\b/], ["structuredClone", qr/\bstructuredClone\s*\(/],
      ["fetch", qr/(^|[^.\w\$])fetch\s*\(/], ["findLast", qr/\.findLast(Index)?\s*\(/], ["toSorted", qr/\.to(Sorted|Reversed|Spliced)\s*\(/],
      ["randomUUID", qr/\brandomUUID\s*\(/], ["AbortController", qr/\bnew\s+AbortController\b/],
      ["rmSync or cpSync call", qr/\b(rmSync|cpSync)\s*\(/],
    );
    for my $line (split /\n/, $src) {
      for my $r (@rules) {
        next unless $line =~ $r->[1];
        next if $r->[0] eq "rmSync or cpSync call" && $line =~ /typeof\s+[\w.]+\.(rmSync|cpSync)\s*===\s*""/;
        (my $t = $line) =~ s/^\s+//; push @hits, "$r->[0]: $t";
      }
    }
    print "$f: $_\n" for @hits;
    exit(@hits ? 1 : 0);
  ' "$1"
}

@test "node 14: the story's JS files (lib/progress, lib/commands/progress.js, the Node test files) use no API newer than 14.13.1" {
  local f bad=0 n=0
  while IFS= read -r f; do
    n=$((n + 1))
    scan_file "$REPO_ROOT/$f" || bad=1
  done < <(story_js_files)
  [ "$n" -ge 15 ] || { echo "only $n files scanned"; false; }
  [ "$bad" -eq 0 ]
}

@test "node 14: every Node test file of the story is in the scanned set" {
  local list
  list="$(story_js_files)"
  for f in tests/lib-progress-core.test.mjs tests/lib-progress-bar.test.mjs tests/lib-progress-overview-scope.test.mjs tests/lib-progress-parity.test.mjs lib/commands/progress.js lib/progress/cli.js; do
    grep -qxF "$f" <<<"$list" || { echo "$f is not scanned"; false; }
  done
}

@test "node 14 control: each banned form planted in a scratch file is reported" {
  local plants=(
    'import { mkdirSync, rmSync } from "fs";'
    'import { rm } from "node:fs";'
    'import { cpSync as copy } from "fs";'
    'import t from "node:test";'
    'import { setTimeout as wait } from "timers/promises";'
    'const a = s.replaceAll("a", "b");'
    'const b = xs.at(-1);'
    'let c; c ??= 1;'
    'let d; d ||= 1;'
    'const e = Object.hasOwn(o, "k");'
    'const g = structuredClone(o);'
    'const h = await fetch("http://localhost");'
    'const i = xs.findLast((x) => x);'
    'const j = xs.toSorted();'
    'const k = crypto.randomUUID();'
    'const l = new AbortController();'
    'fs.rmSync(dir, { recursive: true });'
  )
  local p
  for p in "${plants[@]}"; do
    printf '%s\n' "$p" > "$BATS_TEST_TMPDIR/planted.mjs"
    run scan_file "$BATS_TEST_TMPDIR/planted.mjs"
    [ "$status" -ne 0 ] || { echo "not reported: $p"; false; }
  done
}

@test "node 14 control: comments, strings, regex literals and the guarded rmSync helper are not reported" {
  cat > "$BATS_TEST_TMPDIR/clean.mjs" <<'JS'
/** no replaceAll, no .at( and no ??= here, nor Object.hasOwn, structuredClone(, node:test, rmSync( or fetch( */
// fetch( replaceAll( .at( ??= rmSync(
import assert from "assert";
import fsModule from "fs";
const banned = [["replaceAll", /\breplaceAll\b/], [".at(", /\.at\s*\(/], ["??=", /\?\?=/], ["&&=", /&&=/], ["||=", /\|\|=/]];
assert.ok(/\.at\s*\(/.test("xs.at(-1)") && "s.replaceAll('a','b')".length > 0 && 'c ??= 1' !== "");
const removeTree = (d) =>
  typeof fsModule.rmSync === "function" ? fsModule.rmSync(d, { recursive: true, force: true }) : fsModule.rmdirSync(d, { recursive: true });
const prefetched = 1; // a trailing comment: fetch( .at( ??=
const atom = [1, 2].map((x) => x ?? 0).join(`${banned.length}.at(`);
JS
  run scan_file "$BATS_TEST_TMPDIR/clean.mjs"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# A Node 14.13.1 binary: JENGA_NODE14_BIN, else nvm's. Prints nothing when there is none.
node14_bin() {
  local b="${JENGA_NODE14_BIN:-${NVM_DIR:-$HOME/.nvm}/versions/node/v14.13.1/bin/node}"
  [ -x "$b" ] && [ "$("$b" --version 2>/dev/null)" = "v14.13.1" ] && printf '%s' "$b"
  return 0
}

@test "node 14.13.1 (when installed): every lib/progress module and lib/commands/progress.js loads, and cli.js info runs" {
  local n14 f
  n14="$(node14_bin)"
  [ -n "$n14" ] || skip "no Node 14.13.1 binary (set JENGA_NODE14_BIN)"
  for f in "$REPO_ROOT"/lib/progress/*.js "$REPO_ROOT/lib/commands/progress.js"; do
    run "$n14" --input-type=module -e "import('file://$f').then(() => process.exit(0), (e) => { console.error(String(e)); process.exit(1); })"
    [ "$status" -eq 0 ] || { echo "${f#"$REPO_ROOT"/}: $output"; false; }
  done
  run --separate-stderr "$n14" "$REPO_ROOT/lib/progress/cli.js" info --charset ascii --color never
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ -n "$output" ]
}

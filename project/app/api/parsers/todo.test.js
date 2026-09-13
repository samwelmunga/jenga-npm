/**
 * @file project/app/api/parsers/todo.test.js
 * Plain Node `assert`-based test script for `parsers/todo.js` (E06_S05_T04).
 *
 * No test framework is introduced: `project/app/api/` has no JS test-framework convention — see
 * `knowledge-graph.test.js`'s header for the background (the root `package.json`'s `test` script
 * runs `bats tests/*.bats`, shell only). This file follows that same plain-`assert` pattern and is
 * registered in `project/app/api/package.json`'s `test` script alongside it.
 *
 * Run directly:
 *   node project/app/api/parsers/todo.test.js
 * or, from project/app/api/:
 *   npm test
 *
 * Two layers are covered:
 *   1. Pure-content parsing (`stripComments`, `parseTodoContent`) against every line shape the real
 *      file contains, including the shapes that motivated the end-anchored ref pattern.
 *   2. A read of the **real** `project/todo.md` via `readTodoRefs()`, asserting the two properties
 *      that would silently break the Active Sprint view if the regex ever loosened: no ref is
 *      harvested from a `<!-- RECONCILED: ... -->` comment line, and no ref is harvested from a
 *      rapport filename cited mid-line. Plus a temp-directory round-trip for the missing-file and
 *      explicit-path branches. Temp fixtures are written inside this repo (never `/tmp`, which this
 *      project forbids) and cleaned up in a `finally`.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const { readTodoRefs, parseTodoContent, stripComments } = require('./todo');

const REPO_ROOT = path.resolve(__dirname, '..', '..', '..', '..');

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`  ok — ${name}`);
  } catch (err) {
    failures += 1;
    console.error(`  FAIL — ${name}`);
    console.error(`        ${err.message}`);
  }
}

// ---------------------------------------------------------------------------------------------
// 1. stripComments
// ---------------------------------------------------------------------------------------------
console.log('stripComments:');

check('removes a single-line balanced comment', () => {
  const out = stripComments('a: E01_S01\n<!-- RECONCILED: b: E02_S02 ✅ -->\nc: E03_S03');
  assert.ok(!out.includes('E02_S02'), 'commented ref should be gone');
  assert.ok(out.includes('E01_S01') && out.includes('E03_S03'));
});

check('removes a multi-line balanced comment', () => {
  const out = stripComments('a: E01_S01\n<!-- open\nstill inside: E02_S02\n-->\nc: E03_S03');
  assert.ok(!out.includes('E02_S02'));
  assert.ok(out.includes('E03_S03'));
});

check('preserves line numbering when removing a multi-line comment', () => {
  // Regression guard for the remark filed in
  // project/rapports/problems/E06_S05_T04-queued-promotion-non-blocking-remarks.md: collapsing a
  // balanced block to a bare space shifted every later line up by the block's newline count.
  const content = 'a: E01_S01\n<!-- open\nstill inside: E02_S02\n-->\nc: E03_S03\n';
  const out = stripComments(content);
  assert.equal(
    out.split('\n').length,
    content.split('\n').length,
    'stripped content must have the same line count as the original'
  );
  assert.ok(!out.includes('E02_S02'), 'the commented ref is still removed');
});

check('keeps text trailing a multi-line comment on its own original line', () => {
  const out = stripComments('<!-- open\nclose --> c: E03_S03\n');
  assert.equal(out.split('\n')[1].trim(), 'c: E03_S03', 'trailing text stays on line 2');
});

check('truncates at an unterminated trailing comment', () => {
  const out = stripComments('a: E01_S01\n<!-- never closed\nb: E02_S02');
  assert.ok(out.includes('E01_S01'));
  assert.ok(!out.includes('E02_S02'), 'everything after an unclosed <!-- is commented out');
});

check('does not glue text across a removed mid-line comment', () => {
  // Without the space-substitution, "title" + ": E01_S01" could fuse into a fake entry.
  const refs = parseTodoContent('some title <!-- c --> trailing prose.\n').refs;
  assert.deepEqual(refs, []);
});

check('tolerates null/undefined content', () => {
  assert.equal(stripComments(undefined), '');
  assert.equal(stripComments(null), '');
});

// ---------------------------------------------------------------------------------------------
// 2. parseTodoContent
// ---------------------------------------------------------------------------------------------
console.log('parseTodoContent:');

check('extracts a trailing story ref', () => {
  assert.deepEqual(parseTodoContent('Handoff document schema & checkpoint: E23_S01\n').refs, ['E23_S01']);
});

check('extracts a trailing task ref', () => {
  assert.deepEqual(parseTodoContent('Implement set-break.sh and clear-break.sh: E44_S01_T02\n').refs, ['E44_S01_T02']);
});

check('ignores a line with no ref', () => {
  assert.deepEqual(parseTodoContent('invoke /brainstorm project/rapports/analysis/some-eval.md\n').refs, []);
});

check('ignores headings and blank lines', () => {
  assert.deepEqual(parseTodoContent('# Todo\n\n\n').refs, []);
});

check('ignores an epic-only trailing ref (documented decision)', () => {
  assert.deepEqual(parseTodoContent('Fix hardcoded paths: E34\n').refs, []);
});

check('ignores a ref embedded mid-line in a filename — the real line-60 trap', () => {
  const line =
    'Fix hardcoded project/ paths in board_resolver.sh (see project/rapports/problems/' +
    'E31_S05_T01-hidden-mode-path-resolution-gaps.md, F1/F2): E34\n';
  assert.deepEqual(
    parseTodoContent(line).refs,
    [],
    'neither the cited E31_S05_T01 filename nor the epic-only E34 may be treated as queued'
  );
});

check('ignores a ref mid-line even when the line ends with other prose', () => {
  assert.deepEqual(
    parseTodoContent('Verify the fix (E22_S09_T05) is live on npm before re-fixing it.\n').refs,
    []
  );
});

check('keeps a trailing ref when another ref is cited mid-line', () => {
  assert.deepEqual(
    parseTodoContent('Verify the fix (E22_S09_T05) is live on npm: E22_S09\n').refs,
    ['E22_S09'],
    'only the trailing ref is the queued one'
  );
});

check('de-duplicates repeated refs, preserving first-appearance order', () => {
  const refs = parseTodoContent('a: E02_S01\nb: E01_S01\nc: E02_S01\n').refs;
  assert.deepEqual(refs, ['E02_S01', 'E01_S01']);
});

check('upper-cases refs for case-insensitive matching', () => {
  assert.deepEqual(parseTodoContent('a: e05_s02_t01\n').refs, ['E05_S02_T01']);
});

check('tolerates CRLF line endings and trailing whitespace', () => {
  assert.deepEqual(parseTodoContent('a: E01_S01  \r\nb: E02_S02\r\n').refs, ['E01_S01', 'E02_S02']);
});

check('records entries with titles and line numbers', () => {
  const { entries } = parseTodoContent('# Todo\nMy mission: E07_S03_T02\n');
  assert.equal(entries.length, 1);
  assert.equal(entries[0].ref, 'E07_S03_T02');
  assert.equal(entries[0].title, 'My mission');
  assert.equal(entries[0].line, 2);
});

check('entry line numbers survive a multi-line comment earlier in the file', () => {
  const { entries } = parseTodoContent(
    '# Todo\n<!-- a three\nline balanced\ncomment -->\nMy mission: E07_S03_T02\n'
  );
  assert.equal(entries.length, 1);
  assert.equal(entries[0].line, 5, 'the entry is on line 5 of the original content');
});

// ---------------------------------------------------------------------------------------------
// 3. readTodoRefs — filesystem behavior
// ---------------------------------------------------------------------------------------------
console.log('readTodoRefs:');

const fixtureDir = fs.mkdtempSync(path.join(__dirname, 'todo-test-fixture-'));
try {
  check('missing file reports exists:false with no refs and does not throw', () => {
    const result = readTodoRefs(path.join(fixtureDir, 'does-not-exist.md'));
    assert.equal(result.exists, false);
    assert.deepEqual(result.refs, []);
    assert.equal(result.error, undefined, 'a simply-absent file is not an error condition');
  });

  check('explicit path is read and parsed', () => {
    const p = path.join(fixtureDir, 'todo.md');
    fs.writeFileSync(p, '# Todo\nqueued thing: E11_S02_T03\n<!-- done: E11_S02_T04 -->\n');
    const result = readTodoRefs(p);
    assert.equal(result.exists, true);
    assert.equal(result.path, p);
    assert.deepEqual(result.refs, ['E11_S02_T03']);
  });

  check('an unreadable path (a directory) reports exists:false instead of throwing', () => {
    const result = readTodoRefs(fixtureDir);
    assert.equal(result.exists, false);
    assert.deepEqual(result.refs, []);
    assert.ok(result.error, 'the failure reason should be surfaced, not thrown');
  });
} finally {
  fs.rmSync(fixtureDir, { recursive: true, force: true });
}

// ---------------------------------------------------------------------------------------------
// 4. The real project/todo.md — the properties that matter in production
// ---------------------------------------------------------------------------------------------
console.log("readTodoRefs against this repo's real project/todo.md:");

const realTodoPath = path.join(REPO_ROOT, 'project', 'todo.md');

if (!fs.existsSync(realTodoPath)) {
  console.log(`  skipped — no ${realTodoPath} in this checkout (not a failure)`);
} else {
  const real = readTodoRefs(realTodoPath);
  const raw = fs.readFileSync(realTodoPath, 'utf8');

  check('real file parses with exists:true and a non-empty ref set', () => {
    assert.equal(real.exists, true);
    assert.ok(real.refs.length > 0, 'the live todo.md has active entries, so refs should not be empty');
  });

  check('every ref is a well-formed story or task id', () => {
    for (const ref of real.refs) {
      assert.ok(/^E\d+_S\d+(_T\d+)?$/.test(ref), `malformed ref extracted: ${ref}`);
    }
  });

  check('no ref is harvested from a comment line', () => {
    // Collect every ref that appears ONLY inside <!-- ... --> comment lines, and assert none of
    // them made it into the result. This is derived from the live file, so it keeps testing
    // whatever the file actually contains rather than a hardcoded snapshot of it.
    const commentedRefs = new Set();
    const activeRefs = new Set(real.refs);
    for (const line of raw.split(/\r?\n/)) {
      if (!line.trim().startsWith('<!--')) continue;
      for (const m of line.match(/E\d+_S\d+(?:_T\d+)?/g) || []) commentedRefs.add(m.toUpperCase());
    }
    const leaked = [...commentedRefs].filter(
      (ref) => activeRefs.has(ref) && !raw.split(/\r?\n/).some((l) => !l.trim().startsWith('<!--') && l.trim().endsWith(ref))
    );
    assert.deepEqual(leaked, [], `refs leaked out of comment lines: ${leaked.join(', ')}`);
  });

  check('every entry line number points at the line that actually holds its ref', () => {
    // The whole point of the newline-preserving strip: a 1-based entries[].line must index back
    // into the ORIGINAL file. Checked against live data, which contains several multi-line comments.
    const lines = raw.split(/\r?\n/);
    for (const entry of real.entries) {
      const actual = lines[entry.line - 1];
      assert.ok(
        actual !== undefined && actual.toUpperCase().includes(entry.ref),
        `entry for ${entry.ref} claims line ${entry.line}, but that line is: ${JSON.stringify(actual)}`
      );
    }
  });

  check('no ref is harvested from a rapport path cited mid-line', () => {
    // Any ref that only ever appears immediately followed by a '-' or '/' (i.e. inside a filename
    // or path) must not be in the result set.
    const pathOnlyRefs = new Set();
    for (const m of raw.match(/E\d+_S\d+(?:_T\d+)?[-/]/g) || []) {
      pathOnlyRefs.add(m.slice(0, -1).toUpperCase());
    }
    const lines = raw.split(/\r?\n/);
    for (const ref of pathOnlyRefs) {
      const alsoQueued = lines.some((l) => !l.trim().startsWith('<!--') && l.trim().endsWith(`: ${ref}`));
      if (alsoQueued) continue; // legitimately queued elsewhere by its own entry line
      assert.ok(
        !real.refs.includes(ref),
        `${ref} appears only inside a path/filename but was reported as queued`
      );
    }
  });

  console.log(`  (parsed ${real.refs.length} queued refs from ${realTodoPath})`);
}

// ---------------------------------------------------------------------------------------------
console.log('');
if (failures > 0) {
  console.error(`todo.test.js: ${failures} check(s) FAILED`);
  process.exit(1);
}
console.log('todo.test.js: all checks passed');

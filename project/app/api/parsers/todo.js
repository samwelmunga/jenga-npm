/**
 * @file project/app/api/parsers/todo.js
 *
 * Reads the invoking project's `project/todo.md` and extracts the board refs its **active**
 * (non-comment) entries name, so the dashboard can tell which board items the user has already
 * queued for execution. Consumed by `parsers/board.js`, which tags each matching epic/story/task
 * with `_queued: true` (E06_S05_T04) — the Active Sprint tab's In Progress column promotes those
 * items even though their board status hasn't moved yet.
 *
 * ── Path resolution ───────────────────────────────────────────────────────────────────────────
 * `todo.md` is resolved via `resolveProjectRoot()` (`../lib/resolve-project-root.js`), exactly the
 * way `parsers/board.js` resolves `BOARD_ROOT` — never a fixed `path.resolve(__dirname, '../../..')`
 * climb. A `__dirname` climb only ever lands correctly inside this monorepo's own checkout; from a
 * consumer's `node_modules/@jenga-ai/agent/` it lands inside or above `node_modules` and silently
 * reads the wrong file (or none). That is the exact E46 / E47_S02 defect pattern.
 *
 * Unlike `board.js`, the path is resolved **inside** `readTodoRefs()` rather than at module load.
 * Two reasons: requiring this module can then never throw at import time (a board read must not be
 * taken down by an unresolvable root before the route handler can even produce an error envelope),
 * and tests can pass an explicit path without touching `JENGA_PROJECT_ROOT`. Since `server.js`
 * pins the resolved root into that env var before any parser loads, the per-call resolution is a
 * cheap env-var read, not a repeated filesystem walk.
 *
 * ── Line shapes in the real file ──────────────────────────────────────────────────────────────
 * `project/todo.md`'s documented format is `<mission title>: <E##_S##>` with the ref **optional**
 * (its own header comment says so). The live file contains all of these, and all of them must be
 * handled:
 *
 *   1. `Implement set-break.sh and clear-break.sh: E44_S01_T02`     → task ref, extracted
 *   2. `Handoff document schema & ... checkpoint: E23_S01`          → story ref, extracted
 *   3. `invoke /brainstorm project/rapports/analysis/...md`         → no ref, ignored
 *   4. `<!-- RECONCILED: ...: E32_S01_T01 -->`                      → comment, skipped entirely
 *   5. `# Todo` / `<!-- Format: ... -->` / blank lines               → ignored
 *   6. `Fix hardcoded project/ paths ... (see project/rapports/problems/E31_S05_T01-hidden-mode-path-resolution-gaps.md, F1/F2): E34`
 *
 * Shape 6 is why the ref pattern is **end-anchored and colon-preceded** rather than "any ref
 * anywhere in the line": that single real line both embeds `E31_S05_T01` inside a rapport filename
 * and ends in the epic-only ref `E34`. A loose `/E\d+_S\d+(_T\d+)?/g` scan would spuriously report
 * `E31_S05_T01` as queued — a board item that line is merely *citing*, not queueing.
 *
 * ── Epic-only refs are deliberately not matched ───────────────────────────────────────────────
 * A trailing `E##` (e.g. `E34`, `E15_S04` is a story so it matches, but bare `E34` does not) is
 * ignored. E06_S05_T04's Acceptance Criteria scope resolvable refs to `E##_S##` / `E##_S##_T##`,
 * and its Description states a ref "may point at a story or at a task". Promoting a whole epic off
 * a single queued line would also drag an item with a much wider blast radius into the In Progress
 * column than the user queued. This is a decision, not an oversight.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

/**
 * Matches a whole line of the documented `<mission title>: <ref>` form, where `<ref>` is a story or
 * task id and is the last non-whitespace token on the line. `.*?` for the title is lazy but the
 * `$` anchor forces the ref to be the final token regardless. Case-insensitive so a hand-typed
 * `e06_s05_t04` still resolves; refs are upper-cased on the way out and `board.js` matches ids
 * case-insensitively too, so the whole path is case-agnostic.
 */
const TODO_ENTRY_PATTERN = /^(.*?):[ \t]*(E\d+_S\d+(?:_T\d+)?)[ \t]*$/i;

/** A balanced HTML comment block, `s`-flag-free so it works on older Node too. */
const HTML_COMMENT_BLOCK = /<!--[\s\S]*?-->/g;

/**
 * Removes every balanced `<!-- ... -->` block, then drops everything from an unterminated trailing
 * `<!--` onward (matching how a browser/markdown renderer treats it: the rest of the document is
 * commented out). Blocks are replaced with a single space rather than deleted so a comment that
 * opens mid-line can't silently glue the surrounding text into a fake `title: ref` pair.
 *
 * The replacement is **newline-preserving**: a block spanning N newlines is replaced with a space
 * followed by those N newlines, so every surviving line keeps its original 1-based line number and
 * any text trailing a multi-line comment's `-->` stays on the line it was actually written on.
 * Collapsing the block to a bare space instead (the original behavior) shifted every subsequent
 * line up by N, which made `parseTodoContent`'s `entries[].line` wrong for any file containing a
 * multi-line comment — and `project/todo.md` contains several.
 *
 * The dangling-open truncation needs no equivalent treatment: it only ever discards lines *after*
 * the unterminated `<!--`, so the line numbers of everything that survives are untouched.
 *
 * @param {string} content
 * @returns {string}
 */
function stripComments(content) {
  const withoutBalanced = String(content == null ? '' : content).replace(
    HTML_COMMENT_BLOCK,
    (block) => ' ' + '\n'.repeat((block.match(/\n/g) || []).length)
  );
  const danglingOpen = withoutBalanced.indexOf('<!--');
  return danglingOpen === -1 ? withoutBalanced : withoutBalanced.slice(0, danglingOpen);
}

/**
 * Pure parse of `todo.md` content into the board refs its active entries name.
 *
 * @param {string} content raw file content
 * @returns {{ refs: string[], entries: { title: string, ref: string, line: number }[] }}
 *   `refs` is upper-cased and de-duplicated, in first-appearance order. `entries` keeps every
 *   matching line for debuggability; its 1-based `line` numbers always match the original content,
 *   since `stripComments` preserves the newlines of the blocks it removes.
 */
function parseTodoContent(content) {
  const lines = stripComments(content).split(/\r?\n/);
  const entries = [];
  const seen = new Set();
  const refs = [];

  lines.forEach((rawLine, index) => {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) return;

    const match = TODO_ENTRY_PATTERN.exec(line);
    if (!match) return;

    const title = match[1].trim();
    const ref = match[2].toUpperCase();

    entries.push({ title, ref, line: index + 1 });
    if (!seen.has(ref)) {
      seen.add(ref);
      refs.push(ref);
    }
  });

  return { refs, entries };
}

/**
 * Absolute path to the invoking project's `project/todo.md`.
 * @returns {string}
 */
function resolveTodoPath() {
  return path.join(resolveProjectRoot(), 'project', 'todo.md');
}

/**
 * Read and parse the project's `todo.md`.
 *
 * A missing file is a first-class, non-exceptional case: it returns `{ exists: false, refs: [] }`,
 * which makes every downstream consumer behave exactly as it did before this feature existed. An
 * unreadable file (permissions, a directory where a file was expected) is likewise reported as
 * `exists: false` with the reason attached, never thrown — a broken `todo.md` must not be able to
 * take down `GET /v1/board`.
 *
 * @param {string} [filePath] explicit path; defaults to `<projectRoot>/project/todo.md`
 * @returns {{ exists: boolean, path: string, refs: string[], entries: Object[], error?: string }}
 */
function readTodoRefs(filePath) {
  let todoPath;
  try {
    todoPath = filePath || resolveTodoPath();
  } catch (err) {
    return { exists: false, path: '', refs: [], entries: [], error: err.message };
  }

  let raw;
  try {
    raw = fs.readFileSync(todoPath, 'utf8');
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn(`[todo] Could not read ${todoPath} — ${err.message}`);
      return { exists: false, path: todoPath, refs: [], entries: [], error: err.message };
    }
    return { exists: false, path: todoPath, refs: [], entries: [] };
  }

  const { refs, entries } = parseTodoContent(raw);
  return { exists: true, path: todoPath, refs, entries };
}

module.exports = {
  readTodoRefs,
  parseTodoContent,
  stripComments,
  resolveTodoPath,
  TODO_ENTRY_PATTERN,
};

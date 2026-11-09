/**
 * @file project/app/api/parsers/lib/board-id-sort.js
 * Numeric natural ordering for scrum-board IDs and names that start with one (epic E86, task E86_S02_T02).
 *
 * JavaScript twin of `board_id_sort_key` in scripts/lib/board_ids.py and `board_id_sort` in
 * scripts/lib/board-ids.sh. The dashboard API cannot import either, so the rules are restated here and
 * tests/fixtures/board-id-sort-cases.json is the single case list all three implementations must reproduce
 * (see board-id-sort.test.js).
 *
 * Rules:
 *   - A name starts with a board ID (E##, E##_S##, E##_S##_T##, any digit width) that must end at the end of
 *     the name, at "_" or at ".": `E10x.md` is not epic 10, `E10_S1x.md` is epic 10 and `E10_S1_Tx.md` is
 *     story E10_S1.
 *   - Epic, story and task numbers compare as integers (leading zeros ignored), at any width.
 *   - A missing deeper segment sorts before a present one (the epic before its stories).
 *   - Ties (equal numbers, e.g. E1.md / E01.md, or different slugs) are broken by the full name's text,
 *     compared by code point.
 *   - A name that is not a board ID sorts after every board ID, then by text.
 *
 * CommonJS, Node standard library only (none is actually needed). Never mutates its input.
 */

'use strict';

const END = '(?=[_.]|$)';
// `$` without the `m` flag matches only at the very end, and `\d` is ASCII-only in JavaScript, which
// mirrors the Python `\Z` / re.ASCII behaviour.
const SORT_ID_RE = new RegExp(`^E(\\d+)(?:_S(\\d+)(?:_T(\\d+)${END})?${END})?${END}`);

/** Code-point order (what Python str comparison and `LC_ALL=C sort` give), unlike `<` on UTF-16 code units. */
function compareText(a, b) {
  const ia = a[Symbol.iterator]();
  const ib = b[Symbol.iterator]();
  for (;;) {
    const x = ia.next();
    const y = ib.next();
    if (x.done || y.done) {
      if (x.done && y.done) return 0;
      return x.done ? -1 : 1;
    }
    if (x.value !== y.value) {
      return x.value.codePointAt(0) < y.value.codePointAt(0) ? -1 : 1;
    }
  }
}

/**
 * Sort key for a board ID or a name that starts with one: `[kind, epic, story, task, name]`.
 * kind is 0 for a board ID and 1 otherwise; epic/story/task are BigInt (exact at any digit width),
 * -1n for a missing segment and 0n throughout for a non-ID. Compare keys with `compareBoardIds`
 * semantics, not by stringifying them.
 */
function boardIdSortKey(name) {
  const text = String(name);
  const m = SORT_ID_RE.exec(text);
  if (!m) return [1, 0n, 0n, 0n, text];
  const [epic, story, task] = [m[1], m[2], m[3]].map((g) => (g === undefined ? -1n : BigInt(g)));
  return [0, epic, story, task, text];
}

/** Comparator for Array.prototype.sort: negative, zero or positive, consistent with boardIdSortKey. */
function compareBoardIds(a, b) {
  const ka = boardIdSortKey(a);
  const kb = boardIdSortKey(b);
  for (let i = 0; i < 4; i += 1) {
    if (ka[i] < kb[i]) return -1;
    if (ka[i] > kb[i]) return 1;
  }
  return compareText(ka[4], kb[4]);
}

/** Returns a new array in numeric natural order; the input array is left untouched. */
function sortBoardIds(names) {
  return Array.from(names).sort(compareBoardIds);
}

module.exports = { compareBoardIds, boardIdSortKey, sortBoardIds };

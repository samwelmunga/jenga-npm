/**
 * @file project/app/api/parsers/board.js
 * Parses markdown files from project/board/ into a nested epic→story→task tree.
 *
 * E06_S05_T04 — each item whose id is named by an active entry in the project's `project/todo.md`
 * additionally carries `_queued: true`. This is purely *informational* provenance ("the user has
 * queued this for execution"); the decision of what to do with it belongs to the consumer. The
 * Active Sprint tab's column logic (`project/app/ui/src/components/board/kanbanColumns.js`) uses it
 * to promote `Pending`/`Backlog` items into the In Progress column; the Backlog tab ignores it
 * entirely. Items that aren't referenced get **no new field at all**, so a project with no
 * `todo.md` produces a byte-identical payload to the pre-T04 parser.
 *
 * E76_S03_T06 — frontmatter keys reach the response generically (`...data` below, no whitelist), so
 * the per-task `usage_*` fields and the per-story `usage_*` fields of `templates/SCRUM_BOARD_SCHEMA.md`
 * ("Usage fields (per-task token accounting)", "Usage fields on stories") need no code here: an item
 * that carries them returns them with their numeric values, and an item that does not stays without
 * them (absent, never `null`, never `0`, so a consumer can say "not measured"). Do not add defaults
 * or coercion for those keys. Covered by `board.usage-fields.test.js`.
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');
const { resolveProjectRoot } = require('../lib/resolve-project-root');
const { readTodoRefs } = require('./todo');
const { sortBoardIds } = require('./lib/board-id-sort');

// Resolved relative to the invoking project's own root (E47_S02_T01/T02), not a fixed __dirname
// climb — the old `path.resolve(__dirname, '../../../board')` only ever landed correctly when this
// module ran from this monorepo's own checkout.
const BOARD_ROOT = path.join(resolveProjectRoot(), 'project', 'board');

/**
 * Read all .md files from a directory (non-recursive), in numeric board-ID order of their file
 * names (E86_S02_T05): `E101` before `E1001`, `S10` before `S100`. `fs.readdirSync` order is
 * filesystem-dependent, so the sort is always applied here; `parseBoard()` builds the epic, story and
 * task lists by pushing in this order, so every level of the returned tree inherits it.
 * @param {string} dir
 * @returns {{ file: string, data: Object, content: string }[]}
 */
function readMarkdownDir(dir) {
  if (!fs.existsSync(dir)) return [];
  return sortBoardIds(fs.readdirSync(dir).filter((f) => f.endsWith('.md')))
    .map((f) => {
      const filePath = path.join(dir, f);
      try {
        const raw = fs.readFileSync(filePath, 'utf8');
        const parsed = matter(raw);
        return { file: f, data: parsed.data, content: parsed.content.trim() };
      } catch (err) {
        console.warn(`[board] Skipping malformed file: ${filePath} — ${err.message}`);
        return null;
      }
    })
    .filter(Boolean);
}

/**
 * Board ids referenced by active entries in the project's `project/todo.md`, as an upper-cased Set
 * for case-insensitive lookup (E06_S05_T04).
 *
 * Failure-tolerant by design: `readTodoRefs()` already reports a missing/unreadable file as
 * `exists: false` rather than throwing, and this extra guard covers anything unexpected beyond that
 * (e.g. an unresolvable project root). A broken or absent `todo.md` degrades to "nothing is queued"
 * — i.e. exactly the pre-T04 behavior — and never turns a working board read into a 500.
 *
 * @returns {Set<string>}
 */
function loadQueuedIds() {
  try {
    const { refs } = readTodoRefs();
    return new Set(refs.map((r) => String(r).toUpperCase()));
  } catch (err) {
    console.warn(`[board] Could not read todo.md refs — ${err.message}. No items will be marked queued.`);
    return new Set();
  }
}

/**
 * `{ _queued: true }` if `id` is queued, otherwise an empty object — spread into an item so
 * unreferenced items keep their exact pre-T04 shape (no `_queued: false` noise).
 * @param {Set<string>} queuedIds
 * @param {string|undefined} id
 * @returns {{ _queued?: boolean }}
 */
function queuedFlagFor(queuedIds, id) {
  return typeof id === 'string' && queuedIds.has(id.toUpperCase()) ? { _queued: true } : {};
}

/**
 * Parse the full board into an array of epic objects with nested stories and tasks.
 * @returns {Promise<Object[]>}
 */
async function parseBoard() {
  const queuedIds = loadQueuedIds();

  const epicsDir  = path.join(BOARD_ROOT, 'epics');
  const storiesDir = path.join(BOARD_ROOT, 'stories');
  const tasksDir  = path.join(BOARD_ROOT, 'tasks');

  const epicFiles  = readMarkdownDir(epicsDir);
  const storyFiles = readMarkdownDir(storiesDir);
  const taskFiles  = readMarkdownDir(tasksDir);

  // Build tasks map keyed by story_id
  const tasksByStory = {};
  for (const t of taskFiles) {
    const sid = t.data.story_id;
    if (!sid) continue;
    if (!tasksByStory[sid]) tasksByStory[sid] = [];
    tasksByStory[sid].push({
      ...t.data,
      ...queuedFlagFor(queuedIds, t.data.id),
      _content: t.content,
      _file: t.file,
    });
  }

  // Build stories map keyed by epic_id
  const storiesByEpic = {};
  for (const s of storyFiles) {
    const eid = s.data.epic_id;
    if (!eid) continue;
    if (!storiesByEpic[eid]) storiesByEpic[eid] = [];
    const storyId = s.data.id;
    storiesByEpic[eid].push({
      ...s.data,
      ...queuedFlagFor(queuedIds, storyId),
      _content: s.content,
      _file: s.file,
      tasks: storyId ? (tasksByStory[storyId] || []) : [],
    });
  }

  // Build epic objects
  const epics = epicFiles.map((e) => {
    const epicId = e.data.id;
    return {
      ...e.data,
      ...queuedFlagFor(queuedIds, epicId),
      _content: e.content,
      _file: e.file,
      stories: epicId ? (storiesByEpic[epicId] || []) : [],
    };
  });

  return epics;
}

module.exports = { parseBoard };

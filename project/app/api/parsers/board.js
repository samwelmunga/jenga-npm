/**
 * @file project/app/api/parsers/board.js
 * Parses markdown files from project/board/ into a nested epic→story→task tree.
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');

const BOARD_ROOT = path.resolve(__dirname, '../../../board');

/**
 * Read all .md files from a directory (non-recursive).
 * @param {string} dir
 * @returns {{ file: string, data: Object, content: string }[]}
 */
function readMarkdownDir(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.md'))
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
 * Parse the full board into an array of epic objects with nested stories and tasks.
 * @returns {Promise<Object[]>}
 */
async function parseBoard() {
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
    tasksByStory[sid].push({ ...t.data, _content: t.content, _file: t.file });
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
      _content: e.content,
      _file: e.file,
      stories: epicId ? (storiesByEpic[epicId] || []) : [],
    };
  });

  return epics;
}

module.exports = { parseBoard };

/**
 * @file project/app/api/lib/resolve-project-title.js
 *
 * E47_S09_T01 — the ONE shared resolver for the dashboard's project name. Used by
 * `routes/health.js` (so `/v1/health` `projectName`, the UI `<title>`, the header, and — because
 * `capture-snapshot.js` calls that route — the `--snapshot` export all agree).
 *
 * Resolution order (first usable value wins; a source that is missing, unreadable or yields only
 * generic words is skipped, never fatal):
 *   1. Strategy document — path from `paths.strategy` in `project/configs/workflow.json`
 *      (default `project/documentation/STRATEGY.md`). An explicit name field wins
 *      (`Project: X`, `Project name: X`, optionally bold, as a line of its own);
 *      otherwise the first `# ` heading, after stripping generic words. Generic words are
 *      `strategy`, `brief`, `document`, `overview`, `plan`, `roadmap` plus separators, so
 *      "# Jenga AI Strategy" -> "Jenga AI", "# Strategy: Acme" -> "Acme", and the stock
 *      "# Strategy Brief" -> nothing (falls through to the next source).
 *   2. README.md — first `# ` heading (outside code fences), markdown emphasis/links/images/HTML
 *      stripped.
 *   3. Git repository name — repo name from the `origin` remote URL (without `.git`), else the
 *      basename of the git toplevel. The remote is preferred because a worktree or a renamed
 *      checkout directory (e.g. `bundle-E47_S09`) is not the project's name.
 *   4. `package.json` `name` — last resort (an npm package name is often a slug and, in this
 *      monorepo, the published package name rather than the project's).
 *   5. `DEFAULT_TITLE` ("Jenga AI"). The result is therefore always a non-empty string, never
 *      "undefined".
 *
 * Works in a consumer install: the project root comes from `resolveProjectRoot()` (or an explicit
 * `root` option); no dependency beyond Node built-ins and `git` (optional).
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { resolveProjectRoot } = require('./resolve-project-root');

const DEFAULT_TITLE = 'Jenga AI';
const DEFAULT_STRATEGY_PATH = path.join('project', 'documentation', 'STRATEGY.md');
const GENERIC_WORDS = new Set(['strategy', 'brief', 'document', 'overview', 'plan', 'roadmap']);

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

/** Strip inline markdown/HTML so a heading becomes plain text. */
function cleanInline(text) {
  return String(text)
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]*>/g, '')
    .replace(/[*_`~]/g, '')
    .replace(/\s+#+\s*$/, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/** First `# ` heading outside fenced code blocks, as plain text (or null). */
function firstH1(markdown) {
  let fenced = false;
  for (const line of markdown.split(/\r?\n/)) {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    const m = /^#\s+(.+)$/.exec(line);
    if (m) {
      const text = cleanInline(m[1]);
      if (text) return text;
    }
  }
  return null;
}

/** Remove generic words (and the separators around them) from a strategy heading. */
function stripGeneric(heading) {
  const words = heading.split(/\s+/).filter((w) => !GENERIC_WORDS.has(w.replace(/[^A-Za-z]/g, '').toLowerCase()));
  return words
    .join(' ')
    .replace(/^[\s:\-–—|]+/, '')
    .replace(/[\s:\-–—|]+$/, '')
    .trim();
}

/** Name from a strategy document: explicit field first, else cleaned first H1. */
function titleFromStrategy(markdown) {
  const field = /^\s*(?:[-*]\s+)?\**project(?:\s+name)?\**\s*:\s*\**\s*(.+?)\s*$/im.exec(markdown);
  if (field) {
    const explicit = cleanInline(field[1]);
    if (explicit) return explicit;
  }
  const h1 = firstH1(markdown);
  if (!h1) return null;
  return stripGeneric(h1) || null;
}

function strategyPath(root) {
  let rel = DEFAULT_STRATEGY_PATH;
  try {
    const cfg = JSON.parse(readText(path.join(root, 'project', 'configs', 'workflow.json')));
    const configured = cfg && cfg.paths && cfg.paths.strategy;
    if (typeof configured === 'string' && configured.trim()) rel = configured.trim();
  } catch {
    // no / unreadable workflow.json -> default
  }
  return path.resolve(root, rel);
}

function git(root, args) {
  try {
    return execFileSync('git', ['-C', root, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    }).trim();
  } catch {
    return '';
  }
}

/** Repository name: origin remote's last path segment (minus .git), else git toplevel basename. */
function gitRepoName(root) {
  const url = git(root, ['config', '--get', 'remote.origin.url']);
  if (url) {
    const seg = url.replace(/[\\/]+$/, '').split(/[\\/:]/).pop().replace(/\.git$/, '');
    if (seg) return seg;
  }
  const top = git(root, ['rev-parse', '--show-toplevel']);
  return top ? path.basename(top) : null;
}

function packageName(root) {
  try {
    const pkg = JSON.parse(readText(path.join(root, 'package.json')));
    if (pkg && typeof pkg.name === 'string' && pkg.name.trim()) return pkg.name.trim();
  } catch {
    // missing / unparsable
  }
  return null;
}

/**
 * @param {Object} [options]
 * @param {string} [options.root] project root (defaults to `resolveProjectRoot()`)
 * @returns {string} always a non-empty string
 */
function resolveProjectTitle({ root } = {}) {
  let projectRoot = root;
  if (!projectRoot) {
    try {
      projectRoot = resolveProjectRoot();
    } catch {
      return DEFAULT_TITLE;
    }
  }
  const strategy = readText(strategyPath(projectRoot));
  const fromStrategy = strategy && titleFromStrategy(strategy);
  if (fromStrategy) return fromStrategy;

  const readme = readText(path.join(projectRoot, 'README.md'));
  const fromReadme = readme && firstH1(readme);
  if (fromReadme) return fromReadme;

  return gitRepoName(projectRoot) || packageName(projectRoot) || DEFAULT_TITLE;
}

module.exports = { resolveProjectTitle, titleFromStrategy, firstH1, stripGeneric, gitRepoName, DEFAULT_TITLE };

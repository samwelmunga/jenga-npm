#!/usr/bin/env node
/**
 * build-snapshot-html.cjs
 *
 * Turns an already-built dashboard `dist/` into ONE self-contained HTML file
 * with a captured data snapshot embedded inline — with zero dependencies, so it
 * runs identically in this monorepo and in a consumer's node_modules.
 *
 * Why this replaced the vite path
 * -------------------------------
 * `--snapshot` used to shell out to `npm run build:snapshot` (vite build --mode
 * snapshot) inside project/app/ui. That can only ever work in this monorepo:
 * the published tarball ships `project/app/ui/dist/**` and `scripts/**` and
 * nothing else — no package.json, no vite.config.js, no src/ — so there is no
 * vite to run and no sources to build. `--snapshot` was therefore dead on every
 * consumer install, and the bats suite could not see it because it faked `npm`
 * on PATH.
 *
 * Inlining a prebuilt dist needs no build tooling at all, so the SAME code path
 * now runs in both places. That is the point: the consumer path is no longer a
 * separate, never-exercised branch — every local `--snapshot` run exercises it.
 *
 * What it does, given <dist>/index.html:
 *   1. Inlines every <script src> into <script> with the file's contents.
 *   2. Inlines every <link rel=stylesheet href> into <style>.
 *   3. Drops <link rel=modulepreload> — the module it preloads is now inline.
 *   4. Injects the captured JSON as
 *      <script id="jenga-dashboard-data" type="application/json"> before </head>,
 *      which src/api/client.js's get() already reads instead of calling fetch()
 *      whenever it is present. That runtime branch is NOT build-mode-gated, so
 *      the ordinary `vite build` output is already snapshot-capable.
 *   5. Fails loudly if any local asset reference survives, so a future UI change
 *      that adds an image/font/chunk can never silently ship a broken snapshot.
 *
 * Usage:
 *   node build-snapshot-html.cjs --dist <dir> --data <json> --out <html>
 */

'use strict';

const fs = require('fs');
const path = require('path');

function die(msg) {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

// ── Parse args ───────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const opts = { dist: '', data: '', out: '' };

for (let i = 0; i < args.length; i++) {
  const flag = args[i];
  if (flag === '--dist' || flag === '--data' || flag === '--out') {
    const value = args[++i];
    if (value === undefined) die(`${flag} requires a value`);
    opts[flag.slice(2)] = value;
  } else if (flag === '-h' || flag === '--help') {
    console.log('Usage: build-snapshot-html.cjs --dist <dir> --data <json> --out <html>');
    process.exit(0);
  } else {
    die(`unknown argument: ${flag}`);
  }
}

for (const required of ['dist', 'data', 'out']) {
  if (!opts[required]) die(`--${required} is required`);
}

const DIST_DIR = path.resolve(opts.dist);
const INDEX_HTML = path.join(DIST_DIR, 'index.html');

if (!fs.existsSync(INDEX_HTML)) {
  die(
    `no built dashboard found at ${INDEX_HTML}. ` +
      'In this monorepo run `npm run ui:build --prefix project/app`; in a consumer install ' +
      'this means the package shipped without project/app/ui/dist (a packaging regression).'
  );
}

// ── Read the captured data ───────────────────────────────────────────────────
// Parse rather than pass through, so a malformed capture artifact fails here,
// loudly, instead of producing a snapshot that only breaks once opened.
let snapshotData;
try {
  snapshotData = JSON.parse(fs.readFileSync(opts.data, 'utf8'));
} catch (err) {
  die(`could not read/parse snapshot data at ${opts.data}: ${err.message}`);
}

let html = fs.readFileSync(INDEX_HTML, 'utf8');

/**
 * Resolves an asset reference from index.html to a path on disk. Vite emits
 * root-absolute refs ("/assets/index-abc.js") by default, but a custom `base`
 * can make them relative ("./assets/...") — both resolve against dist.
 * Returns null for anything we must not try to inline (protocol-absolute URLs,
 * data: URIs), which the caller leaves untouched.
 */
function resolveAsset(ref) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(ref) || ref.startsWith('//')) return null;
  const relative = ref.replace(/^\//, '').replace(/^\.\//, '').split('?')[0].split('#')[0];
  return path.join(DIST_DIR, relative);
}

function readAsset(ref, kind) {
  const assetPath = resolveAsset(ref);
  if (assetPath === null) return null;
  if (!fs.existsSync(assetPath)) {
    die(`${kind} referenced by index.html not found on disk: ${ref} (resolved to ${assetPath})`);
  }
  return fs.readFileSync(assetPath, 'utf8');
}

// Escapes a closing tag inside inlined content so it cannot terminate the
// wrapper element early. `<\/script` is valid inside a JS string literal and
// parses identically; the same trick applies to `</style` in CSS.
function escapeClosingTag(content, tagName) {
  return content.replace(new RegExp(`</${tagName}`, 'gi'), `<\\/${tagName}`);
}

function attr(tag, name) {
  const match = tag.match(new RegExp(`\\b${name}=["']([^"']*)["']`, 'i'));
  return match ? match[1] : null;
}

// ── 1. Inline <script src="..."> ─────────────────────────────────────────────
html = html.replace(/<script\b([^>]*)\bsrc=["']([^"']+)["']([^>]*)><\/script>/gi, (tag, pre, src, post) => {
  const code = readAsset(src, 'script');
  if (code === null) return tag; // external URL — leave as-is
  // Preserve type="module": the dist bundle is ESM and breaks when run as a
  // classic script. crossorigin is dropped; it is meaningless once inline.
  const isModule = /type=["']module["']/i.test(pre + post);
  const typeAttr = isModule ? ' type="module"' : '';
  return `<script${typeAttr}>\n${escapeClosingTag(code, 'script')}\n</script>`;
});

// ── 2 & 3. Inline stylesheets, drop modulepreload ────────────────────────────
html = html.replace(/<link\b[^>]*>/gi, (tag) => {
  const rel = (attr(tag, 'rel') || '').toLowerCase();
  if (rel === 'modulepreload' || rel === 'preload') return '';
  if (rel !== 'stylesheet') return tag; // icons, manifests, etc. stay untouched
  const href = attr(tag, 'href');
  if (!href) return tag;
  const css = readAsset(href, 'stylesheet');
  if (css === null) return tag;
  return `<style>\n${escapeClosingTag(css, 'style')}\n</style>`;
});

// ── 4. Inject the captured snapshot data ─────────────────────────────────────
// Escaping every '<' as its JSON unicode escape keeps the payload from
// prematurely closing its own <script> tag, whatever the board/history
// content happens to contain.
const serialized = JSON.stringify(snapshotData).replace(/</g, '\\u003c');
const dataTag = `<script id="jenga-dashboard-data" type="application/json">${serialized}</script>`;

if (!/<\/head>/i.test(html)) {
  die(`${INDEX_HTML} has no </head> to inject the snapshot data before`);
}
// A replacer FUNCTION, not a string: board content legitimately contains '$&',
// '$`' and similar sequences (markdown code spans like `^[1-5]$`), which a
// string replacement would interpret as backreferences and splice the document
// into itself. A function's return value is used verbatim.
html = html.replace(/<\/head>/i, () => `  ${dataTag}\n  </head>`);

// ── 5. Refuse to emit a snapshot that still points at files it does not carry ─
// Without this, adding (say) a background image to the UI would produce a
// snapshot that looks fine here and renders broken on the recipient's machine.
const leftovers = [...html.matchAll(/\b(?:src|href)=["'](?!data:|https?:|#|\/\/)([^"']+)["']/gi)]
  .map((m) => m[1])
  .filter((ref) => {
    const resolved = resolveAsset(ref);
    return resolved !== null && fs.existsSync(resolved);
  });

// Same check for url() references inside the CSS we just inlined — a font or
// background image reached that way is just as missing on the recipient's
// machine, and never appears as an src=/href= attribute.
for (const match of html.matchAll(/url\(\s*["']?(?!data:|https?:|#|\/\/)([^"')]+)["']?\s*\)/gi)) {
  const resolved = resolveAsset(match[1]);
  if (resolved !== null && fs.existsSync(resolved)) leftovers.push(match[1]);
}

if (leftovers.length > 0) {
  die(
    'snapshot would not be self-contained — these local asset references survived inlining: ' +
      `${[...new Set(leftovers)].join(', ')}. ` +
      'Teach build-snapshot-html.cjs to inline them before shipping this UI change.'
  );
}

// ── Write ────────────────────────────────────────────────────────────────────
fs.mkdirSync(path.dirname(path.resolve(opts.out)), { recursive: true });
fs.writeFileSync(opts.out, html);
console.log(`Inlined single-file dashboard: ${opts.out}`);

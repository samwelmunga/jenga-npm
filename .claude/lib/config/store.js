/**
 * lib/config/store.js - the config store: read, validate, bump, write atomically (E68_S02_T01)
 *
 * The single code path every `jenga config` write goes through. `jenga config set` (lib/commands/config.js) and the
 * interactive flow (lib/config/interactive.js) both call setValue(); neither carries validation or write logic of
 * its own.
 *
 * Exports:
 *   loadContext()                                 { ok, descriptors, configsDir } | { ok: false, code, message }
 *   readConfig(fileId, ctx?)                      resolve a descriptor and read its config file
 *   getValue(fileId, key, ctx?)                   read one key (read-only keys are readable)
 *   parseValue(descriptorKey, rawString)          CLI string -> typed value: { ok, value } | { ok: false, message }
 *   validateValue(descriptorKey, value)           type, min/max, allowed, pattern: { ok, message }
 *   setValue(fileId, key, rawString, ctx?)        validate, bump and write atomically; returns a result object
 *   formatSetResult(result)                       the one-line confirmation both callers print
 *   displayValue(value)                           single-line rendering of a value
 *
 * Result objects carry `code` from the shared exit-code table (lib/config/exit-codes.js; 0 ok, 3 unknown file or
 * key, 4 invalid value, 5 read-only key, 6 config file missing or malformed or configs dir unresolvable, 1 an
 * invalid descriptor) and a `message` for every non-zero code. Success results also carry fileId, key, value,
 * previous, changed and bump ({ key, from, to } or null).
 *
 * setValue order (the skills/j-tools/scripts/tools-entry.sh precedent: validate, replace atomically, never report
 * success on failure):
 *   1. resolve the descriptor: unknown file or key -> 3; a non-editable key -> 5 (before the value is even parsed)
 *   2. read the config file: missing, malformed or a non-integer version counter -> 6
 *   3. parse and validate the value -> 4 on failure (file untouched)
 *   4. build ONE candidate object: the new value, and, when the descriptor declares bump_on_change, the named
 *      counter + 1, so a value and its bump never land separately
 *   5. a value equal to the current one is a successful no-op: no bump, no rewrite
 *   6. serialise as JSON.stringify(obj, null, 2) + "\n", write a temp file in the target's own directory, fsync,
 *      and rename it over the target. On any error the temp file is removed and the original is untouched.
 * No lock: the rename is the atomicity guarantee.
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { chmodSync, closeSync, fsyncSync, openSync, renameSync, statSync, unlinkSync, writeSync } from "fs";
import { basename, dirname, join } from "path";
import { loadDescriptors, loadSchema, validateEntries } from "./descriptors.js";
import { EXIT, EXIT_UNEXPECTED } from "./exit-codes.js";
import { readConfigFile, resolveConfigsDir } from "./paths.js";

const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);
const fail = (code, message) => ({ code, message });

/** Single-line display of any value: strings JSON-quoted, nested values as compact JSON. */
export function displayValue(value) {
  if (value === undefined) return "[not set]";
  return JSON.stringify(value);
}

/**
 * Load every descriptor (all must be valid, as the renderer requires) and resolve the configs directory.
 * Returns { ok: true, descriptors, configsDir } or { ok: false, code, message }.
 */
export function loadContext() {
  let entries;
  let schema;
  try {
    schema = loadSchema();
    entries = loadDescriptors();
  } catch (e) {
    return Object.assign({ ok: false }, fail(EXIT_UNEXPECTED, e.message));
  }
  if (entries.length === 0) {
    return Object.assign({ ok: false }, fail(EXIT_UNEXPECTED, "no config descriptors found; nothing to configure"));
  }
  const broken = validateEntries(entries, schema).filter((r) => r.problems.length > 0);
  if (broken.length > 0) {
    const lines = [];
    broken.forEach((r) => r.problems.forEach((p) => lines.push(`${r.entry.path}: ${p}`)));
    lines.push("invalid descriptors; run scripts/validate-config-descriptors.sh --all");
    return Object.assign({ ok: false }, fail(EXIT_UNEXPECTED, lines.join("\n")));
  }
  const cfgDir = resolveConfigsDir();
  if (!cfgDir.ok) {
    return Object.assign({ ok: false }, fail(EXIT.config_unavailable, `cannot resolve the configs directory: ${cfgDir.message}`));
  }
  return { ok: true, descriptors: entries.map((e) => e.descriptor), configsDir: cfgDir.dir };
}

const fileIdOf = (descriptor) => descriptor.file.replace(/\.json$/, "");

function findDescriptor(ctx, fileId) {
  const descriptor = ctx.descriptors.find((d) => fileIdOf(d) === fileId);
  if (!descriptor) {
    return fail(EXIT.unknown_file_or_key, `unknown config file "${fileId}"; known: ${ctx.descriptors.map(fileIdOf).join(", ")}`);
  }
  return { code: EXIT.ok, descriptor };
}

function findKey(descriptor, fileId, key) {
  const entry = descriptor.keys.find((k) => k.key === key);
  if (!entry) {
    return fail(
      EXIT.unknown_file_or_key,
      `unknown key "${key}" in ${fileId}; known: ${descriptor.keys.map((k) => k.key).join(", ")}`
    );
  }
  return { code: EXIT.ok, entry };
}

function readCurrent(ctx, descriptor) {
  const cfg = readConfigFile(ctx.configsDir, descriptor.file);
  if (cfg.state === "missing") return fail(EXIT.config_unavailable, `config file ${cfg.path} is not present`);
  if (cfg.state === "unreadable") return fail(EXIT.config_unavailable, `config file ${cfg.path} is unreadable (${cfg.message})`);
  return { code: EXIT.ok, value: cfg.value, path: cfg.path };
}

/**
 * Resolve a descriptor and read its config file. Returns { code: 0, descriptor, value, path } or { code, message }
 * (3 unknown file, 6 missing/malformed config or unresolvable configs directory, 1 invalid descriptors).
 */
export function readConfig(fileId, ctx) {
  const c = ctx || loadContext();
  if (c.ok === false) return fail(c.code, c.message);
  const found = findDescriptor(c, fileId);
  if (found.code !== EXIT.ok) return found;
  const cur = readCurrent(c, found.descriptor);
  if (cur.code !== EXIT.ok) return cur;
  return { code: EXIT.ok, descriptor: found.descriptor, value: cur.value, path: cur.path };
}

/**
 * Read one key. Reading is safe, so read-only keys are readable. Returns { code: 0, descriptorKey, value } or
 * { code, message }; a key the descriptor lists but the file lacks is code 3.
 */
export function getValue(fileId, key, ctx) {
  const c = ctx || loadContext();
  if (c.ok === false) return fail(c.code, c.message);
  const found = findDescriptor(c, fileId);
  if (found.code !== EXIT.ok) return found;
  const k = findKey(found.descriptor, fileId, key);
  if (k.code !== EXIT.ok) return k;
  const cur = readCurrent(c, found.descriptor);
  if (cur.code !== EXIT.ok) return cur;
  if (!has(cur.value, key)) {
    return fail(EXIT.unknown_file_or_key, `${fileId}.${key} is listed by its descriptor but not set in ${cur.path}`);
  }
  return { code: EXIT.ok, descriptorKey: k.entry, value: cur.value[key] };
}

/**
 * Turn a CLI string into a typed value for the key's declared type. Integers must match ^-?[0-9]+$ (and be safe
 * integers); booleans accept only "true" or "false"; strings are taken as given. Other types are never editable.
 */
export function parseValue(descriptorKey, rawString) {
  const raw = String(rawString);
  switch (descriptorKey.type) {
    case "integer": {
      if (!/^-?[0-9]+$/.test(raw)) {
        return { ok: false, message: `${descriptorKey.key}: "${raw}" is not an integer` };
      }
      const n = Number(raw);
      if (!Number.isSafeInteger(n)) {
        return { ok: false, message: `${descriptorKey.key}: "${raw}" is outside the safe integer range` };
      }
      return { ok: true, value: n === 0 ? 0 : n };
    }
    case "boolean":
      if (raw === "true") return { ok: true, value: true };
      if (raw === "false") return { ok: true, value: false };
      return { ok: false, message: `${descriptorKey.key}: "${raw}" is not a boolean (use true or false)` };
    case "string":
      return { ok: true, value: raw };
    default:
      return { ok: false, message: `${descriptorKey.key}: a ${descriptorKey.type} value cannot be given on the command line` };
  }
}

function typeMatches(type, value) {
  switch (type) {
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "string":
      return typeof value === "string";
    case "boolean":
      return typeof value === "boolean";
    default:
      return false;
  }
}

/**
 * Check a typed value against the key's type, min/max, allowed and pattern. Every failure message names the key
 * and the violated bound. Returns { ok: true, message: null } or { ok: false, message }.
 */
export function validateValue(descriptorKey, value) {
  const name = descriptorKey.key;
  const bad = (message) => ({ ok: false, message });
  if (!typeMatches(descriptorKey.type, value)) {
    return bad(`${name}: expected ${descriptorKey.type}, got ${displayValue(value)}`);
  }
  if (descriptorKey.type === "integer") {
    if (typeof descriptorKey.min === "number" && value < descriptorKey.min) {
      return bad(`${name}: ${value} is below the minimum of ${descriptorKey.min}`);
    }
    if (typeof descriptorKey.max === "number" && value > descriptorKey.max) {
      return bad(`${name}: ${value} is above the maximum of ${descriptorKey.max}`);
    }
  }
  if (Array.isArray(descriptorKey.allowed) && descriptorKey.allowed.indexOf(value) < 0) {
    return bad(`${name}: ${displayValue(value)} is not one of the allowed values ${descriptorKey.allowed.map(displayValue).join(", ")}`);
  }
  if (descriptorKey.type === "string" && typeof descriptorKey.pattern === "string") {
    if (!new RegExp(descriptorKey.pattern).test(value)) {
      return bad(`${name}: ${displayValue(value)} does not match the required pattern ${descriptorKey.pattern}`);
    }
  }
  return { ok: true, message: null };
}

/** Write text to a temp file next to target and rename it over target. Throws on failure, after cleaning up. */
function writeAtomic(target, text) {
  const tmp = join(dirname(target), `.${basename(target)}.${process.pid}.${Date.now()}.tmp`);
  let fd = null;
  try {
    const mode = statSync(target).mode & 0o777;
    fd = openSync(tmp, "wx", mode);
    writeSync(fd, text);
    fsyncSync(fd);
    closeSync(fd);
    fd = null;
    chmodSync(tmp, mode);
    renameSync(tmp, target);
  } catch (e) {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch (ignored) {
        /* already failing */
      }
    }
    try {
      unlinkSync(tmp);
    } catch (ignored) {
      /* no temp file to remove */
    }
    throw e;
  }
}

/**
 * Validate and write one key. See the header for the order of checks. `ctx` (from loadContext) may be passed to
 * avoid re-resolving descriptors and the configs directory between calls.
 */
export function setValue(fileId, key, rawString, ctx) {
  const c = ctx || loadContext();
  if (c.ok === false) return fail(c.code, c.message);

  const found = findDescriptor(c, fileId);
  if (found.code !== EXIT.ok) return found;
  const k = findKey(found.descriptor, fileId, key);
  if (k.code !== EXIT.ok) return k;
  const entry = k.entry;
  if (entry.editable !== true) {
    return fail(EXIT.read_only_key, `${fileId}.${key} is read-only; see ${entry.pointer}`);
  }

  const cur = readCurrent(c, found.descriptor);
  if (cur.code !== EXIT.ok) return cur;
  const current = cur.value;

  const parsed = parseValue(entry, rawString);
  if (!parsed.ok) return fail(EXIT.invalid_value, parsed.message);
  const checked = validateValue(entry, parsed.value);
  if (!checked.ok) return fail(EXIT.invalid_value, checked.message);

  const previous = has(current, key) ? current[key] : undefined;
  const base = { code: EXIT.ok, fileId, key, value: parsed.value, previous, path: cur.path };
  if (previous === parsed.value) return Object.assign(base, { changed: false, bump: null });

  const candidate = Object.assign({}, current);
  candidate[key] = parsed.value;
  let bump = null;
  if (typeof entry.bump_on_change === "string") {
    const counter = entry.bump_on_change;
    if (!has(current, counter) || !Number.isSafeInteger(current[counter])) {
      return fail(EXIT.config_unavailable, `config file ${cur.path} is malformed: version counter "${counter}" is missing or not an integer`);
    }
    bump = { key: counter, from: current[counter], to: current[counter] + 1 };
    candidate[counter] = bump.to;
  }

  try {
    writeAtomic(cur.path, JSON.stringify(candidate, null, 2) + "\n");
  } catch (e) {
    return fail(EXIT.config_unavailable, `could not write ${cur.path}: ${e.message}`);
  }
  return Object.assign(base, { changed: true, bump });
}

/** The one-line confirmation, e.g. `scope-thresholds.inline_max_files = 4 (threshold_version -> 5)`. */
export function formatSetResult(result) {
  const head = `${result.fileId}.${result.key} = ${displayValue(result.value)}`;
  if (!result.changed) return `${head} (unchanged)`;
  return result.bump ? `${head} (${result.bump.key} -> ${result.bump.to})` : head;
}

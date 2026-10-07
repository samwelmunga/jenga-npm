/**
 * lib/config/render.js - ranked_list rendering for `jenga config` (E68_S01_T04)
 *
 * Exports:
 *   renderConfigFiles(descriptors, configsDir)   the config files, one ranked_list line each
 *   renderConfigKeys(descriptor, configObject)   one config file's keys, one ranked_list line each
 *
 * Output is the Jenga `ranked_list` object type (templates/playbook-types.json): 1-indexed
 * "<n>. <id> — <text>" lines, one per item, no trailing menu or prompt line, deterministic order (the order of
 * the descriptors passed in, and the descriptor's own `keys` order). Every line is a single line: text is
 * whitespace-collapsed and nested values are summarised as counts, never dumped. The interactive flow
 * (E68_S02) imports these same functions.
 *
 * CLI (scripts/render-config-list.sh is the wrapper):
 *   node lib/config/render.js              list the config files
 *   node lib/config/render.js <file-id>    list that file's keys (file-id is the basename without .json)
 * Exit codes follow the table in project/documentation/config-descriptors.md:
 *   0 ok, 2 usage, 3 unknown file id, 6 configs directory unresolvable or the config file missing/unreadable,
 *   1 invalid or absent descriptors (run scripts/validate-config-descriptors.sh --all).
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { loadDescriptors, loadSchema, validateEntries } from "./descriptors.js";
import { isMainModule, readConfigFile, resolveConfigsDir } from "./paths.js";

const MAX_VALUE_CHARS = 60;

const oneLine = (s) => String(s).replace(/\s+/g, " ").trim();
const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
const fileId = (descriptor) => descriptor.file.replace(/\.json$/, "");

function ranked(items) {
  return items.map((it, i) => `${i + 1}. ${it.id} — ${oneLine(it.text)}`).join("\n");
}

/** Short single-line display of a scalar (strings are quoted so an empty or padded value is visible). */
function displayScalar(value) {
  let text = typeof value === "string" ? JSON.stringify(value) : String(JSON.stringify(value));
  if (text.length > MAX_VALUE_CHARS) text = `${text.slice(0, MAX_VALUE_CHARS - 1)}…`;
  return text;
}

/** Display a current value; nested values are summarised as a count. `undefined` means the key is absent. */
function displayValue(value) {
  if (value === undefined) return "[not set]";
  if (Array.isArray(value)) return plural(value.length, "item");
  if (value !== null && typeof value === "object") return plural(Object.keys(value).length, "key");
  return displayScalar(value);
}

function boundsText(entry) {
  const parts = [];
  const hasMin = typeof entry.min === "number";
  const hasMax = typeof entry.max === "number";
  if (hasMin && hasMax) parts.push(`${entry.min} to ${entry.max}`);
  else if (hasMin) parts.push(`min ${entry.min}`);
  else if (hasMax) parts.push(`max ${entry.max}`);
  if (Array.isArray(entry.allowed)) parts.push(`one of ${entry.allowed.map(displayScalar).join(", ")}`);
  if (typeof entry.pattern === "string") parts.push(`pattern ${entry.pattern}`);
  return parts;
}

/**
 * List the config files as a ranked_list. `descriptors` is an array of parsed (valid) descriptor objects. For each,
 * the text is the descriptor description plus its editable-key count, followed by "[not present]" when the config
 * file does not exist in configsDir or "[unreadable]" when it exists but does not parse as a JSON object. Neither
 * aborts the listing.
 */
export function renderConfigFiles(descriptors, configsDir) {
  return ranked(
    descriptors.map((d) => {
      const editable = d.keys.filter((k) => k.editable === true).length;
      let text = `${oneLine(d.description)} (${plural(editable, "editable key")})`;
      const state = readConfigFile(configsDir, d.file).state;
      if (state === "missing") text += " [not present]";
      else if (state === "unreadable") text += " [unreadable]";
      return { id: fileId(d), text };
    })
  );
}

/**
 * List one config file's keys as a ranked_list, in the descriptor's own order. An editable key reads
 * "label: current value (type, bounds)"; any other key reads "label: summary [read-only; see pointer]". A key the
 * descriptor lists but the object lacks shows "[not set]" rather than failing.
 */
export function renderConfigKeys(descriptor, configObject) {
  if (configObject === null || typeof configObject !== "object" || Array.isArray(configObject)) {
    throw new TypeError("renderConfigKeys: configObject must be a parsed JSON object");
  }
  return ranked(
    descriptor.keys.map((k) => {
      const value = Object.prototype.hasOwnProperty.call(configObject, k.key) ? configObject[k.key] : undefined;
      let text;
      if (k.editable === true) {
        text = `${oneLine(k.label)}: ${displayValue(value)} (${[k.type].concat(boundsText(k)).join(", ")})`;
      } else {
        text = `${oneLine(k.label)}: ${displayValue(value)} [read-only; see ${oneLine(k.pointer)}]`;
      }
      return { id: k.key, text };
    })
  );
}

const USAGE = "usage: render-config-list.sh [<file-id>]";

export function runCli(argv) {
  const out = (s) => process.stdout.write(s + "\n");
  const err = (s) => process.stderr.write(s + "\n");

  if (argv.indexOf("--help") >= 0 || argv.indexOf("-h") >= 0) {
    out(USAGE);
    return 0;
  }
  if (argv.length > 1 || (argv.length === 1 && argv[0].charAt(0) === "-")) {
    err(USAGE);
    return 2;
  }

  let entries;
  let schema;
  try {
    schema = loadSchema();
    entries = loadDescriptors();
  } catch (e) {
    err(e.message);
    return 1;
  }
  if (entries.length === 0) {
    err("no config descriptors found; nothing to list (see the config-descriptors.md guide in the documentation directory)");
    return 1;
  }
  const broken = validateEntries(entries, schema).filter((r) => r.problems.length > 0);
  if (broken.length > 0) {
    broken.forEach((r) => r.problems.forEach((p) => err(`${r.entry.path}: ${p}`)));
    err("invalid descriptors; run scripts/validate-config-descriptors.sh --all");
    return 1;
  }

  const cfgDir = resolveConfigsDir();
  if (!cfgDir.ok) {
    err(`cannot resolve the configs directory: ${cfgDir.message}`);
    return 6;
  }

  const descriptors = entries.map((e) => e.descriptor);
  if (argv.length === 0) {
    out(renderConfigFiles(descriptors, cfgDir.dir));
    return 0;
  }

  const id = argv[0];
  const match = descriptors.find((d) => fileId(d) === id);
  if (!match) {
    err(`unknown config file "${id}"; known: ${descriptors.map(fileId).join(", ")}`);
    return 3;
  }
  const cfg = readConfigFile(cfgDir.dir, match.file);
  if (cfg.state === "missing") {
    err(`config file ${cfg.path} is not present`);
    return 6;
  }
  if (cfg.state === "unreadable") {
    err(`config file ${cfg.path} is unreadable (${cfg.message})`);
    return 6;
  }
  out(renderConfigKeys(match, cfg.value));
  return 0;
}

if (isMainModule(import.meta.url)) {
  process.exitCode = runCli(process.argv.slice(2));
}

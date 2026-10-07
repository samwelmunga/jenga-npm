/**
 * lib/config/descriptors.js - descriptor loader and validator (E68_S01_T02)
 *
 * Exports:
 *   loadSchema(path?)                          the field-spec schema, templates/config-descriptor-schema.json
 *   loadDescriptors(dir?)                      [{ id, path, descriptor, error }], sorted, '_*' files skipped
 *   validateDescriptor(descriptor, schema)     string[] of problems (empty = valid)
 *   checkAgainstConfig(descriptor, config)     string[] of problems against the real, parsed config object
 *   validateEntries(entries, schema, configsDir)   per-entry problems, used by the CLI and by tests
 *
 * Every rule about which fields exist, which are required, which apply to which type and which value shapes are
 * legal is read from the schema (templates/config-descriptor-schema.json); this file carries no second copy of
 * the field list. What code adds is what a declarative schema cannot say: cross-field rules (a default must satisfy
 * its own min/max/allowed/pattern, min <= max, a bump target must be an existing read-only integer, no duplicate
 * keys) and the comparison against the real config file.
 *
 * The same module is the CLI entry for scripts/validate-config-descriptors.sh:
 *   node lib/config/descriptors.js --all | <descriptor-file>...
 * stdout: "PASS <file>" / "FAIL <file>" per descriptor; stderr: one "<file>: <message>" line per problem.
 * Exit codes: 0 all valid, 1 at least one problem (or nothing to validate, or configs dir unresolvable), 2 usage.
 *
 * ESM, Node built-ins only; written for Node >= 14.13.1 (avoid newer built-in APIs).
 */
import { readFileSync, readdirSync } from "fs";
import { basename, resolve } from "path";
import { descriptorsDir, isMainModule, readConfigFile, resolveConfigsDir, schemaPath } from "./paths.js";

const KNOWN_KINDS = [
  "integer",
  "string",
  "boolean",
  "enum",
  "regex",
  "array_of_keys",
  "array_of_scalars",
  "scalar_of_type",
  "key_ref",
];
const REQUIRED_MODES = ["always", "editable", "readonly", "never"];

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function matchesType(value, type) {
  switch (type) {
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "string":
      return typeof value === "string";
    case "boolean":
      return typeof value === "boolean";
    case "array":
      return Array.isArray(value);
    case "object":
      return isPlainObject(value);
    default:
      return false;
  }
}

export function loadSchema(path) {
  return JSON.parse(readFileSync(path || schemaPath(), "utf8"));
}

/** Read and parse one descriptor file into a loader entry. Never throws. */
export function readDescriptorFile(path) {
  const abs = resolve(path);
  const id = basename(abs).replace(/\.json$/, "");
  let text;
  try {
    text = readFileSync(abs, "utf8");
  } catch (e) {
    return { id, path: abs, descriptor: null, error: `cannot read descriptor: ${e.message}` };
  }
  try {
    return { id, path: abs, descriptor: JSON.parse(text), error: null };
  } catch (e) {
    return { id, path: abs, descriptor: null, error: `malformed JSON: ${e.message}` };
  }
}

/**
 * Load every descriptor in dir (default: the package's templates/config-descriptors/, or
 * JENGA_CONFIG_DESCRIPTORS_DIR). Files not ending in .json and files whose name starts with "_" are ignored.
 * Order is the plain code-unit sort of the file names, so output is deterministic. Throws if dir is unreadable.
 */
export function loadDescriptors(dir) {
  const d = dir || descriptorsDir();
  let names;
  try {
    names = readdirSync(d);
  } catch (e) {
    throw new Error(`cannot read descriptor directory ${d}: ${e.message}`);
  }
  return names
    .filter((n) => n.endsWith(".json") && n.charAt(0) !== "_")
    .sort()
    .map((n) => readDescriptorFile(resolve(d, n)));
}

// ---------------------------------------------------------------------------
// Schema sanity
// ---------------------------------------------------------------------------

function checkSchema(schema) {
  const problems = [];
  if (!isPlainObject(schema)) return ["schema is not a JSON object"];
  for (const k of ["types", "scalar_types"]) {
    if (!Array.isArray(schema[k])) problems.push(`schema: "${k}" must be an array`);
  }
  for (const section of ["top_level", "key_fields"]) {
    if (!isPlainObject(schema[section])) {
      problems.push(`schema: "${section}" must be an object`);
      continue;
    }
    for (const name of Object.keys(schema[section])) {
      const spec = schema[section][name];
      if (!isPlainObject(spec) || KNOWN_KINDS.indexOf(spec.kind) < 0) {
        problems.push(`schema: ${section}.${name} has unsupported kind ${JSON.stringify(spec && spec.kind)}`);
      }
      if (isPlainObject(spec) && REQUIRED_MODES.indexOf(spec.required) < 0) {
        problems.push(`schema: ${section}.${name} has unsupported required mode ${JSON.stringify(spec.required)}`);
      }
    }
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Value checks, driven by a field spec
// ---------------------------------------------------------------------------

function describeKind(spec, schema) {
  switch (spec.kind) {
    case "integer":
      return "an integer";
    case "string":
      return "a string";
    case "boolean":
      return "a boolean";
    case "enum":
      return `one of ${(schema[spec.enum_from] || []).join(", ")}`;
    default:
      return spec.kind;
  }
}

/** Returns an array of problem strings for one field value; `entryType` is the key entry's (valid) type or null. */
function checkValue(spec, name, value, ctx, schema, entryType) {
  const bad = (msg) => [`${ctx}: field "${name}" ${msg}`];
  switch (spec.kind) {
    case "integer":
      if (typeof value !== "number" || !Number.isInteger(value)) return bad("must be an integer");
      if (has(spec, "const") && value !== spec.const) return bad(`must be ${JSON.stringify(spec.const)}`);
      return [];
    case "boolean":
      return typeof value === "boolean" ? [] : bad("must be a boolean");
    case "string": {
      if (typeof value !== "string") return bad("must be a string");
      const out = [];
      if (spec.non_empty && value.trim() === "") out.push(...bad("must not be empty"));
      if (spec.single_line && /[\r\n]/.test(value)) out.push(...bad("must be a single line (no newline)"));
      if (spec.pattern && !new RegExp(spec.pattern).test(value)) {
        out.push(...bad(`must match ${spec.pattern} (got ${JSON.stringify(value)})`));
      }
      return out;
    }
    case "enum": {
      const allowed = schema[spec.enum_from] || [];
      return allowed.indexOf(value) >= 0 ? [] : bad(`must be ${describeKind(spec, schema)} (got ${JSON.stringify(value)})`);
    }
    case "regex":
      if (typeof value !== "string") return bad("must be a string holding a regular expression");
      try {
        new RegExp(value);
      } catch (e) {
        return bad(`is not a valid regular expression: ${e.message}`);
      }
      return [];
    case "scalar_of_type":
      if (!entryType) return [];
      return matchesType(value, entryType) ? [] : bad(`must be of the key's type (${entryType})`);
    case "array_of_scalars": {
      if (!Array.isArray(value) || value.length === 0) return bad("must be a non-empty array");
      const out = [];
      const seen = [];
      for (let i = 0; i < value.length; i++) {
        if (entryType && !matchesType(value[i], entryType)) {
          out.push(...bad(`entry ${i} must be of the key's type (${entryType})`));
        } else if (seen.indexOf(value[i]) >= 0) {
          out.push(...bad(`has a duplicate entry ${JSON.stringify(value[i])}`));
        }
        seen.push(value[i]);
      }
      return out;
    }
    case "key_ref":
      return typeof value === "string" && value.trim() !== "" ? [] : bad("must be a non-empty string naming a key");
    case "array_of_keys":
      return Array.isArray(value) && value.length > 0 ? [] : bad("must be a non-empty array");
    default:
      return bad(`has unsupported kind ${spec.kind}`);
  }
}

function isRequired(spec, entry, scalarEditableOk) {
  switch (spec.required) {
    case "always":
      return true;
    case "editable":
      return entry.editable === true && scalarEditableOk;
    case "readonly":
      return entry.editable === false;
    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// validateDescriptor
// ---------------------------------------------------------------------------

function validateKeyEntry(entry, index, schema) {
  const problems = [];
  const name = isPlainObject(entry) && typeof entry.key === "string" && entry.key !== "" ? entry.key : null;
  const ctx = name ? `key "${name}"` : `keys[${index}]`;
  if (!isPlainObject(entry)) return [`${ctx}: must be a JSON object`];

  const specs = schema.key_fields;
  for (const f of Object.keys(entry)) {
    if (!has(specs, f)) problems.push(`${ctx}: unknown field "${f}"`);
  }

  const typeValid = typeof entry.type === "string" && schema.types.indexOf(entry.type) >= 0;
  const entryType = typeValid ? entry.type : null;
  const editableValid = typeof entry.editable === "boolean";
  const scalar = typeValid && schema.scalar_types.indexOf(entry.type) >= 0;

  if (typeValid && editableValid && entry.editable === true && !scalar) {
    problems.push(
      `${ctx}: editable: true is only legal for scalar types (${schema.scalar_types.join(", ")}); this key has type ${entry.type}`
    );
  }

  for (const f of Object.keys(specs)) {
    const spec = specs[f];
    const present = has(entry, f);
    // A missing 'type' or 'editable' makes the conditional fields undecidable; their own message is enough.
    const decidable = editableValid && (spec.applies_to ? typeValid : true);
    if (!present) {
      if (spec.required === "always" || (decidable && isRequired(spec, entry, scalar || !typeValid))) {
        problems.push(`${ctx}: missing required field "${f}"`);
      }
      continue;
    }
    if (editableValid && spec.only_when === "editable" && entry.editable !== true) {
      problems.push(`${ctx}: field "${f}" is only legal on editable keys`);
      continue;
    }
    if (editableValid && spec.only_when === "readonly" && entry.editable !== false) {
      problems.push(`${ctx}: field "${f}" is only legal on read-only keys`);
      continue;
    }
    if (typeValid && spec.applies_to && spec.applies_to.indexOf(entry.type) < 0) {
      problems.push(`${ctx}: field "${f}" does not apply to type ${entry.type}`);
      continue;
    }
    problems.push(...checkValue(spec, f, entry[f], ctx, schema, entryType));
  }

  problems.push(...checkEditableSemantics(entry, ctx, problems));
  return problems;
}

/** Cross-field rules for an editable scalar key. Skips rules whose inputs were already reported as invalid. */
function checkEditableSemantics(entry, ctx, existing) {
  if (entry.editable !== true) return [];
  const out = [];
  const intOk = (f) => has(entry, f) && typeof entry[f] === "number" && Number.isInteger(entry[f]);
  const flagged = (f) => existing.some((p) => p.indexOf(`field "${f}"`) >= 0);

  if (entry.type === "integer") {
    if (intOk("min") && intOk("max") && entry.min > entry.max) {
      out.push(`${ctx}: min (${entry.min}) is greater than max (${entry.max})`);
    }
    const inBounds = (v) => (!intOk("min") || v >= entry.min) && (!intOk("max") || v <= entry.max);
    if (has(entry, "default") && !flagged("default") && !inBounds(entry.default)) {
      out.push(`${ctx}: default ${entry.default} is outside the declared min/max`);
    }
    if (Array.isArray(entry.allowed) && !flagged("allowed")) {
      for (const v of entry.allowed) {
        if (typeof v === "number" && !inBounds(v)) out.push(`${ctx}: allowed value ${v} is outside the declared min/max`);
      }
    }
  }
  if (entry.type === "string" && typeof entry.pattern === "string" && !flagged("pattern")) {
    const re = new RegExp(entry.pattern);
    if (typeof entry.default === "string" && !flagged("default") && !re.test(entry.default)) {
      out.push(`${ctx}: default ${JSON.stringify(entry.default)} does not match the declared pattern`);
    }
    if (Array.isArray(entry.allowed) && !flagged("allowed")) {
      for (const v of entry.allowed) {
        if (typeof v === "string" && !re.test(v)) out.push(`${ctx}: allowed value ${JSON.stringify(v)} does not match the declared pattern`);
      }
    }
  }
  if (Array.isArray(entry.allowed) && has(entry, "default") && !flagged("default") && !flagged("allowed")) {
    if (entry.allowed.indexOf(entry.default) < 0) {
      out.push(`${ctx}: default ${JSON.stringify(entry.default)} is not in the allowed set`);
    }
  }
  return out;
}

/** Validate one parsed descriptor against the schema. Returns an array of problems; empty means valid. */
export function validateDescriptor(descriptor, schema) {
  const sch = checkSchema(schema);
  if (sch.length) return sch;
  if (!isPlainObject(descriptor)) return ["descriptor is not a JSON object"];

  const problems = [];
  for (const f of Object.keys(descriptor)) {
    if (!has(schema.top_level, f)) problems.push(`unknown top-level field "${f}"`);
  }
  for (const f of Object.keys(schema.top_level)) {
    const spec = schema.top_level[f];
    if (!has(descriptor, f)) {
      if (spec.required === "always") problems.push(`missing required field "${f}"`);
      continue;
    }
    problems.push(...checkValue(spec, f, descriptor[f], "descriptor", schema, null));
  }

  if (!Array.isArray(descriptor.keys)) return problems;

  const seen = {};
  const byKey = {};
  descriptor.keys.forEach((entry, i) => {
    problems.push(...validateKeyEntry(entry, i, schema));
    if (isPlainObject(entry) && typeof entry.key === "string" && entry.key !== "") {
      if (has(seen, entry.key)) {
        problems.push(`key "${entry.key}": duplicate key entry`);
      } else {
        byKey[entry.key] = entry;
      }
      seen[entry.key] = true;
    }
  });

  // bump_on_change targets
  descriptor.keys.forEach((entry) => {
    if (!isPlainObject(entry) || typeof entry.bump_on_change !== "string" || entry.editable !== true) return;
    const ctx = `key "${entry.key}"`;
    const target = entry.bump_on_change;
    if (target === entry.key) {
      problems.push(`${ctx}: bump_on_change names the key itself`);
    } else if (!has(byKey, target)) {
      problems.push(`${ctx}: bump_on_change names "${target}", which is not a key in this descriptor`);
    } else {
      const t = byKey[target];
      const want = schema.bump_target || {};
      if (want.type && t.type !== want.type) {
        problems.push(`${ctx}: bump_on_change target "${target}" must have type ${want.type} (it has ${t.type})`);
      }
      if (has(want, "editable") && t.editable !== want.editable) {
        problems.push(`${ctx}: bump_on_change target "${target}" must be a read-only version counter (editable: ${want.editable})`);
      }
    }
  });

  return problems;
}

// ---------------------------------------------------------------------------
// checkAgainstConfig
// ---------------------------------------------------------------------------

/**
 * Compare a (schema-valid) descriptor with the real parsed config object. Reports, as problems:
 *   - a descriptor key absent from the config file,
 *   - a top-level config key no descriptor entry covers,
 *   - a key whose current value does not match its declared type.
 */
export function checkAgainstConfig(descriptor, config) {
  const file = descriptor && typeof descriptor.file === "string" ? descriptor.file : "config file";
  if (!isPlainObject(config)) return [`${file}: config is not a JSON object`];
  if (!descriptor || !Array.isArray(descriptor.keys)) return [];

  const problems = [];
  const covered = {};
  descriptor.keys.forEach((entry) => {
    if (!isPlainObject(entry) || typeof entry.key !== "string") return;
    covered[entry.key] = true;
    if (!has(config, entry.key)) {
      problems.push(`key "${entry.key}": named by the descriptor but absent from ${file}`);
    } else if (!matchesType(config[entry.key], entry.type)) {
      problems.push(
        `key "${entry.key}": declared type ${entry.type} but the value in ${file} is ${describeValueType(config[entry.key])}`
      );
    }
  });
  Object.keys(config).forEach((k) => {
    if (!has(covered, k)) problems.push(`config key "${k}" in ${file} has no descriptor entry`);
  });
  return problems;
}

function describeValueType(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (typeof v === "number") return Number.isInteger(v) ? "integer" : "number";
  return typeof v;
}

// ---------------------------------------------------------------------------
// Whole-entry validation + CLI
// ---------------------------------------------------------------------------

/**
 * Validate loader entries. Returns [{ entry, problems, notes }]. When configsDir is given, a descriptor that passed
 * schema validation is also checked against its real config file; a missing config file is a note (cross-check
 * skipped), a config file that cannot be parsed is a problem.
 */
export function validateEntries(entries, schema, configsDir) {
  return entries.map((entry) => {
    const notes = [];
    let problems = [];
    if (entry.error) {
      problems = [entry.error];
    } else {
      problems = validateDescriptor(entry.descriptor, schema);
      const d = entry.descriptor;
      if (isPlainObject(d) && typeof d.file === "string" && d.file !== `${entry.id}.json`) {
        problems.push(`"file" is ${JSON.stringify(d.file)} but the descriptor is named ${entry.id}.json`);
      }
      if (problems.length === 0 && configsDir) {
        const cfg = readConfigFile(configsDir, d.file);
        if (cfg.state === "ok") {
          problems = checkAgainstConfig(d, cfg.value);
        } else if (cfg.state === "missing") {
          notes.push(`config file ${cfg.path} not present; cross-check skipped`);
        } else {
          problems = [`config file ${cfg.path} is unreadable (${cfg.message})`];
        }
      }
    }
    return { entry, problems, notes };
  });
}

const USAGE = "usage: validate-config-descriptors.sh --all | <descriptor-file>...";

export function runCli(argv) {
  const out = (s) => process.stdout.write(s + "\n");
  const err = (s) => process.stderr.write(s + "\n");
  const args = argv.slice();

  if (args.length === 0 || args.indexOf("--help") >= 0 || args.indexOf("-h") >= 0) {
    (args.length === 0 ? err : out)(USAGE);
    return args.length === 0 ? 2 : 0;
  }
  const all = args.indexOf("--all") >= 0;
  const files = args.filter((a) => a !== "--all");
  if (files.some((a) => a.charAt(0) === "-")) {
    err(`unknown option ${files.find((a) => a.charAt(0) === "-")}\n${USAGE}`);
    return 2;
  }
  if (all && files.length > 0) {
    err(`--all cannot be combined with file arguments\n${USAGE}`);
    return 2;
  }

  let schema;
  try {
    schema = loadSchema();
  } catch (e) {
    err(`cannot load the descriptor schema ${schemaPath()}: ${e.message}`);
    return 1;
  }

  let entries;
  if (all) {
    try {
      entries = loadDescriptors();
    } catch (e) {
      err(e.message);
      return 1;
    }
    if (entries.length === 0) {
      err(`no descriptors found in ${descriptorsDir()}; nothing was validated`);
      return 1;
    }
  } else {
    entries = files.map((f) => readDescriptorFile(f));
  }

  const cfgDir = resolveConfigsDir();
  if (!cfgDir.ok) {
    err(`cannot resolve the configs directory: ${cfgDir.message}`);
    return 1;
  }

  let failed = false;
  for (const r of validateEntries(entries, schema, cfgDir.dir)) {
    r.notes.forEach((n) => err(`${r.entry.path}: NOTE ${n}`));
    if (r.problems.length === 0) {
      out(`PASS ${r.entry.path}`);
    } else {
      failed = true;
      out(`FAIL ${r.entry.path}`);
      r.problems.forEach((p) => err(`${r.entry.path}: ${p}`));
    }
  }
  return failed ? 1 : 0;
}

if (isMainModule(import.meta.url)) {
  process.exitCode = runCli(process.argv.slice(2));
}

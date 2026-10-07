/**
 * lib/config/paths.js - where the config command finds things (E68_S01_T02)
 *
 * Two different homes, deliberately kept apart:
 *
 *   - PACKAGE assets (descriptors, the descriptor schema, scripts/resolve-root.sh) are located from this file's
 *     own import.meta.url, never from process.cwd(). `templates/`, `lib/` and `scripts/` are not mirrored into a
 *     consumer project; they are read in place from node_modules/@jenga-ai/agent/ at run time.
 *   - PROJECT config files (project/configs/*.json) are located by calling `scripts/resolve-root.sh get configs`,
 *     so JENGA_PROJECT_ROOT, the upward search and `.project/` trees are all honoured. No `project/` literal
 *     lives anywhere under lib/config/.
 *
 * ESM, Node built-ins only (engines floor is Node 14.13.1).
 */
import { readFileSync, realpathSync } from "fs";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const HERE = dirname(fileURLToPath(import.meta.url));

/** Absolute path of the package root (the directory holding lib/, scripts/ and templates/). */
export function packageRoot() {
  return resolve(HERE, "..", "..");
}

/** Directory of descriptors. JENGA_CONFIG_DESCRIPTORS_DIR overrides it (tests). */
export function descriptorsDir() {
  const override = process.env.JENGA_CONFIG_DESCRIPTORS_DIR;
  return override ? resolve(override) : join(packageRoot(), "templates", "config-descriptors");
}

/** Absolute path of the machine-readable descriptor schema. */
export function schemaPath() {
  return join(packageRoot(), "templates", "config-descriptor-schema.json");
}

/**
 * Resolve the project's configs directory through scripts/resolve-root.sh.
 * Returns { ok: true, dir } or { ok: false, message, status }.
 */
export function resolveConfigsDir(cwd) {
  const script = join(packageRoot(), "scripts", "resolve-root.sh");
  const r = spawnSync("bash", [script, "get", "configs"], {
    cwd: cwd || process.cwd(),
    encoding: "utf8",
    env: process.env,
  });
  if (r.error) {
    return { ok: false, status: 1, message: `could not run ${script}: ${r.error.message}` };
  }
  const out = (r.stdout || "").trim();
  if (r.status !== 0 || !out) {
    const message = (r.stderr || "").trim() || `${script} get configs exited ${r.status}`;
    return { ok: false, status: r.status === null ? 1 : r.status, message };
  }
  return { ok: true, dir: out };
}

/**
 * Read one config file from the configs directory.
 * Returns { state: "ok", value, path } | { state: "missing", path } | { state: "unreadable", path, message }.
 * "unreadable" covers invalid JSON and a top level that is not an object.
 */
export function readConfigFile(configsDir, file) {
  const path = join(configsDir, file);
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { state: "missing", path };
    return { state: "unreadable", path, message: e.message };
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch (e) {
    return { state: "unreadable", path, message: `invalid JSON: ${e.message}` };
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { state: "unreadable", path, message: "top level is not a JSON object" };
  }
  return { state: "ok", value, path };
}

/** True when the module whose import.meta.url is given is the script node was started with (CLI entry guard). */
export function isMainModule(metaUrl) {
  try {
    return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(metaUrl));
  } catch (e) {
    return false;
  }
}

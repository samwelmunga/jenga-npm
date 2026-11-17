/**
 * lib/progress/config.js - the settings the Node progress renderers read from project config (E92_S08_T03)
 *
 * Two keys of the EXISTING <configs dir>/dashboard-config.json (no new config file; the file is not renamed):
 *
 *   progress_charset   utf8 | ascii
 *   progress_color     auto | always | never
 *
 * Both are optional. A project that predates them simply lacks them, so there is no migration: a missing file, a
 * missing key, or a configs directory that cannot be resolved all mean "use the default", silently. An invalid
 * value also falls back to the default, with ONE warning (returned, never printed here).
 *
 * The configs directory is resolved exactly as lib/config/paths.js and scripts/board-progress.sh do: through
 * `scripts/resolve-root.sh get configs`, so JENGA_PROJECT_ROOT (set from --root by cli.js), the upward search and
 * `.project/` trees are honoured and no `project/` path is spelled out here.
 *
 * resolveChoice() is the one precedence rule shared by charset.js and color.js: flag, then environment variable,
 * then config key, then default. Why that order is in the execution summary of E92_S08_T03: each layer is further
 * from the keyboard than the one before and nearer to a standing preference, so the nearest, most deliberate
 * statement wins.
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { spawnSync } from "child_process";
import { join } from "path";
import { readConfigFile } from "../config/paths.js";
import { findScriptsDir } from "./data.js";

/** The config file that holds the progress settings (existing file, see the header). */
export const CONFIG_FILE = "dashboard-config.json";

const show = (v) => (typeof v === "string" ? JSON.stringify(v) : String(JSON.stringify(v)));

/**
 * Pick a setting by precedence flag, environment variable, config key, default.
 *
 * `flag`, `envValue` and `configValue` are the raw values of each layer (undefined, null or "" in the flag and
 * environment layers mean "not given"; the config layer treats only undefined as "not given", so a present but
 * invalid value is reported). A layer that is present but not in `allowed` is skipped, with one warning, and the
 * next layer is tried. Layers after the winning one are never examined, so they cannot warn.
 *
 * Returns { value, source: "flag" | "env" | "config" | "default", warnings: string[] }.
 */
export function resolveChoice(opts) {
  const warnings = [];
  const layers = [
    { source: "flag", raw: opts.flag, given: opts.flag !== undefined && opts.flag !== null && opts.flag !== "", where: "the flag" },
    { source: "env", raw: opts.envValue, given: opts.envValue !== undefined && opts.envValue !== "", where: opts.envName },
    { source: "config", raw: opts.configValue, given: opts.configValue !== undefined, where: `${opts.configKey} in ${CONFIG_FILE}` },
  ];
  for (let i = 0; i < layers.length; i++) {
    const layer = layers[i];
    if (!layer.given) continue;
    if (typeof layer.raw === "string" && opts.allowed.indexOf(layer.raw) >= 0) {
      return { value: layer.raw, source: layer.source, warnings };
    }
    warnings.push(`${layer.where}: ${show(layer.raw)} is not one of ${opts.allowed.join(", ")}; ignored`);
  }
  return { value: opts.fallback, source: "default", warnings };
}

/**
 * Read the two progress keys from the project's dashboard-config.json.
 *
 * Returns { values: { progress_charset?, progress_color? }, warnings: string[] } with the RAW values found (the
 * caller validates them through resolveChoice). Never throws. Only an unreadable file (invalid JSON, not an
 * object) warns; absence of the project, the file or a key is silent.
 *
 *   opts.env        environment handed to resolve-root.sh (default process.env)
 *   opts.cwd        directory the resolution starts from (default process.cwd())
 *   opts.scriptsDir directory holding resolve-root.sh (default: found by findScriptsDir)
 */
export function readProgressConfig(opts) {
  const o = opts || {};
  const env = o.env || process.env;
  const cwd = o.cwd || process.cwd();
  const values = {};
  const scriptsDir = o.scriptsDir || findScriptsDir({ env, cwd, needs: "resolve-root.sh" });
  if (!scriptsDir) return { values, warnings: [] };

  const r = spawnSync("bash", [join(scriptsDir, "resolve-root.sh"), "get", "configs"], { cwd, env, encoding: "utf8" });
  const dir = (r.stdout || "").trim();
  if (r.error || r.status !== 0 || !dir) return { values, warnings: [] };

  const cfg = readConfigFile(dir, CONFIG_FILE);
  if (cfg.state === "missing") return { values, warnings: [] };
  if (cfg.state === "unreadable") return { values, warnings: [`${cfg.path} is unreadable (${cfg.message}); progress settings use their defaults`] };
  ["progress_charset", "progress_color"].forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(cfg.value, key)) values[key] = cfg.value[key];
  });
  return { values, warnings: [] };
}

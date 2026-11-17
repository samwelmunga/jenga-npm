/**
 * lib/progress/data.js - the data loader of the Node progress renderers (E92_S08_T03)
 *
 * Runs scripts/board-progress.sh and parses its JSON. This file COUNTS NOTHING: every number a renderer shows
 * comes from that one script (E92 decision 1, one counting script), so the terminal and the dashboard cannot
 * disagree about what "8 of 10" means.
 *
 *   readBoardProgress(args, opts)   args are the script's own: --graph, --story <id>, --epic <id>, --ids <list>,
 *                                   --within <id>, --counts-only, ... exactly what the bash renderers pass
 *
 * Failure is a VALUE, never a throw: a missing script, a non-zero exit (2 unknown id, 3 empty scope, 1 internal)
 * or output that is not JSON returns { ok: false, warning }, so cli.js can print one warning line and exit 0
 * (the never-fail rule of the story).
 *
 * Where the scripts live (the dual-path idiom): the directory named by JENGA_PROGRESS_SCRIPTS_DIR when set (a test
 * seam; it is then the only candidate, so a test can point it at an empty directory to simulate a missing script),
 * otherwise `scripts/` next to this package's `lib/` (the repository, and equally node_modules/@jenga-ai/agent/
 * when installed), otherwise `<cwd>/scripts` and `<cwd>/node_modules/@jenga-ai/agent/scripts`.
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { dirname, join, resolve } from "path";
import { fileURLToPath } from "url";

export const ENV_SCRIPTS_DIR = "JENGA_PROGRESS_SCRIPTS_DIR";
export const BOARD_PROGRESS_SCRIPT = "board-progress.sh";

const HERE = dirname(fileURLToPath(import.meta.url));
const TIMEOUT_MS = 120000;
const MAX_BUFFER = 256 * 1024 * 1024;

/**
 * Find the scripts directory that holds `opts.needs` (default board-progress.sh). Returns an absolute directory or
 * null. opts: { env, cwd, needs }.
 */
export function findScriptsDir(opts) {
  const o = opts || {};
  const env = o.env || process.env;
  const cwd = o.cwd || process.cwd();
  const needs = o.needs || BOARD_PROGRESS_SCRIPT;
  const override = env[ENV_SCRIPTS_DIR];
  const candidates = override
    ? [resolve(cwd, override)]
    : [resolve(HERE, "..", "..", "scripts"), join(cwd, "scripts"), join(cwd, "node_modules", "@jenga-ai", "agent", "scripts")];
  for (let i = 0; i < candidates.length; i++) {
    if (existsSync(join(candidates[i], needs))) return candidates[i];
  }
  return null;
}

const firstLine = (text) => String(text || "").split(/\r?\n/).filter((l) => l.trim() !== "")[0] || "";

/**
 * Run `bash <scriptsDir>/<script> ...args`. Returns { ok: true, stdout } or { ok: false, message } (never throws).
 * opts: { scriptsDir, env, cwd }.
 */
export function runScript(script, args, opts) {
  const o = opts || {};
  const dir = o.scriptsDir || findScriptsDir({ env: o.env, cwd: o.cwd, needs: script });
  if (!dir || !existsSync(join(dir, script))) {
    return { ok: false, message: `${script} was not found; progress is unavailable` };
  }
  try {
    const stdout = execFileSync("bash", [join(dir, script)].concat(args || []), {
      encoding: "utf8",
      env: o.env || process.env,
      cwd: o.cwd || process.cwd(),
      stdio: ["ignore", "pipe", "pipe"],
      timeout: TIMEOUT_MS,
      maxBuffer: MAX_BUFFER,
    });
    return { ok: true, stdout };
  } catch (e) {
    if (e && typeof e.status === "number") {
      const why = firstLine(e.stderr) || "no message";
      return { ok: false, message: `${script} exited ${e.status}: ${why}` };
    }
    return { ok: false, message: `could not run ${script}: ${e && e.message ? firstLine(e.message) : "unknown error"}` };
  }
}

/**
 * Run board-progress.sh with `args` and parse its JSON.
 * Returns { ok: true, data } or { ok: false, warning }.
 */
export function readBoardProgress(args, opts) {
  const r = runScript(BOARD_PROGRESS_SCRIPT, args, opts);
  if (!r.ok) return { ok: false, warning: r.message };
  try {
    return { ok: true, data: JSON.parse(r.stdout) };
  } catch (e) {
    return { ok: false, warning: `${BOARD_PROGRESS_SCRIPT} printed output that is not JSON` };
  }
}

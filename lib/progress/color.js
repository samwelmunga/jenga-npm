/**
 * lib/progress/color.js - explicit colour for the Node progress renderers (E92_S08_T03)
 *
 * Colour is an EXPLICIT choice. The order is:
 *
 *   --color auto|always|never, then JENGA_PROGRESS_COLOR, then the config key progress_color
 *   (<configs dir>/dashboard-config.json), then the default auto.
 *
 *   auto    on only when stdout is a TTY and NO_COLOR is unset or empty
 *   always  on, even when NO_COLOR is set and stdout is a pipe
 *   never   off, even on a TTY
 *
 * ANSI is written by hand (no dependency). The palette is keyed by the colour BUCKET names that
 * scripts/board-progress.sh already prints (done, in_progress, failed, pending, rejected), so this file never maps a
 * board status to a bucket itself. The E92 decision 2 set: green for Passed and Passed with remarks (done), yellow
 * for In Progress, red for Failed and Blocked (failed), grey for Pending, a muted blue-grey for Rejected. `ready`
 * (cyan, the "ready to take" nodes of the design) and `locked` (grey) are the two additions of the node design.
 *
 * ESM; Node >= 14.13.1.
 */
import { resolveChoice } from "./config.js";

export const COLOR_MODES = ["auto", "always", "never"];
export const DEFAULT_COLOR = "auto";
export const ENV_COLOR = "JENGA_PROGRESS_COLOR";
export const CONFIG_KEY_COLOR = "progress_color";

const ESC = "\u001b";
const RESET = `${ESC}[0m`;

/** SGR parameter string per colour name. */
export const SGR = Object.freeze({
  done: "32",
  in_progress: "33",
  failed: "31",
  pending: "90",
  rejected: "38;5;67",
  ready: "36",
  locked: "90",
});

const BOLD = "1";
const DIM = "2";

// Matches CSI sequences (ESC [ ... final byte), which is every sequence this module writes.
const ANSI_RE = /\u001b\[[0-9;?]*[ -/]*[@-~]/g;

/** True when `value` names a colour mode. */
export function isColorMode(value) {
  return typeof value === "string" && COLOR_MODES.indexOf(value) >= 0;
}

/** Remove every ANSI escape sequence, so widths are computed on visible characters only. */
export function stripAnsi(text) {
  return String(text).replace(ANSI_RE, "");
}

/**
 * Resolve the colour mode and whether colour is on.
 *
 * `inputs` = { flag, env, config, isTTY }: `env` is an environment object (process.env) of which only
 * JENGA_PROGRESS_COLOR and NO_COLOR are read; `config` is the raw progress_color value (or undefined); `isTTY` is
 * whether stdout is a terminal. Returns { value, source, enabled, warnings } where `value` is the mode.
 */
export function resolveColor(inputs) {
  const i = inputs || {};
  const env = i.env || {};
  const r = resolveChoice({
    flag: i.flag,
    envValue: env[ENV_COLOR],
    envName: ENV_COLOR,
    configValue: i.config,
    configKey: CONFIG_KEY_COLOR,
    allowed: COLOR_MODES,
    fallback: DEFAULT_COLOR,
  });
  let enabled = false;
  if (r.value === "always") enabled = true;
  else if (r.value === "auto") enabled = i.isTTY === true && (env.NO_COLOR === undefined || env.NO_COLOR === "");
  return { value: r.value, source: r.source, enabled, warnings: r.warnings };
}

/**
 * A painter for one run. With `enabled` false every function returns its text unchanged, so callers never branch.
 * paint(name, text) uses the SGR table (an unknown name leaves the text as is); bold and dim wrap in SGR 1 and 2.
 * Each run is closed with ESC[0m, and empty text is never wrapped.
 */
export function createPainter(enabled) {
  const wrap = (code, text) => (enabled && text !== "" ? `${ESC}[${code}m${text}${RESET}` : text);
  return {
    enabled: !!enabled,
    paint(name, text) {
      const code = Object.prototype.hasOwnProperty.call(SGR, name) ? SGR[name] : null;
      return code === null ? text : wrap(code, text);
    },
    bold: (text) => wrap(BOLD, text),
    dim: (text) => wrap(DIM, text),
  };
}

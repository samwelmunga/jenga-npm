/**
 * lib/progress/labels.js - the label table for the Node progress renderers (E92_S08_T03)
 *
 * Every user-visible WORD of a progress rendering lives in scripts/lib/progress-labels.sh, the single source, and
 * reaches Node through scripts/progress-labels-json.sh. No word is written in Node: this file only runs that script
 * and hands the table over. English is the default; JENGA_PROGRESS_LANG=sv (or cli.js --lang sv, which sets it for
 * the child) selects Swedish.
 *
 *   loadLabels(opts)         { ok: true, lang, labels } or { ok: false, warning }; never throws
 *   formatLabel(fmt, ...)    fill the %d and %s placeholders of the format-string labels (rejected_note,
 *                            unlocked_by, card_bar_aria); %% is a literal percent sign
 *
 * ESM; Node >= 14.13.1.
 */
import { runScript } from "./data.js";

export const LABELS_SCRIPT = "progress-labels-json.sh";

/** Run the labels script. opts: { lang, env, cwd, scriptsDir }; `lang` overrides JENGA_PROGRESS_LANG for the child. */
export function loadLabels(opts) {
  const o = opts || {};
  const env = Object.assign({}, o.env || process.env);
  if (o.lang) env.JENGA_PROGRESS_LANG = o.lang;
  const r = runScript(LABELS_SCRIPT, [], { scriptsDir: o.scriptsDir, env, cwd: o.cwd });
  if (!r.ok) return { ok: false, warning: r.message };
  let doc;
  try {
    doc = JSON.parse(r.stdout);
  } catch (e) {
    return { ok: false, warning: `${LABELS_SCRIPT} printed output that is not JSON` };
  }
  if (!doc || typeof doc !== "object" || typeof doc.lang !== "string" || !doc.labels || typeof doc.labels !== "object") {
    return { ok: false, warning: `${LABELS_SCRIPT} printed JSON without lang and labels` };
  }
  return { ok: true, lang: doc.lang, labels: doc.labels };
}

/** Fill %d and %s placeholders in order from `values`; %% is a literal %. A missing value leaves "" for %s, 0 for %d. */
export function formatLabel(format, ...values) {
  let n = 0;
  return String(format).replace(/%([ds%])/g, (all, kind) => {
    if (kind === "%") return "%";
    const v = values[n++];
    if (kind === "d") return String(v === undefined ? 0 : Math.trunc(Number(v)) || 0);
    return v === undefined ? "" : String(v);
  });
}

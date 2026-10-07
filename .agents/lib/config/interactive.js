/**
 * lib/config/interactive.js - the interactive `jenga config` flow (E68_S02_T03)
 *
 * Navigation and prompts only. Every list comes from lib/config/render.js and every write goes through
 * lib/config/store.js's setValue(), so `jenga config set` and this flow share validation, bump behaviour and the
 * atomic write. No model call, no network.
 *
 * Three levels:
 *   1. the config files, as a ranked_list (renderConfigFiles); pick a number or an exact file id
 *   2. that file's keys, as a ranked_list (renderConfigKeys); pick a number or an exact key name
 *   3. one key. An editable key shows label, description, type, bounds or allowed values, default and current
 *      value, then prompts for a new value; setValue() validates and writes, the result line (including any
 *      version bump) is printed, and the flow returns to level 2. A read-only key shows label, current value and
 *      pointer and never prompts. A rejected value prints the validation message and re-prompts; the file is
 *      untouched.
 *
 * `q` at any prompt goes back exactly one level; `q` at level 1 exits 0. End of input (Ctrl-D, or piped stdin
 * ending) exits 0 cleanly at any prompt. Numbers are the 1-indexed positions shown; names are an exact match on
 * the id shown. At the value prompt `q` always means "back", so a string value of exactly `q` (or an empty
 * string) can only be set through `jenga config set`; an empty line just re-prompts.
 *
 * runInteractive({ input, output, errorOutput? }) takes injectable streams so tests drive it with piped stdin. It
 * resolves to the exit code (0, or the loadContext failure code with its message on errorOutput).
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */
import { createInterface } from "readline";
import { renderConfigFiles, renderConfigKeys } from "./render.js";
import { displayValue, formatSetResult, loadContext, readConfig, setValue } from "./store.js";
import { EXIT } from "./exit-codes.js";

const MAX_DETAIL_CHARS = 200;

const fileIdOf = (descriptor) => descriptor.file.replace(/\.json$/, "");

/** Resolve typed input against a 1-indexed list of ids: a number, or an exact id. Returns the id or null. */
function pick(input, ids) {
  if (/^[0-9]+$/.test(input)) {
    const n = Number(input);
    return n >= 1 && n <= ids.length ? ids[n - 1] : null;
  }
  return ids.indexOf(input) >= 0 ? input : null;
}

function constraintLines(entry) {
  const lines = [];
  const hasMin = typeof entry.min === "number";
  const hasMax = typeof entry.max === "number";
  if (hasMin && hasMax) lines.push(`Range: ${entry.min} to ${entry.max}`);
  else if (hasMin) lines.push(`Minimum: ${entry.min}`);
  else if (hasMax) lines.push(`Maximum: ${entry.max}`);
  if (Array.isArray(entry.allowed)) lines.push(`Allowed: ${entry.allowed.map(displayValue).join(", ")}`);
  if (typeof entry.pattern === "string") lines.push(`Pattern: ${entry.pattern}`);
  return lines;
}

/** Line-at-a-time reader that never loses lines that arrive before a prompt, and yields null at end of input. */
function makeReader(input, output) {
  const rl = createInterface({ input, output, terminal: !!(output && output.isTTY && input && input.isTTY) });
  const queue = [];
  let waiting = null;
  let closed = false;
  rl.on("line", (line) => {
    if (waiting) {
      const w = waiting;
      waiting = null;
      w(line);
    } else {
      queue.push(line);
    }
  });
  rl.on("close", () => {
    closed = true;
    if (waiting) {
      const w = waiting;
      waiting = null;
      w(null);
    }
  });
  return {
    ask(prompt) {
      rl.setPrompt(prompt);
      rl.prompt();
      if (queue.length > 0) return Promise.resolve(queue.shift());
      if (closed) return Promise.resolve(null);
      return new Promise((resolve) => {
        waiting = resolve;
      });
    },
    close() {
      rl.close();
    },
  };
}

export async function runInteractive(opts) {
  const input = opts.input;
  const output = opts.output;
  const errorOutput = opts.errorOutput || process.stderr;
  const say = (text) => output.write(`${text}\n`);

  const ctx = loadContext();
  if (ctx.ok === false) {
    errorOutput.write(`${ctx.message}\n`);
    return ctx.code;
  }
  const fileIds = ctx.descriptors.map(fileIdOf);
  const reader = makeReader(input, output);

  /** Ask until a non-empty line arrives. Returns the trimmed line, or null at end of input. */
  async function ask(prompt) {
    for (;;) {
      const line = await reader.ask(prompt);
      if (line === null) {
        output.write("\n");
        return null;
      }
      const text = line.trim();
      if (text !== "") return text;
    }
  }

  /** Level 3. Returns false when input ended. */
  async function editKey(descriptor, entry, fileId) {
    const cur = readConfig(fileId, ctx);
    if (cur.code !== EXIT.ok) {
      say(cur.message);
      return true;
    }
    const current = Object.prototype.hasOwnProperty.call(cur.value, entry.key) ? cur.value[entry.key] : undefined;
    say("");
    say(`${entry.label} (${fileId}.${entry.key})`);
    say(entry.description);
    say(`Type: ${entry.type}`);
    if (entry.editable !== true) {
      // A nested value can be large: show a bounded preview and point at `get` for the whole thing.
      const full = displayValue(current);
      const clipped = full.length > MAX_DETAIL_CHARS;
      say(`Current value: ${clipped ? `${full.slice(0, MAX_DETAIL_CHARS - 1)}…` : full}`);
      if (clipped) say(`(truncated; the full value is printed by: jenga config get ${fileId}.${entry.key})`);
      say(`Read-only; see ${entry.pointer}`);
      return true;
    }
    constraintLines(entry).forEach(say);
    if (entry.default !== undefined) say(`Default: ${displayValue(entry.default)}`);
    say(`Current value: ${displayValue(current)}`);
    for (;;) {
      const text = await ask(`New value for ${entry.key} (q to go back): `);
      if (text === null) return false;
      if (text === "q") return true;
      const result = setValue(fileId, entry.key, text, ctx);
      if (result.code === EXIT.invalid_value) {
        say(`Rejected: ${result.message}`);
        continue;
      }
      say(result.code === EXIT.ok ? formatSetResult(result) : result.message);
      return true;
    }
  }

  /** Level 2. Returns false when input ended. */
  async function browseKeys(descriptor, fileId) {
    for (;;) {
      const cur = readConfig(fileId, ctx);
      if (cur.code !== EXIT.ok) {
        say(cur.message);
        return true;
      }
      say("");
      say(renderConfigKeys(descriptor, cur.value));
      const text = await ask(`Select a key in ${fileId} (number or name, q to go back): `);
      if (text === null) return false;
      if (text === "q") return true;
      const keyId = pick(text, descriptor.keys.map((k) => k.key));
      if (keyId === null) {
        say(`Not a valid selection: ${text}`);
        continue;
      }
      const entry = descriptor.keys.find((k) => k.key === keyId);
      if ((await editKey(descriptor, entry, fileId)) === false) return false;
    }
  }

  try {
    for (;;) {
      say(renderConfigFiles(ctx.descriptors, ctx.configsDir));
      let chosen = null;
      while (chosen === null) {
        const text = await ask("Select a config file (number or name, q to quit): ");
        if (text === null || text === "q") return EXIT.ok;
        chosen = pick(text, fileIds);
        if (chosen === null) say(`Not a valid selection: ${text}`);
      }
      const descriptor = ctx.descriptors.find((d) => fileIdOf(d) === chosen);
      if ((await browseKeys(descriptor, chosen)) === false) return EXIT.ok;
      say("");
    }
  } finally {
    reader.close();
  }
}

/**
 * jenga config - list and edit Jenga settings (E68_S02_T02, interactive flow wired in E68_S02_T03)
 *
 *   jenga config                          interactive flow (lib/config/interactive.js)
 *   jenga config get <file-id>.<key>      print the current value; read-only keys are readable
 *   jenga config set <file-id>.<key> <v>  validate and write; a bump_on_change counter is incremented atomically
 *
 * The address splits on the FIRST dot: file ids contain no dots (a file id is the config's basename without
 * `.json`), so `scope-thresholds.threshold_version` is unambiguous.
 *
 * This module is argument parsing and exit-code mapping only. Validation, the version bump and the atomic write
 * live in lib/config/store.js, the same path the interactive flow uses. Deterministic: no model call, no network.
 *
 * Exit codes (shared table, lib/config/exit-codes.js): 0 ok, 2 usage, 3 unknown file or key, 4 invalid value,
 * 5 read-only key, 6 config file missing or malformed, 1 an invalid descriptor. Errors go to stderr.
 */
import { EXIT } from "../config/exit-codes.js";
import { runInteractive } from "../config/interactive.js";
import { formatSetResult, getValue, setValue } from "../config/store.js";

export const CONFIG_USAGE = [
  "usage: jenga config                          browse and edit settings interactively",
  "       jenga config get <file-id>.<key>      print a setting's current value",
  "       jenga config set <file-id>.<key> <value>",
  "                                             validate and write a scalar setting",
  "",
  "<file-id> is a config file's name without .json (for example scope-thresholds).",
  "Exit codes: 0 ok, 2 usage, 3 unknown file or key, 4 invalid value, 5 read-only key,",
  "6 config file missing or malformed.",
].join("\n");

function usageError(message) {
  process.stderr.write(`${message}\n${CONFIG_USAGE}\n`);
  return EXIT.usage;
}

/** Split `<file-id>.<key>` on the first dot. Returns { fileId, key } or null. */
function parseAddress(address) {
  const dot = address.indexOf(".");
  if (dot <= 0 || dot === address.length - 1) return null;
  return { fileId: address.slice(0, dot), key: address.slice(dot + 1) };
}

function runGet(rest) {
  if (rest.length !== 1) return usageError("jenga config get takes exactly one argument: <file-id>.<key>");
  const addr = parseAddress(rest[0]);
  if (!addr) return usageError(`"${rest[0]}" is not a <file-id>.<key> address`);
  const r = getValue(addr.fileId, addr.key);
  if (r.code !== EXIT.ok) {
    process.stderr.write(`${r.message}\n`);
    return r.code;
  }
  const v = r.value;
  process.stdout.write(`${typeof v === "string" ? v : JSON.stringify(v)}\n`);
  return EXIT.ok;
}

function runSet(rest) {
  if (rest.length !== 2) return usageError("jenga config set takes exactly two arguments: <file-id>.<key> <value>");
  const addr = parseAddress(rest[0]);
  if (!addr) return usageError(`"${rest[0]}" is not a <file-id>.<key> address`);
  const r = setValue(addr.fileId, addr.key, rest[1]);
  if (r.code !== EXIT.ok) {
    process.stderr.write(`${r.message}\n`);
    return r.code;
  }
  process.stdout.write(`${formatSetResult(r)}\n`);
  return EXIT.ok;
}

/** Dispatch `jenga config ...`. Sets process.exitCode and returns the code. */
export async function runConfig(args) {
  const [sub, ...rest] = args;
  let code;
  if (sub === undefined) {
    code = await runInteractive({ input: process.stdin, output: process.stdout });
  } else if (sub === "--help" || sub === "-h" || sub === "help") {
    process.stdout.write(`${CONFIG_USAGE}\n`);
    code = EXIT.ok;
  } else if (sub === "get") {
    code = runGet(rest);
  } else if (sub === "set") {
    code = runSet(rest);
  } else {
    code = usageError(`unknown config sub-command "${sub}"`);
  }
  process.exitCode = code;
  return code;
}

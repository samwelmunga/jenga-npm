/**
 * jenga progress - show board progress in a real terminal, with colour (E92_S08_T10)
 *
 *   jenga progress <sub-command> [flags]    same as: node lib/progress/cli.js --color always <sub-command> [flags]
 *
 * ANSI colour cannot render in chat markdown, so a rendering copied into a reply is uncoloured; colour is for a real
 * terminal. This command is the short way to get it, without remembering a long `node` path.
 *
 * It is a thin forwarder (decision 4 of story E92_S08), modelled on lib/commands/config.js: it adds no sub-command
 * and no flag. Every sub-command (overview, scope <id>, bar, ...) and every flag (--charset, --layout, --cols, --root,
 * --lang, --help) belongs to lib/progress/cli.js. The one thing it does is add `--color always` unless the caller
 * passed `--color` (in either `--color x` or `--color=x` form).
 *
 * Because that is passed as a FLAG, it outranks the environment variable and the `progress_color` key of
 * dashboard-config.json, exactly as the renderers' precedence (flag, environment, config key, default) says. So
 * `progress_color: never` does not turn this command's colour off; `jenga progress --color never ...` does.
 *
 * The code runs in-process (cli.js exports run(argv, io)), not through a shell. Exit codes are those of cli.js:
 * 0 (including the never-fail warnings on stderr) and 2 for a usage error. Deterministic: no model call, no network.
 *
 * ESM, Node built-ins only; Node >= 14.13.1.
 */

/** True when the argument list already carries a --color flag the user typed. */
export function hasColorFlag(args) {
  return args.some((a) => a === "--color" || a.indexOf("--color=") === 0);
}

/** The argument list handed to cli.js: the user's arguments, with `--color always` in front unless they gave --color. */
export function withDefaultColor(args) {
  return hasColorFlag(args) ? args.slice() : ["--color", "always"].concat(args);
}

/** Dispatch `jenga progress ...`. Sets process.exitCode and returns the exit code of cli.js. */
export async function runProgress(args) {
  const { run } = await import("../progress/cli.js");
  const code = run(withDefaultColor(args));
  process.exitCode = code;
  return code;
}

// RETIRED (E89_S06_T13). This module used to register hooks/prompt_router.sh as a UserPromptSubmit
// hook in a project's .claude/settings.json. That registration is gone: the hook's stdout was injected
// into model context on every prompt and the Router it fronted is being retired (E89_S06_T07, which
// also stopped `jenga init` calling this). It is kept as an inert export so a stale import or an old
// caller cannot crash, but it injects nothing and never touches any settings file.
//
// Do NOT revive it to register the workflow-recorder hook: that hook is carried by the five
// permission-level templates, and consumer-side registration is a separate piece of work.

/**
 * No-op. Retained for import compatibility only; writes nothing.
 * @returns {Promise<void>}
 */
export async function injectSettings() {
  return;
}

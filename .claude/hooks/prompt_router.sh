#!/usr/bin/env bash
# hooks/prompt_router.sh
# RETIRED STUB (E89_S06_T07). Formerly the UserPromptSubmit / userPromptSubmitted hook that routed
# prompts through the Jenga Router. It now emits nothing: under Claude Code a UserPromptSubmit
# hook's stdout is injected into model context, and the old passthrough leaked the whole payload.
# Kept (rather than deleted) so projects that registered it before the fix go quiet on upgrade.
# New projects no longer register it. Stdout is closed here as a belt-and-braces guard, mirroring
# hooks/on_recording_step.sh; tests/prompt-router-silent.bats fails if anything reaches stdout.

exec 1>/dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node "$SCRIPT_DIR/prompt_router_helper.js" >/dev/null 2>&1 || true
exit 0

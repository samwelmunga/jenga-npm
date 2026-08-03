#!/usr/bin/env bash
# hooks/prompt_router.sh
# Claude Code UserPromptSubmit hook — routes prompts through the Jenga Router.
# Reads JSON from stdin, routes through Jenga Router, outputs JSON to stdout.
# Falls back to passthrough if the router is unreachable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/prompt_router_helper.js"

# Pass stdin through the Node.js helper
exec node "$HELPER"

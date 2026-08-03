# jenga-router

A stdio MCP server that routes incoming prompts to the appropriate Jenga skill.

## Usage

```bash
node mcp/router/index.js
```

## Tools

| Tool | Description |
|------|-------------|
| `ping` | Health check — returns `{ ok: true, uptime: <ms> }` |

## Protocol

Communicates over stdin/stdout using the Model Context Protocol (MCP) with `StdioServerTransport`.

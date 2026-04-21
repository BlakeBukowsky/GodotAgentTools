# Agent Tools

Godot editor plugin that exposes **43 tools across 12 namespaces** (scene edits, signal wiring, resource creation, reference validation, animation, headless test runs, etc.) over MCP so coding agents can operate through the editor's real APIs instead of hand-editing `.tscn` / `.tres` / `project.godot` as text.

Works with any MCP-capable client — Claude Code, Claude Desktop, Cursor, Cline, Windsurf, Continue, Zed.

## Quick start

1. Enable this plugin: *Project → Project Settings → Plugins* → tick **Agent Tools**.
2. Confirm the Output panel shows `[agent_tools] listening on 127.0.0.1:9920`.
3. Configure your MCP client to run the bridge — see the [full setup guide](https://github.com/BlakeBukowsky/GodotTools#configure-your-agent) for per-client config paths.

Simplest user-scoped config (for Claude Code, Cursor, Windsurf, etc. — different config file per client):

```json
{
  "mcpServers": {
    "godot-agent-tools": {
      "command": "npx",
      "args": ["-y", "godot-agent-tools-mcp"]
    }
  }
}
```

Full documentation, troubleshooting, and tool catalog: **https://github.com/BlakeBukowsky/GodotTools**

## Raw TCP protocol (if you want to skip MCP)

Line-delimited JSON-RPC on `127.0.0.1:9920`:

```json
{"id": 1, "method": "scene.current", "params": {}}
```

Response:
```json
{"id": 1, "result": {"open": false}}
```

## License

MIT — see [LICENSE](LICENSE).

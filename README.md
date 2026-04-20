# Godot Agent Tools

Exposes Godot editor operations — scene edits, signal wiring, resource creation, reference validation, input map management, headless test runs — over [MCP](https://modelcontextprotocol.io) so coding agents can work inside a Godot project through the editor's real APIs instead of hand-editing `.tscn` / `.tres` / `project.godot` as text.

## Why

`.tscn`, `.tres`, and `project.godot` are Godot-specific text formats with fragile invariants: UIDs, sub-resource IDs, inherited-scene overrides, signal `[connection]` blocks, and autoload metadata. An agent editing these as plain text will silently corrupt them. This plugin routes every write through Godot's own `PackedScene` / `ResourceSaver` / `ClassDB` / `ResourceUID` APIs, so UIDs stay stable, IDs stay unique, and scenes survive round-tripping.

## Components

1. **Godot addon** (`addons/agent_tools/`) — editor plugin that exposes 32 tools over a localhost TCP JSON-RPC socket (default `127.0.0.1:9920`).
2. **MCP shim** (`mcp/server.mjs`) — Node.js process that speaks MCP to your agent and forwards tool calls to the running Godot editor. Works with any MCP-capable client (Claude Code, Claude Desktop, Cursor, Cline, Windsurf, Continue, Zed, etc.).

The addon is pure GDScript — no native extensions, no build step. The shim is ~200 lines of plain Node.

## Requirements

- Godot **4.3+** (developed against 4.6)
- Node.js **18+** (for the MCP shim)
- Any MCP-capable coding agent

## Install

### Addon (per Godot project)

Copy `addons/agent_tools/` into your project's `addons/` directory, then:

1. Open the project in Godot
2. *Project → Project Settings → Plugins* → tick **Agent Tools**
3. Confirm the Output panel shows `[agent_tools] listening on 127.0.0.1:9920`

### MCP shim (once per machine)

```bash
git clone <this-repo>
cd <this-repo>/mcp
npm install
```

## Configure your MCP client

Every client ends up running `node /abs/path/to/mcp/server.mjs`.

<details>
<summary><b>Claude Code</b> — project-scoped</summary>

`.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "godot-agent-tools": {
      "command": "node",
      "args": ["/abs/path/to/mcp/server.mjs"]
    }
  }
}
```
</details>

<details>
<summary><b>Claude Desktop</b></summary>

Edit `claude_desktop_config.json` (in your OS config dir):

```json
{
  "mcpServers": {
    "godot-agent-tools": {
      "command": "node",
      "args": ["/abs/path/to/mcp/server.mjs"]
    }
  }
}
```
</details>

<details>
<summary><b>Cursor / Windsurf / Cline / VS Code / Continue / Zed</b></summary>

Same shape — point each client's MCP config at `node /abs/path/to/mcp/server.mjs`. Consult the client docs for the correct config path.
</details>

### Environment variables

| Var | Default | Purpose |
|---|---|---|
| `GODOT_AGENT_HOST` | `127.0.0.1` | Host the shim dials |
| `GODOT_AGENT_PORT` | `9920` | Port the addon listens on |
| `GODOT_AGENT_TIMEOUT_MS` | `15000` | Per-call timeout |

## Usage

1. Open your Godot project in the editor with the addon enabled.
2. Start a session in your MCP client.
3. The agent can now invoke tools like `scene_add_node`, `signal_connect`, `refs_find_usages`, `run_scene_headless`.

Typical agent-driven flow for "create a main scene with a player":

```
scene_new           path=res://Main.tscn root_type=Node2D
scene_add_node      type=CharacterBody2D name=Player
script_create       path=res://scripts/player.gd extends=CharacterBody2D attach_to_node=Player
signal_connect      from=Player signal=body_entered to=. method=_on_player_body_entered
scene_save
refs_validate_project
run_scene_headless  path=res://Main.tscn quit_after_seconds=1
```

## Tool catalog

**32 tools** across 11 namespaces:

| Namespace | Tools |
|---|---|
| `scene` | `new`, `open`, `current`, `save`, `inspect`, `add_node`, `remove_node`, `reparent`, `set_property`, `instance_packed` |
| `signal` | `connect`, `disconnect`, `list` |
| `script` | `create`, `attach` |
| `resource` | `create`, `set_property` |
| `refs` | `validate_project`, `find_usages`, `rename` |
| `project` | `get_setting`, `set_setting` |
| `autoload` | `add`, `remove`, `list` |
| `input_map` | `add_action`, `add_event`, `list`, `remove_action` |
| `docs` | `class_ref` |
| `run` | `scene_headless` |
| `editor` | `reload_filesystem` |

Each tool's full JSON schema is declared in [`mcp/server.mjs`](mcp/server.mjs).

### Highlights

- **`refs.find_usages`** searches for both a resource's path form and its `uid://` form, so it catches UID-indirected references a plain grep misses.
- **`refs.rename`** moves a file, its `.uid` and `.import` sidecars, and rewrites every path-form reference (including `project.godot` autoload entries). Supports `dry_run`.
- **`signal.connect`** validates that the signal exists on the source, the method exists on the target, and arity matches — before persisting the connection.
- **`docs.class_ref`** returns a class's methods / properties / signals / constants from `ClassDB` so agents plan against real API instead of guessing.
- **`run.scene_headless`** spawns a child `godot --headless` process and returns exit code + combined stdout/stderr — the only way to catch runtime errors the static validator can't see.

## Skipping MCP — raw TCP protocol

The addon's TCP server speaks line-delimited JSON-RPC. Useful for debugging or non-MCP clients.

Request:
```json
{"id": 1, "method": "scene.current", "params": {}}
```

Response:
```json
{"id": 1, "result": {"open": false}}
```

Error:
```json
{"id": 1, "error": {"code": -32001, "message": "no scene open"}}
```

Quick test from PowerShell (no deps):

```powershell
$c=[Net.Sockets.TcpClient]::new('127.0.0.1',9920); $s=$c.GetStream(); $w=[IO.StreamWriter]::new($s); $r=[IO.StreamReader]::new($s); $w.WriteLine('{"id":1,"method":"scene.current","params":{}}'); $w.Flush(); $r.ReadLine(); $c.Close()
```

## Development

Contributing a new tool takes three edits:

1. Add a `static func` to the relevant module in `addons/agent_tools/tools/` (returns `{"data": ...}` or `{"error": {"code", "message"}}`).
2. Add a dispatch line to `addons/agent_tools/registry.gd`.
3. Add an MCP schema entry to `mcp/server.mjs`.

After editing GDScript, toggle the plugin off/on in *Project Settings → Plugins* — Godot's hot-reload doesn't always refresh preloaded modules. After editing `server.mjs`, reload the MCP connection in your agent.

See [`AGENTS.md`](AGENTS.md) for more conventions (if present).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Godot editor not reachable on 127.0.0.1:9920` | Editor isn't running, or plugin isn't enabled. Confirm via the Output panel message. |
| Tool returns `method not found: <name>` | Registry doesn't know about it — toggle the plugin to reload. |
| Every tool in a module returns `null` | Parse error in that module's `.gd` file — toggle and check Godot's Output panel for the error. |
| Port already in use | Another process holds `9920`. Set `GODOT_AGENT_PORT` in both the addon (edit `plugin.gd`) and the shim's env. |
| MCP client shows old tool list | Shim caches `TOOLS` at startup; restart the MCP connection after editing `server.mjs`. |

## License

MIT — see [LICENSE](LICENSE).

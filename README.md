# Godot Agent Tools

Let coding agents (Claude Code, Cursor, Cline, Windsurf, Claude Desktop, etc.) work inside your Godot project safely — editing scenes, wiring signals, creating resources, validating references, and running headless smoke tests through the editor's real APIs instead of hand-editing `.tscn` / `.tres` / `project.godot` as text.

**48 tools** across 13 namespaces. Works with any MCP-capable agent. Godot 4.3+.

---

## The 2-minute install

1. **Install the addon in your Godot project.**
   - *Project → AssetLib* tab → search **Agent Tools** → *Download* → *Install*
   - *Project → Project Settings → Plugins* → tick **Agent Tools**
2. **Point your agent at it.** [Pick your agent below](#configure-your-agent) and paste the snippet into the right config file.
3. **Restart your agent** and call `scene_current` to sanity-check. Done.

No Node.js install required — `npx` downloads the MCP shim on first use.

---

## Why this exists

`.tscn`, `.tres`, and `project.godot` are Godot-specific text formats with fragile invariants: UIDs, sub-resource IDs, inherited-scene overrides, signal `[connection]` blocks, autoload metadata. An agent editing these as plain text will silently corrupt them. This plugin routes every write through Godot's own `PackedScene` / `ResourceSaver` / `ClassDB` / `ResourceUID` APIs, so UIDs stay stable, IDs stay unique, and scenes survive round-tripping.

---

## Requirements

- **Godot 4.3+** (developed and tested on 4.6)
- **Node.js 18+** — only needed the first time `npx` runs the MCP shim; no manual install
- Any **MCP-capable agent**

---

## Install

### Addon (per Godot project)

**Asset Library (recommended):**

1. Open your project in Godot
2. Click the *AssetLib* tab at the top of the editor
3. Search for **Agent Tools**, hit *Download* → *Install*
4. *Project Settings → Plugins* → enable **Agent Tools**

**Manual (if the Asset Library entry is unavailable):**

```bash
# From this repo:
cp -r addons/agent_tools /path/to/your/godot/project/addons/
```

Then enable in *Project Settings → Plugins*.

### MCP shim

**No install.** The shim is published to npm as [`godot-agent-tools-mcp`](https://www.npmjs.com/package/godot-agent-tools-mcp). The config snippets below use `npx -y godot-agent-tools-mcp`, which fetches and caches on first run.

---

## Configure your agent

Pick your agent below. Every snippet is the same two lines (`"command": "npx"` + `"args": ["-y", "godot-agent-tools-mcp"]`) — only the **file path** differs.

Two scopes to choose from:
- **Project-scoped**: config lives in your Godot project; only that project sees the tools.
- **User-scoped**: config lives in your home directory; every project on the machine sees the tools.


<details>
<summary><b>Claude Code</b></summary>

**Project-scoped** — create `.mcp.json` at your project root with:
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

**User-scoped** (works in every project) — add the same `godot-agent-tools` entry under `mcpServers` in:
- macOS / Linux: `~/.claude.json`
- Windows: `%USERPROFILE%\.claude.json`

Restart Claude Code after editing.
</details>

<details>
<summary><b>Claude Desktop</b></summary>

Edit the config file for your OS:
- **macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows**: `%APPDATA%\Claude\claude_desktop_config.json`
- **Linux**: `~/.config/Claude/claude_desktop_config.json`

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

Quit and relaunch Claude Desktop (the tray icon; not just the window).
</details>

<details>
<summary><b>Cursor</b></summary>

**Project-scoped**: `.cursor/mcp.json` at the project root.
**User-scoped**: `~/.cursor/mcp.json`.

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

Reload Cursor (*Cmd/Ctrl+Shift+P → "Reload Window"*).
</details>

<details>
<summary><b>Windsurf</b></summary>

File: `~/.codeium/windsurf/mcp_config.json`

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
</details>

<details>
<summary><b>Cline (VS Code extension)</b></summary>

Open the Cline sidebar → click the *MCP Servers* icon → *Configure MCP Servers*. That opens the settings file; add:

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
</details>

<details>
<summary><b>VS Code (native MCP support)</b></summary>

**Project-scoped**: `.vscode/mcp.json` at the project root.
**User-scoped**: in VS Code `settings.json` under `"mcp.servers"`.

```json
{
  "servers": {
    "godot-agent-tools": {
      "command": "npx",
      "args": ["-y", "godot-agent-tools-mcp"]
    }
  }
}
```
</details>

<details>
<summary><b>Continue.dev</b></summary>

File: `~/.continue/config.json`. Add under `experimental.modelContextProtocolServers`:

```json
{
  "experimental": {
    "modelContextProtocolServers": [
      {
        "transport": {
          "type": "stdio",
          "command": "npx",
          "args": ["-y", "godot-agent-tools-mcp"]
        }
      }
    ]
  }
}
```
</details>

<details>
<summary><b>Zed</b></summary>

In Zed's `settings.json` (*Cmd/Ctrl+,*):

```json
{
  "context_servers": {
    "godot-agent-tools": {
      "command": {
        "path": "npx",
        "args": ["-y", "godot-agent-tools-mcp"]
      }
    }
  }
}
```
</details>

### Environment variables (shim side, optional)

| Var | Default | Purpose |
|---|---|---|
| `GODOT_AGENT_HOST` | `127.0.0.1` | Host the shim dials |
| `GODOT_AGENT_PORT` | `9920` | Port the addon listens on |
| `GODOT_AGENT_TIMEOUT_MS` | `15000` | Per-call timeout |

---

## Verify

1. Open your Godot project in the editor; confirm the Output panel shows:
   ```
   [agent_tools] listening on 127.0.0.1:9920
   ```
2. In your agent, run `scene_current` — should return `{"open": true, ...}` if a scene is open, or `{"open": false}` otherwise.
3. Run `refs_validate_project` — should return `{"checked": N, "issues": []}` (give or take — issues are real findings).

If either of those returns an error, see [Troubleshooting](#troubleshooting).

---

## Usage

A typical agent-driven flow ("create a main scene with a player"):

```
scene_new           path=res://Main.tscn root_type=Node2D
scene_add_node      type=CharacterBody2D name=Player
script_create       path=res://scripts/player.gd extends=CharacterBody2D attach_to_node=Player
signal_connect      from=Player signal=body_entered to=. method=_on_player_body_entered
scene_save
refs_validate_project
run_scene_headless  path=res://Main.tscn quit_after_seconds=1
```

---

## Tool catalog

**48 tools** across 13 namespaces:

| Namespace | Tools |
|---|---|
| `scene` | `new`, `open`, `current`, `save`, `inspect`, `add_node`, `build_tree`, `remove_node`, `reparent`, `duplicate_node`, `set_property`, `get_property`, `call_method`, `instance_packed`, `capture_screenshot` |
| `signal` | `connect`, `disconnect`, `list` |
| `script` | `create`, `attach` |
| `resource` | `create`, `set_property`, `call_method` |
| `refs` | `validate_project`, `find_usages`, `rename`, `rename_class` |
| `project` | `get_setting`, `set_setting` |
| `autoload` | `add`, `remove`, `list` |
| `input_map` | `add_action`, `add_event`, `list`, `remove_action`, `remove_event` |
| `animation` | `list`, `add_animation`, `remove_animation`, `add_value_track` |
| `docs` | `class_ref` |
| `fs` | `list` |
| `user_fs` | `read`, `list` |
| `run` | `scene_headless` (supports scripted input + screenshot capture) |
| `editor` | `reload_filesystem`, `save_all_scenes` |

Full JSON schemas live in [`mcp/server.mjs`](mcp/server.mjs).

### Highlights

- **`refs.find_usages`** searches for both the path form and the `uid://` form of a target, catching UID-indirected references a plain grep would miss.
- **`refs.rename`** moves a file + its `.uid` and `.import` sidecars, and rewrites every path-form reference (including `project.godot` autoload entries). Supports `dry_run`.
- **`signal.connect`** validates that the signal exists on the source, the method exists on the target, and arity matches — before persisting the connection.
- **`docs.class_ref`** returns a class's methods / properties / signals / constants straight from `ClassDB` so agents plan against real API, not hallucinated API.
- **`run.scene_headless`** spawns a child `godot --headless` process and returns exit code + combined stdout/stderr — the only way to catch runtime errors the static validator can't see.
- **`scene.capture_screenshot`** saves a PNG of the editor viewport (clean — no grid/gizmos) so agents can verify visual layout. Empty scenes render as the viewport background color.
- **`refs.rename_class`** rewrites `class_name X` and every word-boundary reference across `.gd`/`.tscn`/`.tres`. Complements `refs.rename` (which is file-based).
- **`animation.*`** manipulates `AnimationPlayer` resources — animations in `.tscn` text form are one of the least agent-friendly surfaces in Godot.
- **`scene.build_tree`** collapses "build a 30-node UI" from dozens of `add_node` + `set_property` round trips into a single recursive spec. Atomic: full rollback on any failure.
- **`scene.call_method` / `resource.call_method`** invoke any method with argument coercion — so helpers like `StyleBoxFlat.set_border_width_all(4)` don't force agents to write a `.gd` script just to call them.

---

## Skipping MCP — raw TCP protocol

The addon's TCP server speaks line-delimited JSON-RPC. Useful for scripting or non-MCP clients.

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

Quick probe from PowerShell (no deps):

```powershell
$c=[Net.Sockets.TcpClient]::new('127.0.0.1',9920); $s=$c.GetStream(); $w=[IO.StreamWriter]::new($s); $r=[IO.StreamReader]::new($s); $w.WriteLine('{"id":1,"method":"scene.current","params":{}}'); $w.Flush(); $r.ReadLine(); $c.Close()
```

---

## Development

If you're hacking on the plugin itself, see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions. Short version:

1. Adding a tool = three edits (tool file, `registry.gd`, `mcp/server.mjs`).
2. After editing GDScript, **toggle the plugin** off/on in *Project Settings → Plugins* — hot-reload doesn't always refresh preloaded modules.
3. After editing `server.mjs`, **reload the MCP connection** in your agent — the tool list is cached at startup.

To run the shim from source (instead of npm) for dev:

```bash
git clone https://github.com/BlakeBukowsky/GodotTools.git
cd GodotTools/mcp
npm install
# Then point your agent's MCP config at:
# "command": "node", "args": ["/abs/path/to/GodotTools/mcp/server.mjs"]
```

To smoke-test the plugin end-to-end (needs the editor running with plugin enabled):

```bash
node tests/smoke.mjs
```

Exercises ~25 tool calls covering create/read/update/delete flows, cleans up `res://__smoketest/` after itself, exits non-zero on the first failure.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Agent can't see any `godot_*` or `scene_*` tools | MCP config not picked up. Check that the snippet landed in the right file for your agent (see [config table](#configure-your-agent)), then restart the agent. |
| `Godot editor not reachable on 127.0.0.1:9920` | Editor isn't running, or the plugin isn't enabled. Confirm the `[agent_tools] listening...` line in the Output panel. |
| Tool call returns `method not found: <name>` | Either the plugin is out of date (update the addon) or the registry cached the old dispatch table — toggle the plugin. |
| Every tool in a module returns `null` | Parse error in that module's `.gd` file. Toggle the plugin and watch the Output panel for the actual error. |
| `npx` errors with `ENOTFOUND registry.npmjs.org` | Network / firewall issue. Try `npx -y godot-agent-tools-mcp` manually from a terminal first to confirm. |
| Port `9920` already in use | Another process has it. Edit `plugin.gd`'s `DEFAULT_PORT` constant and set `GODOT_AGENT_PORT` in your agent's MCP env. |

---

## License

MIT — see [LICENSE](LICENSE).

---

## Links

- [Godot Asset Library entry](https://godotengine.org/asset-library) (search "Agent Tools")
- [npm: godot-agent-tools-mcp](https://www.npmjs.com/package/godot-agent-tools-mcp)
- [Issues](https://github.com/BlakeBukowsky/GodotTools/issues)
- [Model Context Protocol](https://modelcontextprotocol.io)

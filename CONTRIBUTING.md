# Contributing

Guide for contributors — humans and AI coding agents alike.

## Architecture

Two components that talk to each other over localhost TCP:

- **`addons/agent_tools/`** — Godot editor plugin, pure GDScript. Runs as an `EditorPlugin`, opens a TCP server on `127.0.0.1:9920`, dispatches JSON-RPC requests to tool modules.
- **`mcp/`** — Node.js MCP server. Speaks MCP over stdio to an agent, forwards each tool call over TCP to the plugin, returns results.

Each tool lives in a module under `addons/agent_tools/tools/` and is exposed through `registry.gd`.

## Adding a new tool

Always three edits:

1. **Add a `static func`** to the relevant module in `addons/agent_tools/tools/` (or create a new module if it's a new namespace).
2. **Add a dispatch line** to `addons/agent_tools/registry.gd`.
3. **Add an MCP schema entry** to the `TOOLS` array in `mcp/server.mjs`.

Forgetting step 3 means the agent can't discover the tool. Forgetting step 2 means the TCP layer returns `method not found`.

## Return shape

Every tool function returns a `Dictionary` with exactly one of:

```gdscript
return {"data": <any>}                                        # success
return {"error": {"code": int, "message": str, "data"?: any}} # failure
```

Use the `_ok()` / `_err()` helpers that each tool file defines — don't open-code them.

Error codes roughly follow JSON-RPC conventions: `-32602` for bad params, `-32601` for method-not-found, `-32001` for "tool-level" failures (node not found, file missing, etc.).

## Reload dance

Godot's GDScript hot-reload does **not** reliably refresh:
- `preload()`ed modules held by `EditorPlugin`
- Already-instantiated class instances holding old bytecode

Reload rules:

| You changed | Do |
|---|---|
| A tool function body | Usually hot-reloads. Toggle plugin if anything seems stale. |
| `registry.gd` dispatch entries | **Always toggle plugin** (Project Settings → Plugins → uncheck → recheck). |
| Any function signature, new module, new preload | **Always toggle plugin.** |
| `mcp/server.mjs` | Restart the MCP connection in your agent. The `TOOLS` array is cached at server startup. |

**Symptom → cause table:**
- Every call into a module returns `null` → parse error in that `.gd` file. Toggle + check Godot's Output panel.
- `method not found` for something you just added → forgot to update `registry.gd`, or the plugin didn't reload.
- MCP client doesn't see a new tool → forgot to update `mcp/server.mjs`, or didn't restart the MCP connection.

## Known landmines

These are real bugs we've already hit. Don't relearn them.

- **`EditorInterface.save_scene_as()` returns `void`** in Godot 4.x — not `Error`. Assigning it to `var err: int` is a parse error that kills the whole file silently.
- **`GDScript.new()` + `reload()` false-positives on any script with `class_name`** — duplicate global class registration. Use `ResourceLoader.load(path, "Script")` to validate scripts.
- **`project.godot` is not matched by default file walks** in `refs_tools.gd`. The extension list must include `"godot"` or `find_usages`/`rename` silently misses autoload references.
- **`PROPERTY_USAGE_STORAGE` does not distinguish user-added project settings from Godot's built-in defaults** — Godot's `ui_*` input actions also have STORAGE set. To enumerate only user-added actions, parse the `[input]` section of `project.godot` via `ConfigFile` directly.
- **`{"data": null}` on the TCP wire is how the client sees a GDScript runtime error** that failed silently. If you see that, your tool module likely has a parse error, not a logic bug.

## Testing

Quick TCP-layer smoke test (PowerShell, no deps):

```powershell
$c=[Net.Sockets.TcpClient]::new('127.0.0.1',9920); $s=$c.GetStream(); $w=[IO.StreamWriter]::new($s); $r=[IO.StreamReader]::new($s); $w.WriteLine('{"id":1,"method":"scene.current","params":{}}'); $w.Flush(); $r.ReadLine(); $c.Close()
```

Full-stack test: open an MCP session in your agent and call tools. The `refs_validate_project` tool is a good all-in-one smoke test — it exercises file walking, script parsing, and scene loading.

## Versioning & release

Keep these three in sync:
- `addons/agent_tools/plugin.cfg` → `version=`
- `mcp/package.json` → `"version":`
- git tag on the commit that bumps both

Release flow:
```bash
# bump both files, then:
git commit -m "vX.Y.Z"
git tag vX.Y.Z
git push && git push --tags
cd mcp && npm publish
# update Asset Library submission with the new commit SHA
```

Docs-only changes (README, AGENTS.md) don't need a version bump — just commit and push.

## File organization

- One module per namespace. Existing namespaces go in existing files:
  - `scene_tools.gd` — scene.*
  - `signal_tools.gd` — signal.*
  - `script_tools.gd` — script.*
  - `resource_tools.gd` — resource.*
  - `refs_tools.gd` — refs.*
  - `project_tools.gd` — project.*, autoload.*
  - `editor_tools.gd` — editor.*
  - `docs_tools.gd` — docs.*
  - `input_tools.gd` — input_map.*
  - `run_tools.gd` — run.*

- New namespace → new file. Don't cross-pollinate.

- MCP tool names are **underscore-separated** (`scene_add_node`). They map to dot-separated Godot method names (`scene.add_node`). Keep the pattern consistent.

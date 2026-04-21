# Changelog

All notable changes to this project will be documented here. Versions on the Godot addon
(`addons/agent_tools/plugin.cfg`) and the MCP shim (`mcp/package.json`) stay in sync.

## [0.3.0] — 2026-04-21

Competitive-parity pass against the broader Godot-AI tool surface, plus MCP Resources.

### Added (third pass)

- **Real multi-editor session routing.** Plugin now scans ports 9920–9929 for a free one and writes a per-PID descriptor to `<home>/.godot-agent-tools/sessions/<pid>.json` containing `{pid, port, project_path, project_name, godot_version, started_at_unix}`. The MCP shim reads this registry on every call to resolve a target, filters dead sessions by PID-alive check, and defaults to the most-recently-started one. New shim-local tools `session.list` and `session.activate` let an agent enumerate running editors and pin subsequent calls to a specific PID. `GODOT_AGENT_PORT` env var still forces a specific target and bypasses discovery.
- **Three more MCP clients in `client.configure`.** Added `windsurf_user` (`~/.codeium/windsurf/mcp_config.json`), `continue_user` (`~/.continue/config.json`, writes into `experimental.modelContextProtocolServers` array with transport-match dedup), `vscode_project` (`.vscode/mcp.json` with VS Code's `servers` schema). Full list now: `claude_code_project`, `claude_code_user`, `claude_desktop`, `cursor_project`, `cursor_user`, `windsurf_user`, `continue_user`, `vscode_project`. Zed / VS Code user / Cline still need manual setup (JSONC-with-comments + editor-UI-only storage respectively).

### Added (second pass)

- **`test.run` — first-class test framework integration.** Detects GUT (`addons/gut`) or GdUnit4 (`addons/gdUnit4`), invokes the framework's CLI runner via a headless subprocess, and parses the output into `{total, passed, failed, skipped, failures: [{name, file, line}]}`. Higher level than `run.scene_headless` — understands framework concepts instead of making the agent regex stdout.
- **`client.configure` / `client.list` / `client.remove`.** Manage MCP client config files without hand-editing. Initial client list: `claude_code_project` (writes `.mcp.json` at project root), `claude_code_user` (`~/.claude.json`), `claude_desktop` (OS-specific), `cursor_project` (`.cursor/mcp.json`), `cursor_user` (`~/.cursor/mcp.json`). Idempotent — won't duplicate an existing entry; `overwrite:true` to force-replace.
- **`physics.autofit_collision_shape_2d`.** Given a Sprite2D or AnimatedSprite2D, sizes a CollisionShape2D (rectangle / circle / capsule) to match the sprite's visual bounds and centers it. Auto-creates the CollisionShape2D if missing (`create:true`). Respects sprite offset, centering, scale, and region_rect.
- **Theme helpers — `theme.set_color`, `theme.set_constant`, `theme.set_font_size`, `theme.set_stylebox_flat`.** Wrap Theme's awkward `(item_name, type_name, value)` API. `set_stylebox_flat` is a recipe tool — creates a `StyleBoxFlat` with the given properties (via `Coerce`) and assigns it in one call, replacing the usual multi-step setup.
- **Multi-editor port configuration.** Plugin now reads `agent_tools/port` from `project.godot` (falls back to default 9920). Different Godot projects can bind to different ports; MCP clients target via `GODOT_AGENT_PORT` env var. Simple alternative to full session routing for the common "I have two editors open" case.

### Added (first pass)

- **`editor.game_screenshot` + live-game bridge.** New autoload (`_MCPGameBridge`, auto-registered by the plugin) runs inside the running game and handles capture requests via a file-based IPC channel under `res://.godot/agent_tools/bridge/`. Tool writes a request, polls for the response PNG, returns. Works for scenes that the user has pressed Play on — complements (doesn't replace) `run.scene_headless` which spawns its own subprocess. Falls back with a clear error when no game is running.
- **`logs.read` / `logs.clear` — live game log capture.** Same autoload attaches a custom `Logger` via `OS.add_logger()`, streaming every `print` / `push_error` / `push_warning` into a ring buffer written to `res://.godot/agent_tools/bridge/logs.json`. Agent reads structured entries (`{level, message, time_ms}`) without shelling out or regex-parsing.
- **`performance.monitors`.** One tool call for FPS, frame/physics time, memory (static + max), object/node/resource/orphan counts, draw calls, primitives, 2D items, video memory, audio latency, 2D/3D physics active objects. Default returns a common set; pass `monitors: ["fps", "draw_calls", ...]` for targeted reads.
- **`editor.state`.** Consolidated editor + project status: Godot version, project name, current scene details, open scenes list, play state, playing scene path. Replaces piecewise `scene.current` + `project.get_setting` patterns.
- **`editor.selection_get` / `editor.selection_set`.** Read or set the editor tree dock's selection — lets agents cooperate with manual editor work (operate on what the user clicked, or point the user at what the agent just built).
- **`script.patch`.** Incremental `.gd` edits. `replacements: [{old, new}]` requires each `old` to appear exactly once (ambiguous or missing matches error cleanly); alternative `full_source` overwrites. Parse-checks the result via `ResourceLoader.load`; **rolls back to the original source if parsing fails**, so a bad patch can't leave a broken script on disk. Supports `dry_run`.
- **`fs.read_text` / `fs.write_text`** for `res://`. `write_text` auto-creates parent dirs and triggers a filesystem rescan so new files appear in the FileSystem dock immediately.
- **`batch.execute`.** Dispatch multiple tool calls in one round trip, returning per-call results. Saves TCP round trips on long known sequences. Optional `stop_on_error`.
- **MCP Resources (protocol-level addition).** `godot://editor/state`, `godot://scene/current`, `godot://scene/hierarchy`, `godot://selection/current`, `godot://logs/recent`, `godot://performance/monitors`. Agents that support MCP Resources can subscribe to these read-only endpoints instead of polling tools.

### Changed

- **README has an "Agent Tools vs. Godot AI" section.** Honest breakdown of where each plugin is stronger, plus a tool-count-philosophy note (dense/generic vs wide/specific). Users can run both servers simultaneously without conflict.
- **Plugin auto-registers `_MCPGameBridge` autoload** on enable and removes it on disable. First time you enable the plugin, `project.godot` gets a new `autoload/_MCPGameBridge` entry; disabling cleanly removes it.

## [0.2.1] — 2026-04-21

### Added

- **`run.scene_headless` — full verification pass.** Moves from "does the scene load" to structured runtime verification:
  - **Scripted input.** `input_script` array of frame-indexed events (`action_press/release/tap`, `key`, `mouse_click`, `mouse_motion`) executed by a shipped wrapper driver (`addons/agent_tools/headless/driver.tscn`).
  - **Multi-frame screenshots.** Either `screenshot: "path"` (shorthand for one capture at quit) or `screenshots: [{frame, path}, ...]` for checkpoints across the run. Lets agents verify transitions, not just end state.
  - **Configurable resolution.** `resolution: "1280x720"` (default `"320x240"` for minimal footprint) — bump up for UI verification where text and small detail matter.
  - **Structured error extraction.** Tool parses stdout for `ERROR:` / `USER ERROR:` / `SCRIPT ERROR:` / `WARNING:` / `USER WARNING:` lines (plus the immediate "at: file:line" trailer) and returns them as `result.errors` and `result.warnings` arrays. "Did it run clean?" = `errors.length === 0`, no regex required.
  - **Final state dump.** `state_dump: true` makes the driver write a JSON snapshot of the final scene tree (name, class, node_path, script, children, plus common properties like `visible`/`position`/`text`/`value`/`modulate`/`color`) that the tool returns as `result.final_state`. Lets agents verify end state programmatically.
  - **Deterministic seed.** `seed: 42` calls `seed()` before the target scene is instanced so `randi`/`randf` are reproducible.
- **Screenshot rendering workaround.** Godot 4.6's `--headless` forces a Dummy renderer that can't capture (null texture via `viewport.get_texture()`, signal-11 crash via `--write-movie`). When screenshots are requested, the tool drops `--headless` and runs windowed offscreen (`--windowed --position -9999,-9999`). Bare runs (no screenshot) still use `--headless` and remain fully invisible.
- **`user_fs.read` / `user_fs.list`.** Read-side access to `user://` (the game's runtime data directory — save files, custom-level JSON, settings). Complements `fs.list` which is `res://`-only. Save/load debugging no longer requires running the editor and eyeballing files.
- **`scene.build_tree` — bulk node construction.** Takes a recursive spec `[{type, name?, properties?, script?, children?: [...]}, ...]` and builds the whole subtree in one call. Properties use the same coercion as `scene.set_property`; scripts are attached before properties so script-exported vars are settable in the same spec. Fully atomic — on any failure (unknown class, missing property, coercion error, read-only slot, silent-null assignment), every node created during the call is rolled back. Closes the 30+ round-trip gap where a modestly nested UI scene used to lose to direct `.tscn` authoring.
- **`scene.call_method` and `resource.call_method`.** Invoke any method on a node in the current scene or on a resource file. Args are coerced against the method's declared parameter types (same rules as `set_property`, including `res://...` → Resource auto-load). Return values are serialized to JSON via `Coerce.to_json`. Closes the gap where agents previously had to write a `.gd` script just to call helpers like `StyleBoxFlat.set_border_width_all(4)` or `Curve.add_point(...)`. `resource.call_method` takes an optional `save: false` for read-only calls.

### Changed

- **`value` echoes in `scene.set_property` / `scene.get_property` / `resource.set_property` now return JSON-native data** via the new `Coerce.to_json()` helper, instead of Godot's stringified form. A Vector2 comes back as `[x, y]` (not `"(x, y)"`), a Color as `[r, g, b, a]`, an Object as `{class, resource_path?}` or `null`, a Transform2D as `{origin, x, y}`, packed arrays as plain arrays, and so on. Agents can now programmatically verify the stored value matches what they sent, rather than parsing Godot's `str()` output that made silent-failure sentinels like `"<Object#null>"` blend in with successful echoes.
- **Reject writes to read-only properties upfront.** `scene.set_property` and `resource.set_property` now check `PROPERTY_USAGE_READ_ONLY` and return an explicit error instead of letting Godot silently ignore the `set()`.

- **Extracted `_coerce` to a shared `tools/_coerce.gd` helper**, now also hosting `Coerce.to_json()`. It was duplicated between `scene_tools.gd` and `resource_tools.gd` and had already drifted once (the TYPE_OBJECT fix had to be applied twice). Both modules now `preload("res://addons/agent_tools/tools/_coerce.gd")` and call `Coerce.coerce(value, target_type)`. New coercions go in one place.

### Fixed

- **`scene.save` no longer triggers Godot's native Save-As dialog on fresh scenes.** When the currently-edited scene had never been saved and the caller didn't pass `path`, `EditorInterface.save_scene()` would pop the blocking Save-As file dialog — requiring a human click to resolve. Now the tool detects `scene_file_path == ""` upfront and returns a clean error ("pass 'path'") so the agent can react instead of hanging. Passing `path` explicitly still works without any dialog via `save_scene_as()`.
- **`scene.save` with a path now creates parent directories and detects silent save failures.** `EditorInterface.save_scene_as(path)` does NOT auto-create missing directories — it silently fails and leaves the scene unbound. The tool now calls `make_dir_recursive_absolute` on the target dir before saving, and checks that the scene actually got bound to the new path post-save, returning an explicit error if it didn't (instead of a misleading `{"path": ""}` success echo).
- **`scene.set_property` / `resource.set_property` now auto-load Resource paths.** Passing `"res://foo.tres"` or `"uid://..."` to a Resource-typed property (e.g. `shape` on a CollisionShape2D) used to silently drop the assignment — the string couldn't fit in an Object slot, leaving the slot null while the tool returned a misleading `"value": "<Object#null>"` echo. Now: path strings are resolved via `ResourceLoader.load()` before assignment, and if the store still ends up null after set, the tool returns an explicit error naming the mismatch instead of pretending success.
- **Expanded type coercion for `scene.set_property` / `resource.set_property`.** Added `Vector3i`, `Vector4`, `Vector4i`, `Rect2`, `Rect2i`, `Quaternion`, `Transform2D`, `Transform3D`, `Basis`, `AABB`, `Plane`, and all `Packed{String,Int32,Int64,Float32,Float64,Vector2,Vector3,Color}Array` variants. Transforms use an ergonomic TRS dict form — `Transform2D` takes `{origin, rotation (radians), scale, skew?}`; `Transform3D` / `Basis` take `{origin?, rotation: [x,y,z] euler radians, scale}`. Packed arrays coerce element-wise. Tool descriptions now enumerate the full supported-type list so agents don't have to trial-and-error. Still deferred: `Projection`, `Callable`, `Signal`, `RID`.
- **`input_map.add_event` now supports `device` and `joy_motion`.** Every event shape accepts an optional `device` field (default `-1` = all devices; set `0`, `1`, etc. for local-multiplayer per-controller bindings). Added a fourth event type `{type: "joy_motion", axis, axis_value}` with axis accepting int 0..5 or friendly names (`"left_x"`, `"trigger_left"`, etc.). Previously only `key` / `mouse_button` / `joy_button` events were expressible and there was no way to bind an analog stick or distinguish controllers, so local-multiplayer setups required hand-editing `project.godot`.

## [0.2.0] — 2026-04-21

### Added

- **`scene.capture_screenshot`** — save a PNG of the editor viewport for the open scene (2D or 3D selected automatically). Clean capture, no grid/gizmos.
- **`scene.get_property`** — read a property from a node. Mirror of `scene.set_property`.
- **`scene.duplicate_node`** — clone a node (with descendants) and set owner recursively so the copy serializes.
- **`fs.list`** — enumerate project files by type (`scene`, `script`, `resource`, `shader`, `image`, `audio`) with optional glob filter.
- **`animation.list`, `animation.add_animation`, `animation.remove_animation`, `animation.add_value_track`** — AnimationPlayer manipulation without touching .tscn text.
- **`refs.rename_class`** — rewrite `class_name X` to `class_name Y` and every word-boundary reference across .gd / .tscn / .tres files. Supports `dry_run`.
- **`input_map.remove_event`** — remove a specific event from an action by index. Closes the asymmetry with `add_event`.
- **`editor.save_all_scenes`** — save every open scene in one call.
- **Node.js smoke test harness** at [`tests/smoke.mjs`](tests/smoke.mjs) — exercises ~35 tool calls end-to-end. Run with `node tests/smoke.mjs` while the editor is open.

### Changed

- **MCP shim uses a persistent TCP connection** now instead of opening a new socket per tool call. Multiple in-flight requests tracked by id.
- **`input_map.*` operations sync the runtime InputMap** in addition to saving to `project.godot`, so added actions/events are usable immediately without an editor restart.
- **`input_map.list` reads `project.godot`'s `[input]` section directly** (via `ConfigFile`) rather than filtering `ProjectSettings.get_property_list()` by `PROPERTY_USAGE_STORAGE` — that flag is set on Godot's ~90 built-in ui_* defaults too, which broke user-only filtering.
- **Server-side diagnostic for silent tool-module failures** — when a tool's `.gd` file fails to parse, preload returns null and tool calls produce `{}`; the server now reports that as an error pointing at the Output panel instead of wire-level `{"result": null}`.
- Plugin print on enable now reminds users to configure their MCP client.
- `plugin.cfg` description mentions the setup step.

### Fixed

- `refs.validate_project` no longer false-positives `script_parse_error` on scripts with `class_name` (was using a detached `GDScript.new()` + `reload()` which collided with the global class registry). Now goes through `ResourceLoader.load()`.
- `refs.find_usages` / `refs.rename` now scan `project.godot` for references — previously `_walk`'s extension list missed `.godot`, silently hiding autoload references from rename operations.
- `scene.save_scene` no longer crashes the whole `scene_tools.gd` module. `EditorInterface.save_scene_as()` returns void (not Error); the previous `var err: int = EditorInterface.save_scene_as(...)` was a parse error that killed every `scene.*` tool silently.

### Removed

- `.mcp.json` auto-writer dialog on plugin enable — was Claude Code-specific and confused users of other MCP clients.

## [0.1.2] — 2026-04-20

### Fixed

- `plugin.cfg` version synced with `mcp/package.json`.

## [0.1.1] — 2026-04-20

Initial Asset Library / npm publish with full surface of 32 tools.

## [0.1.0] — 2026-04-20

Initial release. Godot editor plugin + MCP shim + 32 tools.

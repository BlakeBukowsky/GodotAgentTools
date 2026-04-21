# Changelog

All notable changes to this project will be documented here. Versions on the Godot addon
(`addons/agent_tools/plugin.cfg`) and the MCP shim (`mcp/package.json`) stay in sync.

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

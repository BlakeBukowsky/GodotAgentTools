@tool
extends RefCounted

# editor.reload_filesystem — trigger an editor filesystem rescan.
# Run this after external file changes (created/moved/deleted by tools outside the editor)
# so load() and the FileSystem dock reflect reality.
static func reload_filesystem(_params: Dictionary) -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	return {"data": {"scanned": true}}


# editor.save_all_scenes — save every open edited scene.
static func save_all_scenes(_params: Dictionary) -> Dictionary:
	EditorInterface.save_all_scenes()
	return {"data": {"saved": true}}


# editor.state — consolidated editor + project status in one call.
# Replaces piecewise scene.current + project.get_setting + etc.
static func state(_params: Dictionary) -> Dictionary:
	var version := Engine.get_version_info()
	var version_str: String = "%d.%d.%d-%s" % [version.major, version.minor, version.patch, version.status]

	var current_scene_path := ""
	var current_scene_class := ""
	var current_scene_name := ""
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		current_scene_path = root.scene_file_path
		current_scene_class = root.get_class()
		current_scene_name = String(root.name)

	var open_scenes: Array = []
	for s in EditorInterface.get_open_scenes():
		open_scenes.append(s)

	var project_name := ""
	if ProjectSettings.has_setting("application/config/name"):
		project_name = str(ProjectSettings.get_setting("application/config/name"))

	return {"data": {
		"godot_version": version_str,
		"project_name": project_name,
		"current_scene": {
			"path": current_scene_path,
			"root_name": current_scene_name,
			"root_class": current_scene_class,
			"open": root != null,
		},
		"open_scenes": open_scenes,
		"playing_scene": EditorInterface.is_playing_scene(),
		"playing_scene_path": EditorInterface.get_playing_scene() if EditorInterface.is_playing_scene() else "",
	}}


# editor.selection_get — return the currently-selected nodes in the editor tree dock.
# Useful for "operate on whatever I clicked" workflows.
static func selection_get(_params: Dictionary) -> Dictionary:
	var selection := EditorInterface.get_selection()
	var root := EditorInterface.get_edited_scene_root()
	var out: Array = []
	for node in selection.get_selected_nodes():
		var path_str := ""
		if root != null and (node == root or root.is_ancestor_of(node)):
			path_str = String(root.get_path_to(node))
		out.append({
			"name": String(node.name),
			"class": node.get_class(),
			"node_path": path_str,
		})
	return {"data": {"selected": out, "count": out.size()}}


# editor.selection_set — select a specific set of nodes in the editor tree dock.
# Params: {node_paths: ["Player", "Enemy"]}
static func selection_set(params: Dictionary) -> Dictionary:
	var paths: Array = params.get("node_paths", [])
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"error": {"code": -32001, "message": "no scene open"}}

	var selection := EditorInterface.get_selection()
	selection.clear()

	var resolved: Array = []
	var missing: Array = []
	for p in paths:
		var node: Node = root if p == "." else root.get_node_or_null(p)
		if node == null:
			missing.append(p)
			continue
		selection.add_node(node)
		resolved.append(p)

	if not missing.is_empty():
		return {"error": {"code": -32001, "message": "nodes not found: %s" % str(missing)}}
	return {"data": {"selected": resolved}}


# editor.game_screenshot — capture the viewport of the currently-running game.
# Works when the user has pressed F5 (or equivalent) and a game process is running
# with our runtime bridge autoload registered. Writes a request file, polls for
# the bridge to produce the PNG, returns the path.
#
# Params: {output?: "res://.godot/agent_tools/game.png", timeout_ms?: 5000}
static func game_screenshot(params: Dictionary) -> Dictionary:
	var output_path: String = params.get("output", "res://.godot/agent_tools/game_screenshot.png")
	var timeout_ms: int = int(params.get("timeout_ms", 5000))

	if not EditorInterface.is_playing_scene():
		return {"error": {"code": -32001,
			"message": "no game running — press F5 (or equivalent) to start the game, then call again. Alternative for arbitrary scenes: run.scene_headless with 'screenshot'."}}

	var bridge_dir := "res://.godot/agent_tools/bridge"
	if not DirAccess.dir_exists_absolute(bridge_dir):
		var derr := DirAccess.make_dir_recursive_absolute(bridge_dir)
		if derr != OK:
			return {"error": {"code": -32001, "message": "mkdir failed: %d" % derr}}

	# Wipe stale output so we can detect when the bridge has written fresh data.
	if FileAccess.file_exists(output_path):
		@warning_ignore("return_value_discarded")
		DirAccess.remove_absolute(output_path)

	var request_path := bridge_dir + "/request.json"
	var request_id := str(Time.get_ticks_msec())
	var req := {
		"id": request_id,
		"type": "screenshot",
		"output": output_path,
	}
	var f := FileAccess.open(request_path, FileAccess.WRITE)
	if f == null:
		return {"error": {"code": -32001, "message": "could not write bridge request"}}
	f.store_string(JSON.stringify(req))
	f.close()

	# Poll for response — bridge writes response.json with matching id when done.
	var response_path := bridge_dir + "/response.json"
	var deadline_usec: int = Time.get_ticks_usec() + timeout_ms * 1000
	while Time.get_ticks_usec() < deadline_usec:
		if FileAccess.file_exists(response_path):
			var rf := FileAccess.open(response_path, FileAccess.READ)
			if rf:
				var body := rf.get_as_text()
				rf.close()
				var parsed = JSON.parse_string(body)
				if typeof(parsed) == TYPE_DICTIONARY and parsed.get("id", "") == request_id:
					@warning_ignore("return_value_discarded")
					DirAccess.remove_absolute(response_path)
					if parsed.has("error"):
						return {"error": {"code": -32001, "message": "bridge: %s" % parsed.error}}
					return {"data": {
						"path": output_path,
						"captured": FileAccess.file_exists(output_path),
					}}
		OS.delay_msec(50)

	# Clean up stale request if bridge never picked it up.
	if FileAccess.file_exists(request_path):
		@warning_ignore("return_value_discarded")
		DirAccess.remove_absolute(request_path)
	return {"error": {"code": -32001,
		"message": "bridge timed out after %dms — is the running game using the _MCPGameBridge autoload? Re-enable the plugin to re-register it, then press F5 again." % timeout_ms}}


# logs.read — pull recent log lines captured by the game-bridge autoload.
# Params: {clear?: false, max_lines?: 200}
static func logs_read(params: Dictionary) -> Dictionary:
	var clear: bool = params.get("clear", false)
	var max_lines: int = int(params.get("max_lines", 200))
	var logs_path := "res://.godot/agent_tools/bridge/logs.json"
	if not FileAccess.file_exists(logs_path):
		return {"data": {
			"entries": [],
			"count": 0,
			"note": "no log buffer found — the game may not be running or the autoload isn't initialized. Press F5 and try again.",
		}}
	var f := FileAccess.open(logs_path, FileAccess.READ)
	if f == null:
		return {"error": {"code": -32001, "message": "could not read logs"}}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_ARRAY:
		parsed = []
	var entries: Array = parsed
	if entries.size() > max_lines:
		entries = entries.slice(entries.size() - max_lines)
	if clear:
		@warning_ignore("return_value_discarded")
		DirAccess.remove_absolute(logs_path)
	return {"data": {"entries": entries, "count": entries.size()}}


# logs.clear — drop the log buffer regardless of read state.
static func logs_clear(_params: Dictionary) -> Dictionary:
	var logs_path := "res://.godot/agent_tools/bridge/logs.json"
	if FileAccess.file_exists(logs_path):
		@warning_ignore("return_value_discarded")
		DirAccess.remove_absolute(logs_path)
	return {"data": {"cleared": true}}
